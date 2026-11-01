#!/bin/sh
# Builds nanoterm.app (macOS desktop version) and nanoterm-phone-macos-arm64.dmg
# in zig-out/package. This is the phone's app running as a desktop window,
# useful for testing without a simulator.
#
#   VERSION=0.1.0 sh mobile/package-macos.sh
#
# Signs with $CODESIGN_IDENTITY when set, else ad hoc.
set -eu
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

app=nanoterm-phone
version="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
version="${version#v}"
out=zig-out/package
bundle="$out/$app.app"
dmg="$out/$app-macos-arm64.dmg"

# Build for macOS (native desktop window).
min_macos=13.0
echo "Building $app $version for macOS..."
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos.$min_macos -Dcpu=apple_m1

# Check if the binary was built.
if [ ! -f "zig-out/bin/nanoterm" ]; then
  echo "Error: zig-out/bin/nanoterm not found. Build may have failed." >&2
  exit 1
fi

# Create the app bundle.
rm -rf "$out"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "zig-out/bin/nanoterm" "$bundle/Contents/MacOS/$app"

# Copy icon if it exists.
if [ -f "mobile/macos/AppIcon.icns" ]; then
  cp mobile/macos/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
elif [ -f "macos/AppIcon.icns" ]; then
  cp macos/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
fi

# Create Info.plist.
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$app</string>
  <key>CFBundleDisplayName</key><string>nanoterm (Phone)</string>
  <key>CFBundleIdentifier</key><string>com.justrach.nanoterm-phone</string>
  <key>CFBundleExecutable</key><string>$app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleGetInfoString</key><string>nanoterm phone client as desktop app</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>$min_macos</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign the app.
sign() {
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$1"
  else
    codesign --force --sign - "$1"
  fi
}

echo "Signing $app.app..."
sign "$bundle"

# Create the disk image.
echo "Creating DMG..."
stage="$out/dmg"
mkdir -p "$stage"
cp -R "$bundle" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$app" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$stage"

echo "Signing DMG..."
sign "$dmg"

# Generate checksum.
shasum -a 256 "$dmg" | tee "$dmg.sha256"

echo ""
echo "✓ Packaged successfully:"
echo "  App: $bundle"
echo "  DMG: $dmg"
echo "  SHA: $dmg.sha256"
