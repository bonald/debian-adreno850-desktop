#!/system/bin/sh
# Native Debian 13 (trixie arm64) chroot manager with bare-metal Adreno 850 GPU
# (glibc Mesa 26.3.1 Turnip Vulkan 1.4 + Zink OpenGL 4.6), macOS-style XFCE4 + Plank
# desktop on Termux:X11 (:0), and TigerVNC (x0vncserver) + noVNC remote access
# restricted to Tailscale + localhost.
#
# Installed path: /data/adb/debian-gpu.sh
#
# Usage:
#   su -c "/data/adb/debian-gpu.sh start"   - Mount, start X11, XFCE4 + Plank, VNC & noVNC
#   su -c "/data/adb/debian-gpu.sh stop"    - Stop desktop, VNC & noVNC
#   su -c "/data/adb/debian-gpu.sh umount"  - Stop services and unmount chroot image
#   su -c "/data/adb/debian-gpu.sh shell"   - Interactive bash shell as droid
#   su -c "/data/adb/debian-gpu.sh status"  - Show running services & remote URLs
#   su -c "/data/adb/debian-gpu.sh passwd"  - Change VNC password
#   su -c "/data/adb/debian-gpu.sh verify"  - Verify Vulkan 1.4 / OpenGL 4.6 / CPU inside chroot

set -eu

IMG="${IMG:-/data/adb/debian-gpu.img}"
MNT="${MNT:-/data/local/debian-gpu}"
DESKTOP_USER="${DESKTOP_USER:-droid}"
TPREFIX="/data/data/com.termux/files/usr"
THOME="/data/data/com.termux/files/home"
X11_DIR="$TPREFIX/tmp/.X11-unix"

detect_termux_uid() {
    if [ -n "${TERMUX_UID:-}" ]; then
        printf "%s\n" "$TERMUX_UID"
        return 0
    fi
    uid="$(stat -c '%u' /data/data/com.termux 2>/dev/null || true)"
    if [ -z "$uid" ]; then
        echo "ERROR: /data/data/com.termux not found. Install Termux first." >&2
        exit 1
    fi
    printf "%s\n" "$uid"
}

get_tailscale_ip() {
    ip -4 addr show dev tun1 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}' \
    || ip -4 addr show 2>/dev/null | awk '/inet 100\./ {split($2,a,"/"); print a[1]; exit}'
}

do_mount() {
    mkdir -p "$MNT" "$X11_DIR"
    if ! mountpoint -q "$MNT"; then
        if [ ! -f "$IMG" ]; then
            echo "ERROR: Chroot image not found at $IMG" >&2
            exit 1
        fi
        LOOP="$(losetup -f)"
        losetup "$LOOP" "$IMG"
        mount -t ext4 -o rw,suid,dev,exec,noatime "$LOOP" "$MNT"
    fi
    mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/tmp/.X11-unix" "$MNT/mnt/android"
    mountpoint -q "$MNT/proc" || mount -t proc proc "$MNT/proc"
    mountpoint -q "$MNT/sys" || mount -t sysfs sysfs "$MNT/sys"
    mountpoint -q "$MNT/dev" || mount --bind /dev "$MNT/dev"
    mkdir -p "$MNT/dev/pts" "$MNT/dev/shm"
    mountpoint -q "$MNT/dev/pts" || mount --bind /dev/pts "$MNT/dev/pts"
    mountpoint -q "$MNT/dev/shm" || mount -t tmpfs -o rw,nosuid,nodev,mode=1777 tmpfs "$MNT/dev/shm"
    mountpoint -q "$MNT/tmp/.X11-unix" || mount --bind "$X11_DIR" "$MNT/tmp/.X11-unix"
    mountpoint -q "$MNT/mnt/android" || mount --bind /storage/emulated/0 "$MNT/mnt/android"
    # Keep DNS fresh across network changes
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$MNT/etc/resolv.conf"
}

