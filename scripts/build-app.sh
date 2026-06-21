#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="codex监测"
PACKAGE_NAME="codex-monitor"
APP_VERSION="0.1.0"
BUNDLE_ID="com.alight.codexnotch"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_STAGE_DIR="$DIST_DIR/dmg-stage"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release
swift "$ROOT_DIR/scripts/generate-app-icon.swift"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/CodexNotch" "$MACOS_DIR/CodexNotch"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexNotch</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"

ARCHS="$(lipo -archs "$MACOS_DIR/CodexNotch" 2>/dev/null || true)"
ARCHS="${ARCHS#"${ARCHS%%[![:space:]]*}"}"
ARCHS="${ARCHS%"${ARCHS##*[![:space:]]}"}"
if [[ "$ARCHS" == *"arm64"* && "$ARCHS" == *"x86_64"* ]]; then
  DMG_ARCH="universal"
elif [[ -n "$ARCHS" ]]; then
  DMG_ARCH="${ARCHS// /-}"
else
  DMG_ARCH="$(uname -m)"
fi
DMG_PATH="$DIST_DIR/$PACKAGE_NAME-$APP_VERSION-$DMG_ARCH.dmg"
find "$DIST_DIR" -maxdepth 1 -type f \( -name "$APP_NAME.dmg" -o -name "$APP_NAME-*.dmg" -o -name "$PACKAGE_NAME-*.dmg" \) -delete

rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"
ditto "$APP_DIR" "$DMG_STAGE_DIR/$APP_NAME.app"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE_DIR" -ov -format UDZO "$DMG_PATH"

echo "Built $APP_DIR"
echo "Built $DMG_PATH"
