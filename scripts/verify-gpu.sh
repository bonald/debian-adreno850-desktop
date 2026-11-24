#!/bin/bash
# Verify bare-metal Adreno 850 Vulkan 1.4 (Turnip) + OpenGL 4.6 (Zink) inside the chroot.
# Usage: verify-gpu [--bench]
set -euo pipefail

if [ -f /etc/profile.d/turnip-a850.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/turnip-a850.sh
fi

echo "=== CPU ==="
lscpu | grep -E "Architecture|CPU\(s\):|Vendor ID|CPU max MHz|CPU min MHz" || true

echo ""
echo "=== Vulkan (Turnip KGSL) ==="
vulkaninfo --summary 2>&1 | grep -E "apiVersion|deviceName|driverName|driverInfo" || true

echo ""
echo "=== OpenGL (Zink over Turnip) ==="
glxinfo -B 2>&1 | grep -E "Accelerated|renderer string|core profile version|^OpenGL version" || true

if [ "${1:-}" = "--bench" ]; then
    echo ""
    echo "=== glmark2 --off-screen (1280x720) ==="
    glmark2 --off-screen -s 1280x720 \
        -b build:duration=2 \
        -b texture:duration=2 \
        -b shading:shading=phong:duration=2 \
        -b terrain:duration=2 \
        2>&1 | grep -E "FPS|Score|Renderer|Version"
fi
