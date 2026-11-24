#!/bin/bash
# Step 3 (Runs automatically inside the Debian 13 chroot via 02-bootstrap-chroot.sh):
#   1. Creates Android network groups (aid_inet=3003, aid_net_raw=3004) & user 'droid'
#   2. Installs XFCE4 + Plank macOS desktop, TigerVNC/noVNC, Mesa Zink, and Turnip build deps
#   3. Compiles glibc Mesa 26.3.1 Turnip (KGSL, X11) and installs to /opt/turnip-a850
#   4. Configures the macOS-style dark desktop, traffic-light xfwm4 theme, and Plank glass dock
#
# Environment overrides:
#   DESKTOP_USER=droid    Linux user created in chroot
#   MESA_VERSION=26.3.1   Mesa source directory under /src/mesa-${MESA_VERSION}
#   BUILD_JOBS=8          Parallel ninja jobs (default: nproc)
#   KEEP_MESA_SRC=0       Set to 1 to keep /src/mesa-* after install

set -euo pipefail

DESKTOP_USER="${DESKTOP_USER:-droid}"
MESA_VERSION="${MESA_VERSION:-26.3.1}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
KEEP_MESA_SRC="${KEEP_MESA_SRC:-0}"
MESA_SRC="/src/mesa-${MESA_VERSION}"

echo "==> [1/4] Setting up Android network groups and user '${DESKTOP_USER}'..."
groupadd -g 3003 -f aid_inet
groupadd -g 3004 -f aid_net_raw
usermod -aG aid_inet,aid_net_raw root

if ! id "$DESKTOP_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -u 1000 -G sudo,video,render,aid_inet,aid_net_raw "$DESKTOP_USER"
    echo "${DESKTOP_USER}:${DESKTOP_USER}" | chpasswd
fi

mkdir -p /etc/sudoers.d
echo "${DESKTOP_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${DESKTOP_USER}"
chmod 440 "/etc/sudoers.d/${DESKTOP_USER}"

echo "==> [2/4] Installing Debian 13 desktop, VNC/noVNC, Zink, and Mesa build packages..."
apt-get update -q
apt-get install -y -q --no-install-recommends \
    sudo ca-certificates curl git neovim tmux btop fzf ripgrep openssh-client procps iproute2 \
    dbus-x11 x11-xserver-utils x11-utils xdg-utils python3 python3-pil \
    xfce4-session xfce4-panel xfwm4 xfdesktop4 xfce4-settings xfconf \
    xfce4-whiskermenu-plugin xfce4-genmon-plugin xfce4-terminal \
    thunar mousepad xfce4-taskmanager xfce4-notifyd \
    plank dconf-cli libglib2.0-bin gsettings-desktop-schemas \
    xdg-desktop-portal xdg-desktop-portal-gtk kitty rofi \
    gnome-themes-extra adwaita-icon-theme papirus-icon-theme \
    fonts-cantarell fonts-jetbrains-mono fonts-dejavu librsvg2-common \
    mesa-utils vulkan-tools glmark2-x11 \
    libgl1-mesa-dri libegl-mesa0 libglx-mesa0 mesa-vulkan-drivers \
    tigervnc-scraping-server tigervnc-tools novnc python3-websockify socat \
    build-essential meson ninja-build pkg-config bison flex \
    python3-mako python3-yaml python3-packaging glslang-tools \
    libdrm-dev libx11-dev libx11-xcb-dev libxcb1-dev libxcb-dri3-dev \
    libxcb-present-dev libxcb-shm0-dev libxcb-xfixes0-dev libxcb-randr0-dev \
    libxcb-sync-dev libxcb-keysyms1-dev libxshmfence-dev libxext-dev \
    libxfixes-dev libxrandr-dev libexpat1-dev zlib1g-dev libzstd-dev libarchive-dev

echo "==> [3/4] Compiling glibc Mesa ${MESA_VERSION} Turnip (KGSL, X11) into /opt/turnip-a850..."
if [ -d "$MESA_SRC" ]; then
    cd "$MESA_SRC"
    rm -rf build
    # Note: -Dplatforms=x11 avoids Debian 13's older wayland-scanner rejecting wayland-protocols 1.49 XML
    meson setup build --prefix=/opt/turnip-a850 \
        -Dbuildtype=release -Db_ndebug=true \
        -Dplatforms=x11 \
        -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl \
        -Dgallium-drivers= -Dopengl=false -Degl=disabled -Dgbm=disabled -Dglx=disabled \
        -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled -Dxmlconfig=disabled \
        -Dvalgrind=disabled -Dlibunwind=disabled -Dvulkan-layers= -Dtools= -Dmesa-clc=auto
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build install
    ls -la /opt/turnip-a850/lib/ /opt/turnip-a850/share/vulkan/icd.d/

    if [ "$KEEP_MESA_SRC" != "1" ]; then
        cd /
        rm -rf "$MESA_SRC"
    fi
else
    echo "    Skipping Mesa build ($MESA_SRC not present)."
fi

echo "==> [4/4] Configuring macOS-style XFCE4 + Plank desktop..."
if [ -f /tmp/setup-macos-desktop.sh ]; then
    DESKTOP_USER="$DESKTOP_USER" bash /tmp/setup-macos-desktop.sh
fi

echo "In-chroot setup and Turnip build complete."
