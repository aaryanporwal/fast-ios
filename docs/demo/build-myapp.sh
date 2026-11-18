#!/bin/bash
# Builds docs/demo/MyApp into <out>/MyApp.app for the iOS Simulator (arm64),
# with swiftc alone: no Xcode project. Usage: build-myapp.sh <out folder>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: build-myapp.sh <out folder>}"
app="$out/MyApp.app"
rm -rf "$app"
mkdir -p "$app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -parse-as-library -O \
  -target arm64-apple-ios18.0-simulator -sdk "$sdk" \
  "$here/MyApp/MyApp.swift" -o "$app/MyApp"
cp "$here/MyApp/Info.plist" "$app/Info.plist"
printf 'APPL????' > "$app/PkgInfo"
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1
echo "$app"
