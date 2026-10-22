#!/bin/zsh
# Builds MacGPS.app and packages it with gpsbridge into dist/MacGPS-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${VERSION:-1.0.0}
NAME="MacGPS"
STAGE=dist/dmg
DMG="dist/$NAME-$VERSION.dmg"

VERSION=$VERSION ./build-app.sh

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE/Command Line Tool"
cp -R "dist/$NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp dist/gpsbridge "$STAGE/Command Line Tool/gpsbridge"
cp README.md "$STAGE/README.md"

# Volume icon (optional, needs SetFile from the Xcode command line tools)
if command -v SetFile >/dev/null; then
    cp "dist/$NAME.app/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
    SetFile -c icnC "$STAGE/.VolumeIcon.icns"
fi

hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ dist/tmp.dmg >/dev/null
if command -v SetFile >/dev/null; then
    DEV=$(hdiutil attach -readwrite -noverify -noautoopen dist/tmp.dmg | awk '/Apple_HFS/{print $1}')
    SetFile -a C "/Volumes/$NAME $VERSION"
    hdiutil detach "$DEV" >/dev/null
fi
hdiutil convert dist/tmp.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f dist/tmp.dmg
rm -rf "$STAGE"
codesign --force -s - "$DMG"

echo "Done: $PWD/$DMG ($(du -h "$DMG" | cut -f1))"
