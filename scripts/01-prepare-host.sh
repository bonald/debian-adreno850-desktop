#!/usr/bin/env bash
# Step 1 (Run on your PC with ADB connected to the rooted Android phone):
#   1. Downloads the latest Debian 13 (trixie) arm64 rootfs from LinuxContainers
#   2. Downloads upstream Mesa 26.3.1 and applies patches/mesa-26.3.1-adreno-850.patch
#   3. Repacks archives (zstd if available, otherwise xz) and pushes all setup files to the phone
#
# Usage:
#   ./scripts/01-prepare-host.sh [ADB_SERIAL]
#
# Environment overrides:
#   MESA_VERSION=26.3.1   Mesa release to download & patch
#   WORK_DIR=./work       Local staging directory
#   SKIP_PUSH=1           Prepare archives locally without pushing via ADB

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
MESA_VERSION="${MESA_VERSION:-26.3.1}"
MESA_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"
DEBIAN_BASE="https://images.linuxcontainers.org/images/debian/trixie/arm64/default/"
PATCH_FILE="$REPO_ROOT/patches/mesa-${MESA_VERSION}-adreno-850.patch"
REMOTE_DIR="/data/local/tmp/debian-gpu-setup"

ADB_ARGS=()
if [ "${1:-}" != "" ]; then
    ADB_ARGS=(-s "$1")
elif [ "${ADB_SERIAL:-}" != "" ]; then
    ADB_ARGS=(-s "$ADB_SERIAL")
fi

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: Required command '$1' not found in PATH." >&2
        exit 1
    }
}

require_cmd curl
require_cmd tar
require_cmd xz
require_cmd patch

mkdir -p "$WORK_DIR"

echo "==> [1/4] Fetching Debian 13 (trixie) arm64 rootfs..."
if [ ! -f "$WORK_DIR/debian-trixie-arm64.tar.xz" ]; then
    LATEST="$(curl -sL "$DEBIAN_BASE" | grep -oE '202[0-9]{5}_[0-9]{2}:[0-9]{2}/' | sort | tail -n 1)"
    if [ -z "$LATEST" ]; then
        echo "ERROR: Could not detect latest Debian trixie arm64 build from $DEBIAN_BASE" >&2
        exit 1
    fi
    echo "    Build: $LATEST"
    curl -fL --progress-bar "${DEBIAN_BASE}${LATEST}rootfs.tar.xz" -o "$WORK_DIR/debian-trixie-arm64.tar.xz"
else
    echo "    Using cached $WORK_DIR/debian-trixie-arm64.tar.xz"
fi

echo "==> [2/4] Fetching & patching Mesa ${MESA_VERSION} for Adreno 850 (KGSL gen8_14_0)..."
if [ ! -f "$WORK_DIR/mesa-${MESA_VERSION}.tar.xz" ]; then
    curl -fL --progress-bar "$MESA_URL" -o "$WORK_DIR/mesa-${MESA_VERSION}.tar.xz"
else
    echo "    Using cached $WORK_DIR/mesa-${MESA_VERSION}.tar.xz"
fi

rm -rf "$WORK_DIR/mesa-src"
mkdir -p "$WORK_DIR/mesa-src"
tar -xJf "$WORK_DIR/mesa-${MESA_VERSION}.tar.xz" -C "$WORK_DIR/mesa-src"

if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: Patch file not found: $PATCH_FILE" >&2
    exit 1
fi
patch -d "$WORK_DIR/mesa-src/mesa-${MESA_VERSION}" -p1 < "$PATCH_FILE"
grep -n "Adreno (TM) 850" "$WORK_DIR/mesa-src/mesa-${MESA_VERSION}/src/freedreno/common/freedreno_devices.py"

echo "==> [3/4] Packing trimmed Mesa source & Debian rootfs..."
USE_ZSTD=0
if command -v zstd >/dev/null 2>&1; then
    USE_ZSTD=1
fi

if [ "$USE_ZSTD" -eq 1 ]; then
    DEBIAN_ARCHIVE="$WORK_DIR/debian-trixie-arm64.tar.zst"
    MESA_ARCHIVE="$WORK_DIR/mesa-glibc-a850.tar.zst"
    xz -dc "$WORK_DIR/debian-trixie-arm64.tar.xz" | zstd -T0 -3 -q -f -o "$DEBIAN_ARCHIVE"
    tar -C "$WORK_DIR/mesa-src" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/radeonsi" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/r600" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/iris" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/crocus" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/nouveau" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/svga" \
        -cf - "mesa-${MESA_VERSION}" | zstd -T0 -3 -q -f -o "$MESA_ARCHIVE"
else
    DEBIAN_ARCHIVE="$WORK_DIR/debian-trixie-arm64.tar.xz"
    MESA_ARCHIVE="$WORK_DIR/mesa-glibc-a850.tar.xz"
    tar -C "$WORK_DIR/mesa-src" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/radeonsi" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/r600" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/iris" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/crocus" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/nouveau" \
        --exclude="mesa-${MESA_VERSION}/src/gallium/drivers/svga" \
        -cJf "$MESA_ARCHIVE" "mesa-${MESA_VERSION}"
fi

ls -lh "$DEBIAN_ARCHIVE" "$MESA_ARCHIVE"

if [ "${SKIP_PUSH:-0}" = "1" ]; then
    echo "SKIP_PUSH=1 set. Staging complete in $WORK_DIR."
    exit 0
fi

require_cmd adb
echo "==> [4/4] Pushing archives and scripts to device ($REMOTE_DIR)..."
adb "${ADB_ARGS[@]}" shell "mkdir -p '$REMOTE_DIR'"
adb "${ADB_ARGS[@]}" push \
    "$DEBIAN_ARCHIVE" \
    "$MESA_ARCHIVE" \
    "$REPO_ROOT/config/turnip-a850.sh" \
    "$REPO_ROOT/scripts/02-bootstrap-chroot.sh" \
    "$REPO_ROOT/scripts/03-install-and-build-chroot.sh" \
    "$REPO_ROOT/scripts/setup-macos-desktop.sh" \
    "$REPO_ROOT/scripts/debian-gpu.sh" \
    "$REPO_ROOT/scripts/verify-gpu.sh" \
    "$REMOTE_DIR/"

adb "${ADB_ARGS[@]}" shell "chmod 755 '$REMOTE_DIR'/*.sh"

echo ""
echo "Done! Next step — run the on-device bootstrap + build as root:"
echo "  adb ${ADB_ARGS[*]:-} shell su -c \"sh $REMOTE_DIR/02-bootstrap-chroot.sh\""
