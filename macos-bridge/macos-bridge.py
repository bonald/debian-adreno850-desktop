#!/usr/bin/env python3
"""
Lightweight host bridge for macOS 27 (xnulinux) running inside Debian chroot.
Bound strictly to the private VM TAP IP (192.168.78.1:8445, never public Wi-Fi):
  - WebDAV read/write shared folders:
      /android/... -> /mnt/android  (Android /storage/emulated/0)
      /debian/...  -> /home/droid   (Debian user home)
  - Bidirectional clipboard sync:
      GET  /_clip  -> latest clipboard text + X-Clip-Seq header
      POST /_clip  -> updates clipboard & syncs to X11 DISPLAY=:0
  - Live guest IP registration:
      POST /_register_ip -> records macOS guest DHCP IP (192.168.77.x) to /tmp/macos-ip
      GET  /_status      -> JSON status summary
"""

import ctypes
import datetime
import email.utils
import http.server
import json
import mimetypes
import os
import posixpath
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
import xml.sax.saxutils as saxutils

BIND_HOST = os.environ.get("MACOS_BRIDGE_HOST", "192.168.78.1")
BIND_PORT = int(os.environ.get("MACOS_BRIDGE_PORT", "8445"))
AUDIO_PORT = int(os.environ.get("MACOS_AUDIO_PORT", "4714"))
PULSE_SERVER = os.environ.get("PULSE_SERVER", "127.0.0.1")
IP_FILE = "/tmp/macos-ip"
CLIP_FILE = "/tmp/macos-clipboard.txt"

ROOTS = {
    "android": "/mnt/android",
    "debian": "/home/droid",
}

clip_lock = threading.Lock()
clip_text = ""
clip_seq = 0
last_guest_ip = ""
last_guest_seen = 0.0


def x11_get_clipboard():
    env = dict(os.environ, DISPLAY=":0")
    for cmd in (["xclip", "-o", "-selection", "clipboard"], ["xsel", "-ob"]):
        if shutil.which(cmd[0]):
            try:
                r = subprocess.run(cmd, env=env, capture_output=True, timeout=1.5)
                if r.returncode == 0:
                    return r.stdout.decode("utf-8", errors="replace")
            except Exception:
                pass
    return None


def x11_set_clipboard(text: str):
    env = dict(os.environ, DISPLAY=":0")
    data = text.encode("utf-8")
    for cmd in (["xclip", "-i", "-selection", "clipboard"], ["xsel", "-ib"]):
        if shutil.which(cmd[0]):
            try:
                subprocess.run(cmd, input=data, env=env, timeout=1.5, check=False)
                return
            except Exception:
                pass


def x11_clipboard_watcher():
    global clip_text, clip_seq
    while True:
        time.sleep(1.0)
        val = x11_get_clipboard()
        if val is None:
            continue
        with clip_lock:
            if val != clip_text and len(val) <= 262144:
                clip_text = val
                clip_seq += 1
                try:
                    with open(CLIP_FILE, "w", encoding="utf-8") as f:
                        f.write(val)
                except Exception:
                    pass


def resolve_share_path(url_path: str):
    clean = posixpath.normpath(urllib.parse.unquote(url_path))
    parts = [p for p in clean.split("/") if p]
    if not parts:
        return None, None, None
    share = parts[0]
    if share not in ROOTS:
        return None, None, None
    base = os.path.realpath(ROOTS[share])
    rel = os.path.join(*parts[1:]) if len(parts) > 1 else ""
    full = os.path.realpath(os.path.join(base, rel)) if rel else base
    if full != base and not full.startswith(base + os.sep):
        return None, None, None
    return share, rel, full


