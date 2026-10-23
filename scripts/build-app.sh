#!/bin/zsh
# Builds dist/AutoShareMount.app (universal: Apple Silicon + Intel) and a zip for GitHub Releases.
#
#   ./scripts/build-app.sh            ad-hoc signed (fine for your own Macs)
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
#                                     signed for distribution (then notarize the zip)
#   SIGN_ID=<Apple Development identity or its SHA-1>
#                                     stable identity for your own Macs (permissions survive updates)
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
BUNDLE_ID="${BUNDLE_ID:-io.github.autosharemount}"
APP="dist/AutoShareMount.app"

echo "→ Compiling (release, universal)…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AutoShareMount"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoShareMount"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AutoShareMount</string>
  <key>CFBundleDisplayName</key><string>AutoShareMount</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>AutoShareMount</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>AutoShareMount looks for Macs, PCs and network drives on your network and checks they're reachable before reconnecting.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_smb._tcp</string>
    <string>_afpovertcp._tcp</string>
    <string>_device-info._tcp</string>
  </array>
  <key>NSAppleEventsUsageDescription</key>
  <string>AutoShareMount uses “mount volume” to reconnect drives the same way Finder does.</string>
</dict>
</plist>
EOF

echo "→ Signing"
xattr -cr "$APP"   # Finder/provenance attributes break strict signature checks
if [[ "${SIGN_ID:-}" == *"Developer ID"* ]]; then
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
elif [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force -s "$SIGN_ID" "$APP"
else
  codesign --force -s - "$APP"
fi

echo "→ Zipping"
# Fixed name so https://github.com/<owner>/AutoShareMount/releases/latest/download/AutoShareMount.zip always works.
rm -f dist/AutoShareMount.zip
ditto -c -k --keepParent "$APP" dist/AutoShareMount.zip

echo
echo "Built $APP"
echo "Zip:  dist/AutoShareMount.zip"
