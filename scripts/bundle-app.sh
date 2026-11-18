#!/bin/bash
# Builds fast-ios.app: the menu-bar app with the `fast-ios` command line tool
# inside it (Contents/MacOS/fast-ios). Output: .build/fast-ios.app
#
#   scripts/bundle-app.sh                 # universal (Apple silicon and Intel)
#   ARCHS=arm64 scripts/bundle-app.sh     # faster, Apple silicon only
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/bundle-app.sh
#
# The version comes from scripts/version.sh (FastIOSVersion.current in the CLI). Without SIGN_IDENTITY the app is signed
# ad hoc ("-"), which runs on this Mac; a downloaded copy is blocked by
# Gatekeeper until it is signed with a Developer ID and notarized
# (docs/launch/checklist.md).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(scripts/version.sh)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
ARCHS=${ARCHS:-"arm64 x86_64"}
IDENTITY=${SIGN_IDENTITY:--}

arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done
swift build -c release "${arch_flags[@]}" --product FastIOSBar
swift build -c release "${arch_flags[@]}" --product fast-ios
BIN=$(swift build -c release "${arch_flags[@]}" --show-bin-path)

APP=.build/fast-ios.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FastIOSBar" "$APP/Contents/MacOS/FastIOSBar"
cp "$BIN/fast-ios" "$APP/Contents/MacOS/fast-ios"
cp packaging/app/AppIcon.icns packaging/app/MenuBarIcon.png packaging/app/MenuBarIcon@2x.png "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md THIRD_PARTY_SIMSLIM_LICENSE LICENSE "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>fast-ios</string>
	<key>CFBundleExecutable</key><string>FastIOSBar</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>dev.fast-ios.app</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>fast-ios</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD}</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>MIT licence. Tiger from page-mascot by Kamran Ahmed (MIT).</string>
</dict>
</plist>
PLIST

# Inside out: the tool, then the app. A Developer ID build needs the
# hardened runtime and a secure timestamp for notarization.
if [ "$IDENTITY" = "-" ]; then
  sign=(codesign --force --sign -)
else
  sign=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
fi
"${sign[@]}" "$APP/Contents/MacOS/fast-ios"
"${sign[@]}" "$APP"
codesign --verify --strict "$APP"
echo "$APP ($VERSION, build $BUILD, signed with: $IDENTITY)"
