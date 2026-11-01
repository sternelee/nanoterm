#!/bin/sh
# Builds nanoterm.apk for Android in zig-out/android.
#
#   VERSION=0.1.0 sh mobile/package-android.sh
#
# Requires Android SDK in $ANDROID_HOME with NDK and platform tools.
# Build for arm64 (aarch64) by default, or pass a different target.
set -eu
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

version="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
version="${version#v}"
target="${TARGET:-aarch64-linux-android}"
out=zig-out/android
apk="$out/nanoterm.apk"

# Set ANDROID_HOME if not set (common locations).
if [ -z "${ANDROID_HOME:-}" ]; then
  if [ -d "$HOME/Library/Android/sdk" ]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
  elif [ -d "$HOME/Android/Sdk" ]; then
    export ANDROID_HOME="$HOME/Android/Sdk"
  fi
fi

echo "Building nanoterm $version for Android ($target)..."

# Check for Android SDK.
if [ -z "${ANDROID_HOME:-}" ]; then
  echo "Warning: ANDROID_HOME not set. Build may fail if SDK is not found." >&2
fi

# Build the APK.
zig build -Doptimize=ReleaseSafe -Dtarget=$target

# Check if APK was created.
if [ ! -f "$apk" ]; then
  echo "Error: $apk not found. Build may have failed." >&2
  exit 1
fi

# Generate checksum.
shasum -a 256 "$apk" | tee "$apk.sha256"

echo ""
echo "✓ Packaged successfully:"
echo "  APK: $apk"
echo "  SHA: $apk.sha256"
echo ""
echo "To install on a connected device:"
echo "  adb install $apk"
echo ""
echo "To run on the device:"
echo "  adb shell am start -n com.justrach.nanoterm/android.app.NativeActivity \\"
echo "    --es nanoui.arg.0 --host --es nanoui.arg.1 127.0.0.1 \\"
echo "    --es nanoui.arg.2 --port --es nanoui.arg.3 4789 \\"
echo "    --es nanoui.arg.4 --token --es nanoui.arg.5 <32-char-token>"
