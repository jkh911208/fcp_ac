#!/bin/bash
# Builds, signs, notarizes and staples FCPCaption.dmg.
#
#   Tools/package_release.sh
#
# Everything it needs comes from the environment, so no secret is ever written into the repo:
#
#   FCPCAPTION_DEVELOPMENT_TEAM    your 10-character team id
#   FCPCAPTION_CODE_SIGN_IDENTITY  usually "Developer ID Application: NAME (TEAM)"
#   FCPCAPTION_NOTARY_PROFILE      a keychain profile made with `xcrun notarytool store-credentials`
#
# Without the notary profile it still builds and signs, and says what it skipped — a build that
# quietly skips notarization is a build that fails on someone else's Mac with a Gatekeeper dialog.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build/release"
APP="$BUILD/Build/Products/Release/FCPCaption.app"
STAGE="$ROOT/build/dmg"
DMG="$ROOT/build/FCPCaption.dmg"

: "${FCPCAPTION_DEVELOPMENT_TEAM:?set FCPCAPTION_DEVELOPMENT_TEAM to your team id}"
: "${FCPCAPTION_CODE_SIGN_IDENTITY:?set FCPCAPTION_CODE_SIGN_IDENTITY, e.g. \"Developer ID Application: Name (TEAM)\"}"

echo "==> Regenerating the project with the release identity"
ruby Tools/generate_project.rb >/dev/null

echo "==> Building Release"
rm -rf "$BUILD"
xcodebuild -project FCPCaption.xcodeproj -scheme FCPCaption -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" \
  build | tail -3

# The appex is signed before the app that contains it: signing the outer bundle first would be
# invalidated by touching the inner one afterwards.
echo "==> Signing"
codesign --force --timestamp --options runtime \
  --entitlements FCPCaptionExtension/FCPCaptionExtension.entitlements \
  --sign "$FCPCAPTION_CODE_SIGN_IDENTITY" \
  "$APP/Contents/PlugIns/FCPCaptionExtension.appex"
codesign --force --timestamp --options runtime \
  --entitlements FCPCaption/FCPCaption.entitlements \
  --sign "$FCPCAPTION_CODE_SIGN_IDENTITY" \
  "$APP"

echo "==> Verifying the signature before it goes anywhere"
codesign --verify --deep --strict --verbose=2 "$APP"
# The SDK does not work with library validation, so its absence is a requirement, not a slip.
if codesign -d -v "$APP/Contents/PlugIns/FCPCaptionExtension.appex" 2>&1 | grep -q "library-validation"; then
  echo "ERROR: library validation is enabled on the extension; Final Cut Pro will not load it." >&2
  exit 1
fi

echo "==> Building the disk image"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "FCPCaption" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$FCPCAPTION_CODE_SIGN_IDENTITY" "$DMG"

if [ -z "${FCPCAPTION_NOTARY_PROFILE:-}" ]; then
  echo "!! FCPCAPTION_NOTARY_PROFILE is not set — the dmg is signed but NOT notarized."
  echo "!! It will raise a Gatekeeper warning on any other Mac. See docs/RELEASE.md."
  exit 0
fi

echo "==> Notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$FCPCAPTION_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Checking the result the way Gatekeeper will"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Done: $DMG"