run_in_chroot() {
    chroot "$MNT" /usr/bin/env -i \
        HOME=/root \
        TERM=xterm-256color \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/bash -c "$1"
}

start_termux_x11() {
    TUID="$(detect_termux_uid)"
    cmd deviceidle whitelist +com.termux >/dev/null 2>&1 || true
    cmd deviceidle whitelist +com.termux.x11 >/dev/null 2>&1 || true
    if ! ([ -S "$X11_DIR/X0" ] && pgrep -f "termux.x11" >/dev/null 2>&1); then
        su "$TUID" -c "
            export PREFIX=$TPREFIX HOME=$THOME TMPDIR=$TPREFIX/tmp PATH=$TPREFIX/bin:/system/bin
            nohup termux-x11 :0 -ac >\$TMPDIR/termux-x11.log 2>&1 </dev/null &
        "
        i=0
        while [ ! -S "$X11_DIR/X0" ] && [ "$i" -lt 20 ]; do
            sleep 0.5
            i=$((i + 1))
        done
    fi
    am start --user 0 -n com.termux.x11/.MainActivity >/dev/null 2>&1 || true
}

kill_desktop_procs() {
    run_in_chroot "
        for p in x0vncserver X0tigervnc xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd xfconfd plank; do
            pkill -9 -x \"\$p\" 2>/dev/null || true
        done
        pkill -9 -f 'websockify.*6080' 2>/dev/null || true
        pkill -9 -f 'dbus-run-session -- startxfce4' 2>/dev/null || true
        rm -rf '/home/${DESKTOP_USER}/.cache/sessions' 2>/dev/null || true
    " || true
    pkill -9 -f "TCP-LISTEN:5900" 2>/dev/null || true
    pkill -9 -f "TCP-LISTEN:6080" 2>/dev/null || true
}

do_stop() {
    if mountpoint -q "$MNT"; then
        kill_desktop_procs
    fi
    echo "Debian GPU desktop & remote X stopped."
}

