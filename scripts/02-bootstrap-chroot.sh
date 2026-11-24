#!/system/bin/sh
# Step 2 (Run as root on Android):
#   1. Creates a sparse ext4 loop image at /data/adb/debian-gpu.img (default 32G)
#   2. Mounts it at /data/local/debian-gpu with rw,suid,dev,exec,noatime
#   3. Extracts Debian 13 (trixie) arm64 + patched Mesa 26.3.1 source
#   4. Sets up /proc, /sys, /dev, /dev/pts, /dev/shm, Termux:X11 socket & /mnt/android binds
#   5. Installs /data/adb/debian-gpu.sh and runs step 3 inside the chroot
#
# Usage:
#   su -c "sh /data/local/tmp/debian-gpu-setup/02-bootstrap-chroot.sh"
#
# Environment overrides:
#   IMG_SIZE=32G                    Sparse ext4 image size
#   IMG=/data/adb/debian-gpu.img    Path to ext4 image
#   MNT=/data/local/debian-gpu      Chroot mount point
#   NO_BUILD=1                      Stop after extraction & mounts (skip step 3)

set -eu

SETUP_DIR="$(cd "$(dirname "$0")" && pwd)"
IMG="${IMG:-/data/adb/debian-gpu.img}"
IMG_SIZE="${IMG_SIZE:-32G}"
MNT="${MNT:-/data/local/debian-gpu}"
TPREFIX="/data/data/com.termux/files/usr"
X11_DIR="$TPREFIX/tmp/.X11-unix"
ZSTD="$TPREFIX/bin/zstd"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (e.g. su -c \"sh $0\")." >&2
    exit 1
fi

extract_archive() {
    archive="$1"
    dest="$2"
    extra_tar_flags="${3:-}"
    case "$archive" in
        *.tar.zst)
            if [ ! -x "$ZSTD" ]; then
                echo "ERROR: $ZSTD not found. Run scripts/setup-termux.sh inside Termux first." >&2
                exit 1
            fi
            # shellcheck disable=SC2086
            "$ZSTD" -dc "$archive" | tar $extra_tar_flags -xf - -C "$dest"
            ;;
        *.tar.xz)
            # shellcheck disable=SC2086
            tar $extra_tar_flags -xJf "$archive" -C "$dest"
            ;;
        *)
            echo "ERROR: Unsupported archive format: $archive" >&2
            exit 1
            ;;
    esac
}

echo "==> [1/5] Creating ${IMG_SIZE} sparse ext4 image at $IMG..."
mkdir -p "$(dirname "$IMG")" "$MNT" "$X11_DIR"
if [ ! -f "$IMG" ]; then
    truncate -s "$IMG_SIZE" "$IMG"
    mke2fs -t ext4 -F -L debian-gpu "$IMG"
else
    echo "    Image already exists at $IMG (reusing)."
fi

if ! mountpoint -q "$MNT"; then
    LOOP="$(losetup -f)"
    losetup "$LOOP" "$IMG"
    mount -t ext4 -o rw,suid,dev,exec,noatime "$LOOP" "$MNT"
fi
df -h "$MNT"

echo "==> [2/5] Extracting Debian 13 (trixie) arm64 rootfs..."
if [ ! -f "$MNT/etc/debian_version" ]; then
    if [ -f "$SETUP_DIR/debian-trixie-arm64.tar.zst" ]; then
        extract_archive "$SETUP_DIR/debian-trixie-arm64.tar.zst" "$MNT" "--numeric-owner"
    elif [ -f "$SETUP_DIR/debian-trixie-arm64.tar.xz" ]; then
        extract_archive "$SETUP_DIR/debian-trixie-arm64.tar.xz" "$MNT" "--numeric-owner"
    else
        echo "ERROR: Debian rootfs archive not found in $SETUP_DIR" >&2
        exit 1
    fi
else
    echo "    Debian rootfs already extracted in $MNT."
fi

