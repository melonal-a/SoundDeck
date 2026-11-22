#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/icon"
ICONSET="$WORK/AppIcon.iconset"
SOURCE="$WORK/AppIcon-1024.png"

mkdir -p "$ICONSET"
xcrun swift "$ROOT/Scripts/make-icon.swift" "$SOURCE"

for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" "64:icon_32x32@2x.png" \
            "128:icon_128x128.png" "256:icon_128x128@2x.png" "256:icon_256x256.png" \
            "512:icon_256x256@2x.png" "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
    SIZE="${spec%%:*}"
    NAME="${spec#*:}"
    /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/$NAME" >/dev/null
done

/usr/bin/iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "Built: $ROOT/Resources/AppIcon.icns"
