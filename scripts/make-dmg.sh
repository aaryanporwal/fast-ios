#!/bin/bash
# Builds dist/fast-ios-<version>.dmg (the app and an Applications link on a
# drag-to-install background) and dist/fast-ios-<version>.zip (for a Homebrew
# cask). Uses .build/fast-ios.app; run scripts/bundle-app.sh first, or pass
# --build to run it here.
#
# The window layout (icon places, background, size) is written straight into
# the image by scripts/write-ds-store.swift: no Finder scripting, no prompt.
# Fallback if a future macOS reads that file differently: LAYOUT=finder has
# Finder lay the window out instead (macOS asks once to let Terminal control
# Finder).
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${1:-}" = "--build" ] && scripts/bundle-app.sh

APP=.build/fast-ios.app
[ -d "$APP" ] || { echo "No $APP. Run scripts/bundle-app.sh first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
VOL="fast-ios"
OUT=dist
mkdir -p "$OUT"
DMG="$OUT/fast-ios-$VERSION.dmg"
ZIP="$OUT/fast-ios-$VERSION.zip"
work=$(mktemp -d)
trap 'hdiutil detach -quiet "/Volumes/$VOL" 2>/dev/null || true; rm -rf "$work"' EXIT

stage="$work/stage"
mkdir -p "$stage/.background"
ditto "$APP" "$stage/fast-ios.app"
ln -s /Applications "$stage/Applications"
cp packaging/dmg/background.tiff "$stage/.background/background.tiff"

hdiutil detach -quiet "/Volumes/$VOL" 2>/dev/null || true
hdiutil create -quiet -volname "$VOL" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$work/rw.dmg"
hdiutil attach -quiet -noautoopen "$work/rw.dmg"

if [ "${LAYOUT:-}" != "finder" ]; then
  swift scripts/write-ds-store.swift "/Volumes/$VOL"
else
  osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "fast-ios.app" of container window to {160, 205}
    set position of item "Applications" of container window to {480, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
fi
sync

chflags hidden "/Volumes/$VOL/.background" 2>/dev/null || true
hdiutil detach -quiet "/Volumes/$VOL"
rm -f "$DMG"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$DMG" "$ZIP"
