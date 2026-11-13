#!/bin/zsh
# Makes the disk image of a macOS app: the app, an Applications shortcut to drag it onto, and a
# background that says what to do the first time macOS asks about it.
# Needs dmgbuild: pip3 install dmgbuild (in a venv on CI).
# Usage: NAME="My App" COLORS="5A2A3E 2E1A4A 15102C" tools/make-dmg.sh <MyApp.app> <MyApp.dmg>
#   NAME: shown as the volume name and in "Drag NAME to Applications".
#   COLORS: optional, three hex colors for the background gradient.
set -e
cd "$(dirname "$0")/.."
APP=${1:?app bundle}
DMG=${2:?output dmg}
NAME=${NAME:-${APP:t:r}}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The background at 1x and 2x, joined into one TIFF so Retina screens get the sharp one.
swift tools/make-dmg-background.swift "$WORK/background.png" 1 "$NAME" ${=COLORS} >/dev/null
swift tools/make-dmg-background.swift "$WORK/background@2x.png" 2 "$NAME" ${=COLORS} >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

rm -f "$DMG"
dmgbuild -s tools/dmg-settings.py -D app="$APP" -D background="$WORK/background.tiff" "$NAME" "$DMG"
echo "Made $DMG"
