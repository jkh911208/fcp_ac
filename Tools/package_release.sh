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
# Pass a version to publish the result to GitHub Releases, which is only file hosting here — the
# build happens on this Mac because Apple's Workflow Extensions SDK lives here and cannot be
# installed on a hosted runner:
#
#   Tools/package_release.sh v0.1.0
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
# On CI the identity lives in a throwaway keychain, not the login one.
KEYCHAIN_ARGS=()
if [ -n "${FCPCAPTION_KEYCHAIN:-}" ]; then
  KEYCHAIN_ARGS=(--keychain "$FCPCAPTION_KEYCHAIN")
fi

echo "==> Signing"
codesign --force --timestamp --options runtime "${KEYCHAIN_ARGS[@]}" \
  --entitlements FCPCaptionExtension/FCPCaptionExtension.entitlements \
  --sign "$FCPCAPTION_CODE_SIGN_IDENTITY" \
  "$APP/Contents/PlugIns/FCPCaptionExtension.appex"
codesign --force --timestamp --options runtime "${KEYCHAIN_ARGS[@]}" \
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
codesign --force --timestamp "${KEYCHAIN_ARGS[@]}" --sign "$FCPCAPTION_CODE_SIGN_IDENTITY" "$DMG"

if [ -z "${FCPCAPTION_NOTARY_PROFILE:-}" ]; then
  echo "!! FCPCAPTION_NOTARY_PROFILE is not set — the dmg is signed but NOT notarized."
  echo "!! It will raise a Gatekeeper warning on any other Mac. See docs/RELEASE.md."
  exit 0
fi

echo "==> Notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$FCPCAPTION_NOTARY_PROFILE" \
  ${FCPCAPTION_KEYCHAIN:+--keychain "$FCPCAPTION_KEYCHAIN"} --wait
xcrun stapler staple "$DMG"

echo "==> Checking the result the way Gatekeeper will"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
xcrun stapler validate "$DMG"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo
  echo "Done: $DMG"
  echo "To publish it:  Tools/package_release.sh $VERSION   (or: gh release create <tag> $DMG)"
  exit 0
fi

echo "==> Publishing $VERSION"
# The asset name is load-bearing: the website links releases/latest/download/FCPCaption.dmg.
if gh release view "$VERSION" >/dev/null 2>&1; then
  gh release upload "$VERSION" "$DMG" --clobber
else
  gh release create "$VERSION" "$DMG" --title "FCPCaption ${VERSION#v}" --generate-notes
fi

echo
echo "Published: $(gh release view "$VERSION" --json url --jq .url)"
