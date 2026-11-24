#!/usr/bin/env bash
# Zero-Gradle Android SDK build script for Debian GPU Manager (com.debiangpu.manager).
# Requires: JDK 11+, Android SDK (build-tools + platforms), zip, and optionally python3-pil
#           (only needed if passing --regen-icons or if mipmap PNGs are missing).
#
# Usage:
#   ./build.sh [--regen-icons]
#
# Environment overrides:
#   ANDROID_HOME=~/Android/Sdk
#   BUILD_TOOLS_VERSION=35.0.0
#   ANDROID_API=35

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
BUILD="$DIR/build"

# Auto-detect latest installed build-tools & platform if not explicitly pinned
if [ -n "${BUILD_TOOLS_VERSION:-}" ]; then
    BT="$SDK/build-tools/$BUILD_TOOLS_VERSION"
else
    BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -n 1 || true)"
fi

if [ -n "${ANDROID_API:-}" ]; then
    PLATFORM="$SDK/platforms/android-${ANDROID_API}/android.jar"
else
    PLATFORM="$(ls "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -n 1 || true)"
fi

if [ -z "$BT" ] || [ ! -x "$BT/aapt2" ]; then
    echo "ERROR: Android SDK build-tools not found under $SDK/build-tools" >&2
    exit 1
fi
if [ -z "$PLATFORM" ] || [ ! -f "$PLATFORM" ]; then
    echo "ERROR: Android SDK platform android.jar not found under $SDK/platforms" >&2
    exit 1
fi

echo "==> Using build-tools: $BT"
echo "==> Using platform:    $PLATFORM"

rm -rf "$BUILD"
mkdir -p "$BUILD/gen" "$BUILD/obj" "$BUILD/res-compiled" "$BUILD/dex"

# 1. Generate launcher icons if missing or --regen-icons was passed
if [ "${1:-}" = "--regen-icons" ] || [ ! -f "$DIR/res/mipmap-xxxhdpi/ic_launcher.png" ]; then
    echo "==> Generating launcher icons..."
    python3 - << PYEOF
from PIL import Image, ImageDraw
import os

base = "$DIR/res"
for name, size in [("mipmap-hdpi", 72), ("mipmap-xhdpi", 96), ("mipmap-xxhdpi", 144), ("mipmap-xxxhdpi", 192)]:
    d = os.path.join(base, name)
    os.makedirs(d, exist_ok=True)
    S = 4
    W = size * S
    im = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    dr = ImageDraw.Draw(im)
    pad = int(W * 0.06)
    rad = int(W * 0.22)
    dr.rounded_rectangle((pad, pad, W - pad, W - pad), radius=rad, fill=(20, 23, 34, 255), outline=(92, 124, 224, 255), width=max(4, S * 2))
    dot_y = int(W * 0.25)
    dot_r = int(W * 0.042)
    for i, col in enumerate([(255, 95, 86, 255), (255, 189, 46, 255), (39, 201, 63, 255)]):
        cx = int(W * (0.24 + i * 0.12))
        dr.ellipse((cx - dot_r, dot_y - dot_r, cx + dot_r, dot_y + dot_r), fill=col)
    lw = max(8, int(W * 0.06))
    x0, y0 = int(W * 0.24), int(W * 0.48)
    xm, ym = int(W * 0.42), int(W * 0.60)
    y1 = int(W * 0.72)
    dr.line([(x0, y0), (xm, ym), (x0, y1)], fill=(122, 162, 247, 255), width=lw, joint="curve")
    dr.line([(int(W * 0.50), y1), (int(W * 0.74), y1)], fill=(125, 207, 255, 255), width=lw)
    im = im.resize((size, size), Image.Resampling.LANCZOS)
    im.save(os.path.join(d, "ic_launcher.png"), "PNG")
PYEOF
fi

# 2. Compile & link resources with aapt2
"$BT/aapt2" compile --dir "$DIR/res" -o "$BUILD/res-compiled/res.zip"
"$BT/aapt2" link \
    -I "$PLATFORM" \
    --manifest "$DIR/AndroidManifest.xml" \
    --java "$BUILD/gen" \
    -o "$BUILD/unaligned.apk" \
    "$BUILD/res-compiled/res.zip"

# 3. Compile Java sources (Java 11 bytecode for D8)
javac --release 11 \
    -classpath "$PLATFORM" \
    -d "$BUILD/obj" \
    "$BUILD/gen/com/debiangpu/manager/R.java" \
    "$DIR/src/com/debiangpu/manager/MainActivity.java"

# 4. Convert class files to DEX
# shellcheck disable=SC2046
"$BT/d8" --min-api 29 --lib "$PLATFORM" --output "$BUILD/dex" $(find "$BUILD/obj" -name '*.class')

# 5. Package classes.dex into APK
(cd "$BUILD/dex" && zip -q "$BUILD/unaligned.apk" classes.dex)

# 6. Align APK
"$BT/zipalign" -f -p 4 "$BUILD/unaligned.apk" "$BUILD/aligned.apk"

# 7. Sign APK (generates a local signing keystore if absent; gitignored)
KS="${KEYSTORE_PATH:-$DIR/local-debug.keystore}"
KS_PASS="${KEYSTORE_PASS:-debiangpu}"
if [ ! -f "$KS" ]; then
    keytool -genkeypair -v -keystore "$KS" -storepass "$KS_PASS" -keypass "$KS_PASS" \
        -alias debiangpu -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Debian GPU Manager,O=Local,C=US" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
    --out "$BUILD/DebianGPU.apk" "$BUILD/aligned.apk"
"$BT/apksigner" verify "$BUILD/DebianGPU.apk"

ls -lh "$BUILD/DebianGPU.apk"
echo "APK_BUILD_OK"