do_start() {
    do_mount
    start_termux_x11

    TS_IP="$(get_tailscale_ip || true)"
    kill_desktop_procs
    sleep 0.5

    # Launch macOS-style XFCE4 + Plank desktop on DISPLAY=:0 (bare-metal Adreno 850 Turnip+Zink)
    run_in_chroot "
        su - '${DESKTOP_USER}' -c '
            export DISPLAY=:0
            export VK_ICD_FILENAMES=/opt/turnip-a850/share/vulkan/icd.d/freedreno_icd.aarch64.json
            export MESA_LOADER_DRIVER_OVERRIDE=zink
            export GALLIUM_DRIVER=zink
            export TU_DEBUG=noconform,noubwc
            export MESA_VK_WSI_DEBUG=sw
            export QT_X11_NO_MITSHM=1
            nohup dbus-run-session -- startxfce4 >/tmp/xfce.log 2>&1 </dev/null &
        '
    "

    # Wait up to 8s for xfwm4 to come up
    i=0
    while ! pgrep -x xfwm4 >/dev/null 2>&1 && [ "$i" -lt 16 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    sleep 1

    # Ensure Plank floating dock is running
    run_in_chroot "
        if ! pgrep -x plank >/dev/null 2>&1; then
            su - '${DESKTOP_USER}' -c 'export DISPLAY=:0; nohup plank >/tmp/plank.log 2>&1 </dev/null &'
        fi
    " || true

    # Launch TigerVNC x0vncserver on localhost:5900 (-UseSHM=0 for Android kernels without SYSVIPC)
    # and noVNC/websockify on localhost:6080
    run_in_chroot "
        su - '${DESKTOP_USER}' -c '
            export DISPLAY=:0
            if [ ! -f ~/.vnc/passwd ]; then
                mkdir -p ~/.vnc
                printf \"%s\n\" debian-gpu | vncpasswd -f > ~/.vnc/passwd
                chmod 600 ~/.vnc/passwd
            fi
            nohup x0vncserver -display :0 -interface 127.0.0.1 -rfbport 5900 -PasswordFile ~/.vnc/passwd -UseSHM=0 >/tmp/x0vnc.log 2>&1 </dev/null &
            nohup websockify --web=/usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900 >/tmp/novnc.log 2>&1 </dev/null &
        '
    "
    sleep 1

    # Expose VNC (5900) and noVNC (6080) ONLY on Tailscale IP (never public Wi-Fi)
    if [ -n "$TS_IP" ] && [ -x "$TPREFIX/bin/socat" ]; then
        nohup "$TPREFIX/bin/socat" "TCP-LISTEN:5900,bind=$TS_IP,reuseaddr,fork,nodelay" TCP:127.0.0.1:5900 >/dev/null 2>&1 </dev/null &
        nohup "$TPREFIX/bin/socat" "TCP-LISTEN:6080,bind=$TS_IP,reuseaddr,fork,nodelay" TCP:127.0.0.1:6080 >/dev/null 2>&1 </dev/null &
    fi

    do_status
}

do_umount() {
    do_stop
    sleep 0.5
    for p in "$MNT/mnt/android" "$MNT/tmp/.X11-unix" "$MNT/dev/shm" "$MNT/dev/pts" "$MNT/dev" "$MNT/sys" "$MNT/proc" "$MNT"; do
        mountpoint -q "$p" && umount -l "$p" 2>/dev/null || true
    done
    echo "Debian GPU chroot unmounted."
}

do_status() {
    TS_IP="$(get_tailscale_ip || true)"
    echo "=== Debian 13 Native Adreno 850 Chroot ==="
    mountpoint -q "$MNT" && echo "Mount:      $MNT (mounted)" || echo "Mount:      NOT mounted"
    ([ -S "$X11_DIR/X0" ] && pgrep -f "termux.x11" >/dev/null 2>&1) && echo "Termux:X11: running (DISPLAY=:0)" || echo "Termux:X11: stopped"
    pgrep -x xfwm4 >/dev/null 2>&1 && echo "Desktop:    macOS-style XFCE4 + Plank Dock running" || echo "Desktop:    stopped"
    pgrep -x x0vncserver >/dev/null 2>&1 && echo "TigerVNC:   running (127.0.0.1:5900${TS_IP:+, $TS_IP:5900})" || echo "TigerVNC:   stopped"
    pgrep -f "websockify.*6080" >/dev/null 2>&1 && echo "noVNC Web:  running (http://127.0.0.1:6080/vnc.html${TS_IP:+, http://$TS_IP:6080/vnc.html})" || echo "noVNC Web:  stopped"
}

case "${1:-status}" in
    start)  do_start ;;
    stop)   do_stop ;;
    umount) do_umount ;;
    status) do_status ;;
    shell)
        do_mount
        exec chroot "$MNT" /usr/bin/env -i \
            HOME="/home/${DESKTOP_USER}" USER="${DESKTOP_USER}" LOGNAME="${DESKTOP_USER}" TERM=xterm-256color \
            DISPLAY=:0 \
            VK_ICD_FILENAMES=/opt/turnip-a850/share/vulkan/icd.d/freedreno_icd.aarch64.json \
            MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink \
            TU_DEBUG=noconform,noubwc MESA_VK_WSI_DEBUG=sw QT_X11_NO_MITSHM=1 \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /bin/su -p "${DESKTOP_USER}"
        ;;
    passwd)
        do_mount
        chroot "$MNT" /bin/su - "${DESKTOP_USER}" -c "mkdir -p ~/.vnc && vncpasswd ~/.vnc/passwd && chmod 600 ~/.vnc/passwd"
        echo "Restarting VNC to use new password..."
        do_start
        ;;
    verify)
        do_mount
        shift || true
        chroot "$MNT" /bin/su - "${DESKTOP_USER}" -c "/usr/local/bin/verify-gpu $*"
        ;;
    *)
        echo "Usage: $0 {start|stop|umount|shell|status|passwd|verify [--bench]}" >&2
        exit 1
        ;;
esac
