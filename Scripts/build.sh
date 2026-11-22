#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
BUILD_DIR="$ROOT/.build"
APP="$DIST/SoundDeck.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
MIN_MACOS="14.0"
ARCHS="${ARCHS:-arm64 x86_64}"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "Generating app icon..."
    "$ROOT/Scripts/make-icon.sh"
fi

mkdir -p "$DIST" "$BUILD_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINARIES=()
for ARCH in $ARCHS; do
    echo "Compiling for $ARCH..."
    OUT="$BUILD_DIR/SoundDeck-$ARCH"
    xcrun swiftc \
        -O \
        -whole-module-optimization \
        -swift-version 5 \
        -sdk "$SDK" \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -framework AppKit \
        -framework SwiftUI \
        -framework Combine \
        -framework CoreAudio \
        -framework AudioToolbox \
        -framework AVFoundation \
        "$ROOT"/Sources/*.swift \
        -o "$OUT"
    BINARIES+=("$OUT")
done

if [[ ${#BINARIES[@]} -eq 1 ]]; then
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/SoundDeck"
else
    xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/SoundDeck"
fi

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/SoundDeck"

/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null

echo
echo "Built: $APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/lipo -info "$APP/Contents/MacOS/SoundDeck"