def dav_response_xml(href: str, fs_path: str):
    st = os.stat(fs_path)
    is_dir = os.path.isdir(fs_path)
    if is_dir and not href.endswith("/"):
        href += "/"
    mtime = email.utils.formatdate(st.st_mtime, usegmt=True)
    iso = datetime.datetime.fromtimestamp(st.st_mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    etag = f'"{int(st.st_mtime)}-{st.st_size}"'
    res_type = "<D:collection/>" if is_dir else ""
    size_el = "" if is_dir else f"<D:getcontentlength>{st.st_size}</D:getcontentlength>"
    ctype = "" if is_dir else f"<D:getcontenttype>{saxutils.escape(mimetypes.guess_type(fs_path)[0] or 'application/octet-stream')}</D:getcontenttype>"
    return (
        "<D:response>"
        f"<D:href>{saxutils.escape(urllib.parse.quote(href, safe='/'))}</D:href>"
        "<D:propstat><D:prop>"
        f"<D:resourcetype>{res_type}</D:resourcetype>"
        f"{size_el}{ctype}"
        f"<D:getlastmodified>{mtime}</D:getlastmodified>"
        f"<D:creationdate>{iso}</D:creationdate>"
        f"<D:getetag>{etag}</D:getetag>"
        "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>"
        "</D:response>"
    )


class BridgeHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # keep logs quiet

    def _send_bytes(self, code, data: bytes, ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("DAV", "1, 2")
        self.send_header("MS-Author-Via", "DAV")
        self.send_header("Allow", "OPTIONS, GET, HEAD, POST, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PROPFIND(self):
        parsed = urllib.parse.urlsplit(self.path)
        depth = self.headers.get("Depth", "1").lower()
        clean_path = posixpath.normpath(urllib.parse.unquote(parsed.path))

        if clean_path in ("/", ""):
            items = [
                "<D:response><D:href>/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
            ]
            if depth != "0":
                for name, root in ROOTS.items():
                    if os.path.isdir(root):
                        items.append(dav_response_xml(f"/{name}/", root))
            body = ('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">' + "".join(items) + "</D:multistatus>").encode("utf-8")
            self._send_bytes(207, body, "application/xml; charset=utf-8")
            return

        share, rel, full = resolve_share_path(parsed.path)
        if not full or not os.path.exists(full):
            self._send_bytes(404, b"Not Found")
            return

        href_base = f"/{share}" + (f"/{rel}" if rel else "")
        items = [dav_response_xml(href_base, full)]
        if depth != "0" and os.path.isdir(full):
            try:
                for entry in sorted(os.listdir(full)):
                    if entry in (".", ".."):
                        continue
                    ep = os.path.join(full, entry)
                    try:
                        os.stat(ep)
                        ehref = href_base.rstrip("/") + "/" + entry
                        items.append(dav_response_xml(ehref, ep))
                    except OSError:
                        continue
            except OSError:
                pass
        body = ('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">' + "".join(items) + "</D:multistatus>").encode("utf-8")
        self._send_bytes(207, body, "application/xml; charset=utf-8")

    def do_PROPPATCH(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 0:
            self.rfile.read(length)
        href = saxutils.escape(self.path)
        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            f'<D:multistatus xmlns:D="DAV:"><D:response><D:href>{href}</D:href>'
            "<D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>"
            "</D:response></D:multistatus>"
        ).encode("utf-8")
        self._send_bytes(207, body, "application/xml; charset=utf-8")

    def do_LOCK(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 0:
            self.rfile.read(length)
        token = f"opaquelocktoken:{int(time.time() * 1000)}"
        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>'
            "<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>"
            "<D:depth>Infinity</D:depth><D:timeout>Second-3600</D:timeout>"
            f"<D:locktoken><D:href>{token}</D:href></D:locktoken>"
            "</D:activelock></D:lockdiscovery></D:prop>"
        ).encode("utf-8")
        self._send_bytes(200, body, "application/xml; charset=utf-8", {"Lock-Token": f"<{token}>"})

    def do_UNLOCK(self):
        self._send_bytes(204, b"")

    def do_HEAD(self):
        self._handle_get(head_only=True)

    def do_GET(self):
        self._handle_get(head_only=False)

    def _handle_get(self, head_only: bool):
        global clip_text, clip_seq
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/_status":
            with clip_lock:
                st = {
                    "ok": True,
                    "guest_ip": last_guest_ip,
                    "guest_seen_age_s": round(time.time() - last_guest_seen, 1) if last_guest_seen else None,
                    "clip_seq": clip_seq,
                    "shares": list(ROOTS.keys()),
                }
            self._send_bytes(200, json.dumps(st).encode("utf-8"), "application/json")
            return

        if parsed.path == "/_clip":
            with clip_lock:
                data = clip_text.encode("utf-8")
                seq = str(clip_seq)
            self._send_bytes(200, b"" if head_only else data, "text/plain; charset=utf-8", {"X-Clip-Seq": seq})
            return

        share, rel, full = resolve_share_path(parsed.path)
        if not full or not os.path.exists(full):
            self._send_bytes(404, b"Not Found")
            return
        if os.path.isdir(full):
            entries = sorted(os.listdir(full))
            body = ("\n".join(entries) + "\n").encode("utf-8")
            self._send_bytes(200, b"" if head_only else body, "text/plain; charset=utf-8")
            return

        st = os.stat(full)
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(st.st_size))
        self.send_header("Last-Modified", email.utils.formatdate(st.st_mtime, usegmt=True))
        self.end_headers()
        if not head_only:
            with open(full, "rb") as f:
                shutil.copyfileobj(f, self.wfile, 131072)

    def do_POST(self):
        global clip_text, clip_seq, last_guest_ip, last_guest_seen
        parsed = urllib.parse.urlsplit(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(min(length, 524288)) if length > 0 else b""

        if parsed.path == "/_register_ip":
            ip = body.decode("utf-8", errors="ignore").strip()
            if not ip:
                ip = self.client_address[0]
            last_guest_ip = ip
            last_guest_seen = time.time()
            try:
                with open(IP_FILE, "w", encoding="utf-8") as f:
                    f.write(ip + "\n")
            except Exception:
                pass
            self._send_bytes(200, (ip + "\n").encode("utf-8"))
            return

        if parsed.path == "/_clip":
            text = body.decode("utf-8", errors="replace")
            with clip_lock:
                if text != clip_text:
                    clip_text = text
                    clip_seq += 1
                    try:
                        with open(CLIP_FILE, "w", encoding="utf-8") as f:
                            f.write(text)
                    except Exception:
                        pass
                    x11_set_clipboard(text)
                seq = str(clip_seq)
            self._send_bytes(200, b"OK\n", extra={"X-Clip-Seq": seq})
            return

        self._send_bytes(404, b"Not Found")

    def do_PUT(self):
        parsed = urllib.parse.urlsplit(self.path)
        share, rel, full = resolve_share_path(parsed.path)
        if not full or not rel:
            self._send_bytes(403, b"Forbidden")
            return
        os.makedirs(os.path.dirname(full), exist_ok=True)
        existed = os.path.exists(full)
        length = int(self.headers.get("Content-Length", "0"))
        tmp = full + ".davtmp"
        try:
            with open(tmp, "wb") as f:
                rem = length
                while rem > 0:
                    chunk = self.rfile.read(min(rem, 131072))
                    if not chunk:
                        break
                    f.write(chunk)
                    rem -= len(chunk)
            os.replace(tmp, full)
        except Exception as e:
            if os.path.exists(tmp):
                os.unlink(tmp)
            self._send_bytes(500, str(e).encode("utf-8"))
            return
        self._send_bytes(204 if existed else 201, b"")

    def do_MKCOL(self):
        parsed = urllib.parse.urlsplit(self.path)
        share, rel, full = resolve_share_path(parsed.path)
        if not full or not rel:
            self._send_bytes(403, b"Forbidden")
            return
        if os.path.exists(full):
            self._send_bytes(405, b"Already Exists")
            return
        try:
            os.mkdir(full)
        except FileNotFoundError:
            self._send_bytes(409, b"Conflict")
            return
        self._send_bytes(201, b"")

    def do_DELETE(self):
        parsed = urllib.parse.urlsplit(self.path)
        share, rel, full = resolve_share_path(parsed.path)
        if not full or not rel or not os.path.exists(full):
            self._send_bytes(404, b"Not Found")
            return
        try:
            if os.path.isdir(full):
                shutil.rmtree(full)
            else:
                os.unlink(full)
        except Exception as e:
            self._send_bytes(500, str(e).encode("utf-8"))
            return
        self._send_bytes(204, b"")

    def do_MOVE(self):
        self._move_or_copy(move=True)

    def do_COPY(self):
        self._move_or_copy(move=False)

    def _move_or_copy(self, move: bool):
        parsed = urllib.parse.urlsplit(self.path)
        _, src_rel, src_full = resolve_share_path(parsed.path)
        dest_hdr = self.headers.get("Destination", "")
        dest_path = urllib.parse.urlsplit(dest_hdr).path
        _, dst_rel, dst_full = resolve_share_path(dest_path)
        if not src_full or not src_rel or not dst_full or not dst_rel or not os.path.exists(src_full):
            self._send_bytes(404, b"Not Found")
            return
        existed = os.path.exists(dst_full)
        try:
            if move:
                shutil.move(src_full, dst_full)
            elif os.path.isdir(src_full):
                if existed:
                    shutil.rmtree(dst_full)
                shutil.copytree(src_full, dst_full)
            else:
                shutil.copy2(src_full, dst_full)
        except Exception as e:
            self._send_bytes(500, str(e).encode("utf-8"))
            return
        self._send_bytes(204 if existed else 201, b"")


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class _PaSampleSpec(ctypes.Structure):
    _fields_ = [("format", ctypes.c_int), ("rate", ctypes.c_uint32), ("channels", ctypes.c_uint8)]


class _PaBufferAttr(ctypes.Structure):
    _fields_ = [
        ("maxlength", ctypes.c_uint32),
        ("tlength", ctypes.c_uint32),
        ("prebuf", ctypes.c_uint32),
        ("minreq", ctypes.c_uint32),
        ("fragsize", ctypes.c_uint32),
    ]


def _handle_audio_client(conn, lp):
    ss = _PaSampleSpec(3, 48000, 2)  # PA_SAMPLE_S16LE=3, 48kHz, stereo
    u32_max = 0xFFFFFFFF
    attr = _PaBufferAttr(u32_max, 7680, u32_max, u32_max, u32_max)  # ~40ms target latency
    err = ctypes.c_int(0)
    stream = lp.pa_simple_new(
        PULSE_SERVER.encode("utf-8"),
        b"macOS27",
        1,  # PA_STREAM_PLAYBACK
        None,
        b"macOS Audio",
        ctypes.byref(ss),
        None,
        ctypes.byref(attr),
        ctypes.byref(err),
    )
    if not stream:
        conn.close()
        return
    try:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        while True:
            data = conn.recv(4096)
            if not data:
                break
            if lp.pa_simple_write(ctypes.c_void_p(stream), data, len(data), ctypes.byref(err)) < 0:
                break
        lp.pa_simple_drain(ctypes.c_void_p(stream), ctypes.byref(err))
    except Exception:
        pass
    finally:
        lp.pa_simple_free(ctypes.c_void_p(stream))
        try:
            conn.close()
        except Exception:
            pass


def audio_tcp_server():
    try:
        lp = ctypes.CDLL("libpulse-simple.so.0")
        lp.pa_simple_new.restype = ctypes.c_void_p
    except OSError as e:
        print(f"macos-bridge audio disabled (libpulse-simple unavailable: {e})", flush=True)
        return

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((BIND_HOST, AUDIO_PORT))
        srv.listen(4)
    except OSError as e:
        print(f"macos-bridge audio bind failed on {BIND_HOST}:{AUDIO_PORT}: {e}", flush=True)
        return
    print(f"macos-bridge audio listening on {BIND_HOST}:{AUDIO_PORT} -> PulseAudio {PULSE_SERVER} (48kHz s16le stereo)", flush=True)
    while True:
        try:
            conn, _ = srv.accept()
            threading.Thread(target=_handle_audio_client, args=(conn, lp), daemon=True).start()
        except Exception:
            time.sleep(0.2)


def main():
    threading.Thread(target=x11_clipboard_watcher, daemon=True).start()
    threading.Thread(target=audio_tcp_server, daemon=True).start()
    srv = ThreadedHTTPServer((BIND_HOST, BIND_PORT), BridgeHandler)
    print(f"macos-bridge listening on http://{BIND_HOST}:{BIND_PORT} (shares: /android, /debian, /_clip, /_register_ip)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
