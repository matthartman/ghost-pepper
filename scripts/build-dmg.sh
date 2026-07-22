#!/bin/bash
set -euo pipefail

APP_NAME="GhostPepper"
DMG_NAME="GhostPepper"
BUILD_DIR="build"
DMG_DIR="$BUILD_DIR/dmg"
SIGNING_IDENTITY="${GHOSTPEPPER_SIGNING_IDENTITY:-}"
TEAM_ID="${GHOSTPEPPER_TEAM_ID:-}"
SOURCE_ENTITLEMENTS="$(pwd)/GhostPepper/GhostPepper.entitlements"

# Get version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(pwd)/GhostPepper/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$(pwd)/GhostPepper/Info.plist")

echo "==> Building $APP_NAME v$VERSION (build $BUILD_NUMBER)..."

if [ -z "$SIGNING_IDENTITY" ] || [ -z "$TEAM_ID" ]; then
  echo "ERROR: Set GHOSTPEPPER_SIGNING_IDENTITY and GHOSTPEPPER_TEAM_ID before building a signed DMG."
  echo "Tip: put local signing overrides in Config/LocalSigning.xcconfig and export matching env vars for packaging."
  exit 1
fi

if [ "${GHOSTPEPPER_SKIP_PRIVACY_PREFLIGHT:-0}" != "1" ]; then
  ./scripts/privacy-security-preflight.sh
else
  echo "==> Skipping privacy/security preflight because GHOSTPEPPER_SKIP_PRIVACY_PREFLIGHT=1"
fi

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
# Sign nested code inside-out, leaving the app's main executable for the final
# bundle signature. Signing every executable independently invalidates the
# bundle signature after subsequent nested-code changes.
find "$APP_PATH" -name "*.xpc" -type d | while read -r xpc; do
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$xpc" 2>/dev/null || true
done
find "$APP_PATH" -name "*.framework" -type d | while read -r fw; do
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$fw" 2>/dev/null || true
done
# Sign the app itself last while preserving app capabilities needed at runtime.
ENTITLEMENTS_PLIST=$(mktemp)
cp "$SOURCE_ENTITLEMENTS" "$ENTITLEMENTS_PLIST"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTITLEMENTS_PLIST" >/dev/null 2>&1 || true
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Set :com.apple.security.temporary-exception.mach-lookup.global-name:0 ${BUNDLE_ID}-spks" "$ENTITLEMENTS_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :com.apple.security.temporary-exception.mach-lookup.global-name:1 ${BUNDLE_ID}-spki" "$ENTITLEMENTS_PLIST" >/dev/null 2>&1 || true
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
  xcrun stapler validate "$BUILD_DIR/$DMG_NAME.dmg"
  echo "  Notarization complete!"
else
  echo ""
  echo "WARNING: Notarization may have failed. Check output above."
  echo "If you haven't set up notarytool credentials, run:"
  echo "  xcrun notarytool store-credentials notarytool --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
  echo ""
  echo "ERROR: Refusing to continue without an accepted notarization."
  exit 1
fi

echo "==> Generating Sparkle signature..."
SPARKLE_SIGN="$BUILD_DIR/derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -x "$SPARKLE_SIGN" ]; then
  SPARKLE_SIGN=$(find ~/Library/Developer/Xcode/DerivedData/GhostPepper-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name sign_update -type f -perm +111 -print -quit 2>/dev/null || true)
fi
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
echo "  1. Review docs/pre-deploy-privacy-security.md and fresh Codex audit findings"
echo "  2. Update appcast.xml with version $VERSION, size $DMG_SIZE, and signature above"
echo "  3. Commit and push appcast.xml"
echo "  4. Create a GitHub release: gh release create v$VERSION $BUILD_DIR/$DMG_NAME.dmg --title \"Ghost Pepper v$VERSION 🌶️\""
