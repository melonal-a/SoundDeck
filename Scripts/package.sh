#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/SoundDeck.app"
STAGE="$ROOT/.build/dmg-stage"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$DIST/SoundDeck-$VERSION.dmg"

"$ROOT/Scripts/build.sh"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/SoundDeck.app"
ln -s /Applications "$STAGE/Applications"

/usr/bin/hdiutil create \
    -volname "SoundDeck" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

echo "Packaged: $DMG"
/usr/bin/hdiutil verify "$DMG" >/dev/null
ls -lh "$DMG"
