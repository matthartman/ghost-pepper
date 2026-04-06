#!/bin/bash
set -euo pipefail

APP_NAME="GhostPepper"
DMG_NAME="GhostPepper"
BUILD_DIR="build"
DMG_DIR="$BUILD_DIR/dmg"
SIGNING_IDENTITY="Developer ID Application: Matthew Hartman (BBVMGXR9AY)"
TEAM_ID="BBVMGXR9AY"
SOURCE_ENTITLEMENTS="$(pwd)/GhostPepper/GhostPepper.entitlements"

# Get version from Info.plist
VERSION=$(defaults read "$(pwd)/GhostPepper/Info.plist" CFBundleShortVersionString)
BUILD_NUMBER=$(defaults read "$(pwd)/GhostPepper/Info.plist" CFBundleVersion)

echo "==> Building $APP_NAME v$VERSION (build $BUILD_NUMBER)..."

echo "==> Cleaning..."
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_DIR"

echo "==> Building release (signed with Developer ID)..."
xcodebuild -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  build 2>&1 | tail -5

APP_PATH="$BUILD_DIR/derived/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Build failed — $APP_PATH not found"
  exit 1
fi

echo "==> Re-signing app and frameworks with hardened runtime..."
# Strip debug entitlements and re-sign everything with timestamp + hardened runtime
find "$APP_PATH" -type f -perm +111 -o -name "*.dylib" -o -name "*.framework" | while read -r binary; do
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$binary" 2>/dev/null || true
done
# Sign XPC services
find "$APP_PATH" -name "*.xpc" -type d | while read -r xpc; do
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$xpc" 2>/dev/null || true
done
# Sign frameworks
find "$APP_PATH" -name "*.framework" -type d | while read -r fw; do
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$fw" 2>/dev/null || true
done
# Sign the app itself last while preserving app capabilities needed at runtime.
ENTITLEMENTS_PLIST=$(mktemp)
cp "$SOURCE_ENTITLEMENTS" "$ENTITLEMENTS_PLIST"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTITLEMENTS_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$ENTITLEMENTS_PLIST" >/dev/null 2>&1 || true
codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS_PLIST" "$APP_PATH"
rm "$ENTITLEMENTS_PLIST"

echo "==> Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH" 2>&1 && echo "  Signature valid." || echo "  WARNING: Signature verification failed!"
codesign -dvv "$APP_PATH" 2>&1 | grep "Authority\|TeamIdentifier\|Runtime" | head -5

echo "==> Preparing DMG contents..."
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

echo "==> Creating DMG..."
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov -format UDZO \
  "$BUILD_DIR/$DMG_NAME.dmg"

echo "==> Signing DMG..."
codesign --sign "$SIGNING_IDENTITY" "$BUILD_DIR/$DMG_NAME.dmg"

echo "==> Notarizing..."
NOTARIZE_OUTPUT=$(xcrun notarytool submit "$BUILD_DIR/$DMG_NAME.dmg" \
  --keychain-profile "notarytool" \
  --wait 2>&1) || true
echo "$NOTARIZE_OUTPUT"

if echo "$NOTARIZE_OUTPUT" | grep -q "status: Accepted"; then
  echo "==> Stapling notarization ticket..."
  xcrun stapler staple "$BUILD_DIR/$DMG_NAME.dmg"
  echo "  Notarization complete!"
else
  echo ""
  echo "WARNING: Notarization may have failed. Check output above."
  echo "If you haven't set up notarytool credentials, run:"
  echo "  xcrun notarytool store-credentials notarytool --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
  echo ""
  echo "Continuing without notarization..."
fi

echo "==> Generating Sparkle signature..."
SPARKLE_SIGN=$(find ~/Library/Developer/Xcode/DerivedData/GhostPepper-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1)
if [ -n "$SPARKLE_SIGN" ]; then
  SIGNATURE=$("$SPARKLE_SIGN" "$BUILD_DIR/$DMG_NAME.dmg" 2>&1)
  echo "$SIGNATURE"
  echo ""
  echo "Add this to the appcast.xml <enclosure> tag:"
  echo "  $SIGNATURE"
else
  echo "WARNING: sign_update not found — run a build in Xcode first to fetch Sparkle"
fi

echo "==> Cleaning up..."
rm -rf "$DMG_DIR" "$BUILD_DIR/derived"

DMG_SIZE=$(stat -f%z "$BUILD_DIR/$DMG_NAME.dmg")

echo ""
echo "Done! DMG is at: $BUILD_DIR/$DMG_NAME.dmg ($DMG_SIZE bytes)"
echo ""
echo "Next steps:"
echo "  1. Update appcast.xml with version $VERSION, size $DMG_SIZE, and signature above"
echo "  2. Commit and push appcast.xml"
echo "  3. Create a GitHub release: gh release create v$VERSION $BUILD_DIR/$DMG_NAME.dmg --title \"Ghost Pepper v$VERSION 🌶️\""
