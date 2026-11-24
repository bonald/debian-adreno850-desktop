#!/data/data/com.termux/files/usr/bin/bash
# Run once inside Termux (non-root) on the Android device to install
# Termux:X11 CLI, socat (for Tailscale-only VNC forwarding), and zstd.
set -euo pipefail

echo "==> Updating Termux packages..."
pkg update -y
pkg upgrade -y

echo "==> Enabling X11 repo and installing termux-x11-nightly, socat, zstd..."
pkg install -y x11-repo
pkg install -y termux-x11-nightly socat zstd

mkdir -p "$PREFIX/tmp/.X11-unix"

echo ""
echo "Termux prerequisites installed."
echo "Make sure the Termux:X11 Android companion APK (com.termux.x11) is also installed."