echo "==> [3/5] Extracting patched Mesa 26.3.1 source into chroot /src..."
mkdir -p "$MNT/src"
if [ ! -d "$MNT/src/mesa-26.3.1" ] && [ ! -f "$MNT/opt/turnip-a850/share/vulkan/icd.d/freedreno_icd.aarch64.json" ]; then
    if [ -f "$SETUP_DIR/mesa-glibc-a850.tar.zst" ]; then
        extract_archive "$SETUP_DIR/mesa-glibc-a850.tar.zst" "$MNT/src"
    elif [ -f "$SETUP_DIR/mesa-glibc-a850.tar.xz" ]; then
        extract_archive "$SETUP_DIR/mesa-glibc-a850.tar.xz" "$MNT/src"
    else
        echo "ERROR: Patched Mesa archive not found in $SETUP_DIR" >&2
        exit 1
    fi
fi

echo "==> [4/5] Setting up bind mounts, DNS, hosts, and apt config..."
mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/tmp/.X11-unix" "$MNT/mnt/android"
mountpoint -q "$MNT/proc" || mount -t proc proc "$MNT/proc"
mountpoint -q "$MNT/sys" || mount -t sysfs sysfs "$MNT/sys"
mountpoint -q "$MNT/dev" || mount --bind /dev "$MNT/dev"
# /dev must be bind-mounted BEFORE creating /dev/pts and /dev/shm mount points
mkdir -p "$MNT/dev/pts" "$MNT/dev/shm"
mountpoint -q "$MNT/dev/pts" || mount --bind /dev/pts "$MNT/dev/pts"
mountpoint -q "$MNT/dev/shm" || mount -t tmpfs -o rw,nosuid,nodev,mode=1777 tmpfs "$MNT/dev/shm"
mountpoint -q "$MNT/tmp/.X11-unix" || mount --bind "$X11_DIR" "$MNT/tmp/.X11-unix"
mountpoint -q "$MNT/mnt/android" || mount --bind /storage/emulated/0 "$MNT/mnt/android"

rm -f "$MNT/etc/resolv.conf"
printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$MNT/etc/resolv.conf"
printf "127.0.0.1 localhost debian-gpu\n::1 localhost\n" > "$MNT/etc/hosts"
mkdir -p "$MNT/etc/apt/apt.conf.d"
echo 'APT::Sandbox::User "root";' > "$MNT/etc/apt/apt.conf.d/99no-sandbox"

echo "==> [5/5] Installing host manager (/data/adb/debian-gpu.sh) and staging in-chroot scripts..."
cp "$SETUP_DIR/debian-gpu.sh" /data/adb/debian-gpu.sh
chown root:root /data/adb/debian-gpu.sh
chmod 755 /data/adb/debian-gpu.sh

cp "$SETUP_DIR/03-install-and-build-chroot.sh" "$MNT/tmp/"
cp "$SETUP_DIR/setup-macos-desktop.sh" "$MNT/tmp/"
cp "$SETUP_DIR/verify-gpu.sh" "$MNT/usr/local/bin/verify-gpu"
cp "$SETUP_DIR/turnip-a850.sh" "$MNT/etc/profile.d/turnip-a850.sh"
chmod 755 "$MNT/tmp/03-install-and-build-chroot.sh" "$MNT/tmp/setup-macos-desktop.sh" "$MNT/usr/local/bin/verify-gpu"
chmod 644 "$MNT/etc/profile.d/turnip-a850.sh"

if [ "${NO_BUILD:-0}" = "1" ]; then
    echo "NO_BUILD=1 set. Run step 3 manually inside chroot when ready."
    exit 0
fi

echo "==> Entering Debian 13 chroot to install packages, compile Turnip, and configure desktop..."
chroot "$MNT" /usr/bin/env -i \
    HOME=/root \
    TERM=xterm-256color \
    DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash /tmp/03-install-and-build-chroot.sh

rm -f "$MNT/tmp/03-install-and-build-chroot.sh" "$MNT/tmp/setup-macos-desktop.sh"
rm -f "$SETUP_DIR/debian-trixie-arm64.tar."* "$SETUP_DIR/mesa-glibc-a850.tar."*

echo ""
echo "=================================================================="
echo " Bootstrap & build complete!"
echo " Start the desktop now with:"
echo "   su -c \"/data/adb/debian-gpu.sh start\""
echo " Verify GPU acceleration with:"
echo "   su -c \"/data/adb/debian-gpu.sh verify\""
echo "=================================================================="
