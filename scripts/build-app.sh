#!/bin/bash
# Builds "build/Talk to me Bro.app" from the Swift package.
# Usage: scripts/build-app.sh [release|debug]
#
# VERSION=1.2.0 scripts/build-app.sh  sets the version shown in the app; without it, the latest
#                                     git tag (v1.2.0 gives 1.2.0), or the one in Support/Info.plist.
# UNIVERSAL=1 scripts/build-app.sh    builds for both Apple silicon and Intel Macs, as releases do.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
PLISTBUDDY=/usr/libexec/PlistBuddy
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-$($PLISTBUDDY -c 'Print CFBundleShortVersionString' Support/Info.plist)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if [ -n "${UNIVERSAL:-}" ]; then
    ARCHS=(arm64 x86_64)
else
    ARCHS=("$(uname -m)")
fi

# One build per architecture, joined with lipo. (`swift build --arch arm64 --arch x86_64` goes
# through Xcode's build system, which fails on this Swift 6 package with GitHub's Xcode.)
APP_SLICES=()
for ARCH in "${ARCHS[@]}"; do
    swift build -c "$CONFIG" --arch "$ARCH"
    APP_SLICES+=("$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)/BrowSpeaker")
done

APP="build/Talk to me Bro.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${APP_SLICES[@]}" -output "$APP/Contents/MacOS/BrowSpeaker"
cp Support/Info.plist "$APP/Contents/"
cp Resources/Readability.js "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Share extension ("Share › Lire avec Talk to me Bro"), built outside SwiftPM, once per
# architecture, then joined into one binary.
EXT="$APP/Contents/PlugIns/BrowSpeakerShare.appex"
mkdir -p "$EXT/Contents/MacOS"
OPT=$([ "$CONFIG" = release ] && echo -O || echo -Onone)
SLICES=()
for ARCH in "${ARCHS[@]}"; do
    OUT="build/BrowSpeakerShare-$ARCH"
    swiftc $OPT -module-name BrowSpeakerShare -application-extension \
        -sdk "$(xcrun --show-sdk-path)" -target "$ARCH-apple-macos14.0" \
        -Xlinker -e -Xlinker _NSExtensionMain \
        ShareExtension/ShareViewController.swift -o "$OUT"
    SLICES+=("$OUT")
done
lipo -create "${SLICES[@]}" -output "$EXT/Contents/MacOS/BrowSpeakerShare"
rm -f "${SLICES[@]}"
cp ShareExtension/Info.plist "$EXT/Contents/"
mkdir -p "$EXT/Contents/Resources"
cp -R ShareExtension/*.lproj "$EXT/Contents/Resources/"

# The app and its extension show the same version.
for PLIST in "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist"; do
    $PLISTBUDDY -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
done

codesign --force --sign - --entitlements ShareExtension/ShareExtension.entitlements "$EXT"
codesign --force --sign - "$APP"

echo "✓ $APP $VERSION ($BUILD)"
