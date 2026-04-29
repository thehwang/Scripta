#!/bin/bash
set -e

APP="MeetingPilot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/build/dist"
APP_BUNDLE="$DIST_DIR/$APP.app"

cd "$PROJECT_DIR"

echo "=== Building $APP (release) ==="
swift build -c release 2>&1
BIN_PATH="$(swift build -c release --show-bin-path)"

echo ""
echo "=== Packaging $APP.app ==="
rm -rf "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp "$BIN_PATH/$APP" "$APP_BUNDLE/Contents/MacOS/$APP"
cp "Sources/MeetingPilot/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
mkdir -p "$APP_BUNDLE/Contents/Resources"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  Included AppIcon.icns"
fi

MLX_METALLIB="$(python3 -c 'import mlx; print(mlx.__path__[0])' 2>/dev/null)/lib/mlx.metallib" || true
if [ -f "$MLX_METALLIB" ]; then
    cp "$MLX_METALLIB" "$APP_BUNDLE/Contents/MacOS/mlx.metallib"
    echo "  Included mlx.metallib"
fi

echo ""
echo "=== Signing (ad-hoc, no certificate needed) ==="
xattr -cr "$APP_BUNDLE"
/usr/bin/codesign --force --sign - \
    --entitlements MeetingPilot-deploy.entitlements \
    --deep "$APP_BUNDLE"

echo ""
echo "=== Creating DMG ==="
DMG_PATH="$PROJECT_DIR/build/$APP.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP" \
    -srcfolder "$DIST_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

ZIP_PATH="$PROJECT_DIR/build/$APP-dist.zip"
rm -f "$ZIP_PATH"
cd "$DIST_DIR" && zip -r "$ZIP_PATH" "$APP.app"

echo ""
echo "============================================"
echo "  Distribution package ready!"
echo "============================================"
echo ""
echo "  DMG: build/$APP.dmg ($(du -h "$DMG_PATH" | cut -f1))"
echo "  ZIP: build/$APP-dist.zip ($(du -h "$ZIP_PATH" | cut -f1))"
echo ""
echo "  Install instructions (for recipient):"
echo "  1. Open the DMG or unzip"
echo "  2. Drag $APP.app to /Applications/"
echo "  3. Run:  xattr -cr /Applications/$APP.app"
echo "  4. Right-click → Open (first time only, to bypass Gatekeeper)"
echo "  5. Grant Microphone + Screen Recording permissions when prompted"
echo ""
