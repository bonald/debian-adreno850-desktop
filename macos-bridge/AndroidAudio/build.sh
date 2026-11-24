#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SDK="${MACOS_SDK:-/home/admin/src/macOS-DroidVM/toolchains/sdks/MacOSX26.1.sdk}"
LD64="${LD64:-/home/admin/mac27-files/darwin-tools/bin/aarch64-apple-darwin-ld}"
LIPO="${LIPO:-/home/admin/mac27-files/darwin-tools/bin/aarch64-apple-darwin-lipo}"
OUT="$DIR/build/AndroidAudio.driver"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$DIR/Info.plist" "$OUT/Contents/Info.plist"

clang -target arm64-apple-macos15.0 -bundle -O2 -Wall -Wextra \
  -isysroot "$SDK" --ld-path="$LD64" \
  -framework CoreAudio -framework CoreFoundation \
  "$DIR/AndroidAudio.c" -o "$DIR/build/AndroidAudio.arm64"

clang -target arm64e-apple-macos15.0 -bundle -O2 -Wall -Wextra \
  -isysroot "$SDK" --ld-path="$LD64" \
  -framework CoreAudio -framework CoreFoundation \
  "$DIR/AndroidAudio.c" -o "$DIR/build/AndroidAudio.arm64e"

"$LIPO" -create "$DIR/build/AndroidAudio.arm64" "$DIR/build/AndroidAudio.arm64e" \
  -output "$OUT/Contents/MacOS/AndroidAudio"
chmod 755 "$OUT/Contents/MacOS/AndroidAudio"
file "$OUT/Contents/MacOS/AndroidAudio"
