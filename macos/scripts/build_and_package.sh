#!/usr/bin/env bash
set -euo pipefail

# Zero-dependency macOS build & DMG packaging script.
# Requires ONLY macOS Command Line Tools (swiftc, codesign, iconutil, sips, hdiutil).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$MACOS_DIR/.." && pwd)"
BUILD_DIR="$MACOS_DIR/.build/release-manual"
DIST_DIR="$ROOT_DIR/dist"

APP_NAME="DropLink"
VERSION="1.0.0"
ARCH="$(uname -m)"
TARGET_TRIPLE="${ARCH}-apple-macos12.0"
SDK_PATH="$(xcrun --show-sdk-path)"

echo "==> Building DropLink v${VERSION} for macOS (${TARGET_TRIPLE})"
echo "    SDK: ${SDK_PATH}"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> [1/5] Compiling DropLinkCore static module..."
swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET_TRIPLE" \
  -O \
  -parse-as-library \
  -emit-module \
  -emit-library \
  -static \
  -module-name DropLinkCore \
  -emit-module-path "$BUILD_DIR/DropLinkCore.swiftmodule" \
  -o "$BUILD_DIR/libDropLinkCore.a" \
  "$MACOS_DIR"/Sources/DropLinkCore/*.swift

echo "==> [2/5] Compiling DropLinkTests and running automated verification..."
swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET_TRIPLE" \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lDropLinkCore \
  -o "$BUILD_DIR/DropLinkTests" \
  "$MACOS_DIR/Sources/DropLinkTests/main.swift"

"$BUILD_DIR/DropLinkTests"

echo "==> [3/5] Compiling DropLink macOS desktop executable..."
swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET_TRIPLE" \
  -O \
  -parse-as-library \
  -I "$BUILD_DIR" \
  -L "$BUILD_DIR" \
  -lDropLinkCore \
  -o "$BUILD_DIR/$APP_NAME" \
  "$MACOS_DIR"/Sources/DropLinkApp/*.swift

echo "==> [4/5] Assembling ${APP_NAME}.app bundle..."
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

python3 "$SCRIPT_DIR/generate_icon.py" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.droplink.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>DropLink uses your local Wi-Fi network to transfer encrypted files directly between your Mac and Android device.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 DropLink Contributors. MIT License.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> [5/5] Creating DMG installer..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-macOS-${ARCH}.dmg"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGING"

echo ""
echo "==> Build & Packaging Complete!"
echo "    App Bundle: $APP_BUNDLE"
echo "    DMG Image : $DMG_PATH"
shasum -a 256 "$DMG_PATH"
