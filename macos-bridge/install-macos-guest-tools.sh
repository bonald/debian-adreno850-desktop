#!/bin/sh
# Runs inside hosted macOS 27 (xnulinux) as root.
# Installs:
#  1. AndroidAudio.driver CoreAudio HAL plug-in (48 kHz stereo -> Android AAudio_sink :4714)
#  2. SSH (Remote Login) & Apple Screen Sharing daemons
#  3. Persistent bridge daemon (registers DHCP IP, keeps coreaudiod up, mounts /Volumes/Android & /Volumes/Debian)
#  4. Persistent bidirectional clipboard LaunchAgent for GUI user 'xnu'
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

HOST_URL="${HOST_URL:-http://192.168.78.1:18080}"
BRIDGE_URL="http://192.168.78.1:8445"

echo "=== [1/4] Installing AndroidAudio.driver (CoreAudio HAL -> Android AAudio_sink) ==="
if curl -sf "${HOST_URL}/AndroidAudio.driver.tar.gz" -o /tmp/AndroidAudio.driver.tar.gz; then
    rm -rf /Library/Audio/Plug-Ins/HAL/AndroidAudio.driver
    mkdir -p /Library/Audio/Plug-Ins/HAL
    tar -xzf /tmp/AndroidAudio.driver.tar.gz -C /Library/Audio/Plug-Ins/HAL
    rm -f /tmp/AndroidAudio.driver.tar.gz
    chown -R root:wheel /Library/Audio/Plug-Ins/HAL/AndroidAudio.driver
    chmod -R 755 /Library/Audio/Plug-Ins/HAL/AndroidAudio.driver
    codesign --force --deep --sign - /Library/Audio/Plug-Ins/HAL/AndroidAudio.driver 2>/dev/null || true

    # Enable & restart coreaudiod so it loads AndroidAudio.driver immediately
    launchctl enable system/com.apple.audio.coreaudiod 2>/dev/null || true
    launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.audio.coreaudiod.plist 2>/dev/null || true
    launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || true
    sleep 2
    system_profiler SPAudioDataType 2>/dev/null | head -n 25 || true
else
    echo "WARN: AndroidAudio.driver.tar.gz not fetched from ${HOST_URL}"
fi

echo "=== [2/4] Enabling SSH (Remote Login) & Screen Sharing ==="
ssh-keygen -A >/dev/null 2>&1 || true
launchctl enable system/com.openssh.sshd 2>/dev/null || true
launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true

launchctl enable system/com.apple.screensharing 2>/dev/null || true
launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true

echo "=== [3/4] Installing Persistent Host Bridge Daemon (IP + WebDAV Shares + Audio) ==="
mkdir -p /usr/local/libexec
cat > /usr/local/libexec/xnu_bridge_daemon.sh <<'EOF'
#!/bin/sh
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
BRIDGE="http://192.168.78.1:8445"

# Ensure coreaudiod stays loaded so apps always see Android AAudio Speakers
if ! pgrep -x coreaudiod >/dev/null 2>&1; then
    launchctl enable system/com.apple.audio.coreaudiod 2>/dev/null || true
    launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.audio.coreaudiod.plist 2>/dev/null || true
    launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || true
fi

# Register current en0 DHCP IP with Android host for Tailscale SSH/Screen Sharing forwarding
IP=$(ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')
if [ -n "$IP" ]; then
    curl -sf --max-time 2 -X POST -d "$IP" "${BRIDGE}/_register_ip" >/dev/null 2>&1 || true
fi

# Auto-mount Android & Debian WebDAV shares if bridge is up
if curl -sf --max-time 2 "${BRIDGE}/_status" >/dev/null 2>&1; then
    for share in Android:android Debian:debian; do
        NAME="${share%:*}"
        SUB="${share#*:}"
        MNT="/Volumes/${NAME}"
        if ! mount | grep -q " on ${MNT} "; then
            mkdir -p "$MNT"
            chown xnu:staff "$MNT" 2>/dev/null || true
            mount_webdav "${BRIDGE}/${SUB}" "$MNT" </dev/null >/dev/null 2>&1 || true
        fi
    done
fi
exit 0
EOF
chmod 755 /usr/local/libexec/xnu_bridge_daemon.sh

cat > /Library/LaunchDaemons/com.xnulinux.bridge.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xnulinux.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/xnu_bridge_daemon.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>15</integer>
</dict>
</plist>
EOF
chown root:wheel /Library/LaunchDaemons/com.xnulinux.bridge.plist
chmod 644 /Library/LaunchDaemons/com.xnulinux.bridge.plist
launchctl bootout system/com.xnulinux.bridge 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.xnulinux.bridge.plist 2>/dev/null || true
/usr/local/libexec/xnu_bridge_daemon.sh || true

echo "=== [4/4] Installing Bidirectional Clipboard Sync LaunchAgent (user xnu) ==="
cat > /usr/local/libexec/xnu_clip_sync.sh <<'EOF'
#!/bin/sh
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
BRIDGE="http://192.168.78.1:8445/_clip"
LAST_LOCAL=""
LAST_SEQ="0"
HDR=/tmp/.xnu_clip_hdr
BODY=/tmp/.xnu_clip_body

while true; do
    CUR=$(pbpaste 2>/dev/null || true)
    if [ "$CUR" != "$LAST_LOCAL" ] && [ -n "$CUR" ]; then
        LAST_LOCAL="$CUR"
        if printf "%s" "$CUR" | curl -sf --max-time 2 -D "$HDR" -X POST --data-binary @- "$BRIDGE" >/dev/null 2>&1; then
            SEQ=$(awk -F': ' 'tolower($1)=="x-clip-seq"{gsub(/\r/,"",$2); print $2}' "$HDR" 2>/dev/null || true)
            [ -n "$SEQ" ] && LAST_SEQ="$SEQ"
        fi
    else
        if curl -sf --max-time 2 -D "$HDR" -o "$BODY" "$BRIDGE" 2>/dev/null; then
            SEQ=$(awk -F': ' 'tolower($1)=="x-clip-seq"{gsub(/\r/,"",$2); print $2}' "$HDR" 2>/dev/null || true)
            if [ -n "$SEQ" ] && [ "$SEQ" != "$LAST_SEQ" ] && [ "$SEQ" != "0" ]; then
                LAST_SEQ="$SEQ"
                REMOTE=$(cat "$BODY" 2>/dev/null || true)
                if [ "$REMOTE" != "$LAST_LOCAL" ]; then
                    printf "%s" "$REMOTE" | pbcopy 2>/dev/null || true
                    LAST_LOCAL="$REMOTE"
                fi
            fi
        fi
    fi
    sleep 1
done
EOF
chmod 755 /usr/local/libexec/xnu_clip_sync.sh

cat > /Library/LaunchAgents/com.xnulinux.clipboard.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xnulinux.clipboard</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/xnu_clip_sync.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
chown root:wheel /Library/LaunchAgents/com.xnulinux.clipboard.plist
chmod 644 /Library/LaunchAgents/com.xnulinux.clipboard.plist
launchctl bootout gui/501/com.xnulinux.clipboard 2>/dev/null || true
launchctl bootstrap gui/501 /Library/LaunchAgents/com.xnulinux.clipboard.plist 2>/dev/null || true

sync
echo "MACOS_GUEST_TOOLS_OK"
