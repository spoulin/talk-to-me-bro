#!/bin/bash
# Builds "build/Talk to me Bro.app" from the Swift package.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Talk to me Bro.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BrowSpeaker" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
cp Resources/Readability.js "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Share extension ("Share › Lire avec Talk to me Bro"), built outside SwiftPM.
EXT="$APP/Contents/PlugIns/BrowSpeakerShare.appex"
mkdir -p "$EXT/Contents/MacOS"
OPT=$([ "$CONFIG" = release ] && echo -O || echo -Onone)
swiftc $OPT -module-name BrowSpeakerShare -application-extension \
    -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    ShareExtension/ShareViewController.swift -o "$EXT/Contents/MacOS/BrowSpeakerShare"
cp ShareExtension/Info.plist "$EXT/Contents/"
mkdir -p "$EXT/Contents/Resources"
cp -R ShareExtension/*.lproj "$EXT/Contents/Resources/"
codesign --force --sign - --entitlements ShareExtension/ShareExtension.entitlements "$EXT"

codesign --force --sign - "$APP"

echo "✓ $APP"
