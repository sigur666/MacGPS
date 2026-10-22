#!/bin/zsh
# Builds MacGPS.app and the gpsbridge CLI in ./dist
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${VERSION:-1.0.0}
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=dist/MacGPS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj"
cp "$BIN/MacGPS" "$APP/Contents/MacOS/MacGPS"
cp "$BIN/gpsbridge" "$APP/Contents/Resources/gpsbridge"
cp "$BIN/gpsbridge" dist/gpsbridge

# App icons (rendered from Icons/svg via: swift Icons/render.swift)
ICON=${ICON:-1-skyplot}
[[ -f "Icons/icns/$ICON.icns" ]] || { echo "Unknown icon: $ICON (see Icons/icns)"; exit 1; }
cp "Icons/icns/$ICON.icns" "$APP/Contents/Resources/AppIcon.icns"
for f in Icons/png/*.png; do cp "$f" "$APP/Contents/Resources/icon-$(basename "$f")"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacGPS</string>
  <key>CFBundleDisplayName</key><string>MacGPS</string>
  <key>CFBundleIdentifier</key><string>local.macgps.MacGPS</string>
  <key>CFBundleExecutable</key><string>MacGPS</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.navigation</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 sigur666</string>
  <key>NSLocalNetworkUsageDescription</key><string>MacGPS can optionally share GPS data (NMEA) on the local network.</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Done: $PWD/$APP  and  $PWD/dist/gpsbridge"
