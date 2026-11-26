#!/bin/sh
# Builds both macOS (DMG) and Android (APK) packages for the phone app.
#
#   VERSION=0.1.0 sh mobile/package.sh
#
# This builds:
#   - zig-out/package/nanoterm-phone-macos-arm64.dmg (macOS desktop version)
#   - zig-out/android/nanoterm.apk (Android arm64)
set -eu
cd "$(dirname "$0")/.."

echo "========================================="
echo "Packaging nanoterm phone app"
echo "========================================="
echo ""

# Build macOS DMG.
echo "[1/2] Building macOS DMG..."
echo "-----------------------------------------"
sh mobile/package-macos.sh "$@"
echo ""

# Build Android APK.
echo "[2/2] Building Android APK..."
echo "-----------------------------------------"
sh mobile/package-android.sh "$@"
echo ""

echo "========================================="
echo "✓ All packages built successfully!"
echo "========================================="
echo ""
echo "Output files:"
ls -lh zig-out/package/nanoterm-phone-macos-arm64.dmg 2>/dev/null || true
ls -lh zig-out/android/nanoterm.apk 2>/dev/null || true
