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
# Written so the empty case expands to nothing: macOS's bash 3.2 calls a bare "${arr[@]}" an
# unbound variable under `set -u`, so an unguarded expansion breaks every local release.
KEYCHAIN_ARGS=()
if [ -n "${FCPCAPTION_KEYCHAIN:-}" ]; then
  KEYCHAIN_ARGS=(--keychain "$FCPCAPTION_KEYCHAIN")
fi

echo "==> Signing"
codesign --force --timestamp --options runtime ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
  --entitlements FCPCaptionExtension/FCPCaptionExtension.entitlements \
  --sign "$FCPCAPTION_CODE_SIGN_IDENTITY" \
  "$APP/Contents/PlugIns/FCPCaptionExtension.appex"
codesign --force --timestamp --options runtime ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
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

# Called twice, for the app and then for the dmg, because a ticket belongs to one artifact:
# stapling only the dmg leaves the app inside it without one, and the app is the part that
# survives installation. Gatekeeper then has to ask Apple over the network the first time it is
# launched — which is exactly the moment a new user is least able to diagnose a failure.
#
# $1 is submitted to Apple, $2 is where the ticket is stapled. They differ for the app, because
# notarytool takes an archive while stapler takes the bundle; the ticket is looked up by the
# code's hash, so an archive of the app earns a ticket the app itself can carry.
notarize_and_staple() {
  local submit="$1"
  local staple_to="${2:-$1}"
  xcrun notarytool submit "$submit" --keychain-profile "$FCPCAPTION_NOTARY_PROFILE" \
    ${FCPCAPTION_KEYCHAIN:+--keychain "$FCPCAPTION_KEYCHAIN"} --wait
  xcrun stapler staple "$staple_to"
  xcrun stapler validate "$staple_to"
}

NOTARIZE=1
if [ -z "${FCPCAPTION_NOTARY_PROFILE:-}" ]; then
  NOTARIZE=0
  echo "!! FCPCAPTION_NOTARY_PROFILE is not set — this build will be signed but NOT notarized."
  echo "!! It will raise a Gatekeeper warning on any other Mac. See docs/RELEASE.md."
fi

if [ "$NOTARIZE" = 1 ]; then
  echo "==> Notarizing the app (this takes a few minutes)"
  # notarytool takes an archive, not a bundle. ditto is what Apple documents here; zip(1) does not
  # preserve symlinks inside the bundle and the submission is rejected.
  rm -f "$BUILD/FCPCaption.zip"
  ditto -c -k --keepParent "$APP" "$BUILD/FCPCaption.zip"
  notarize_and_staple "$BUILD/FCPCaption.zip" "$APP"
  rm -f "$BUILD/FCPCaption.zip"
fi

echo "==> Building the disk image"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# ditto, not cp -R: the stapled ticket has to survive the copy into the image, and cp does not
# carry every piece of bundle metadata.
ditto "$APP" "$STAGE/FCPCaption.app"
ln -s /Applications "$STAGE/Applications"

if [ "$NOTARIZE" = 1 ]; then
  # The whole point of this release. If the copy lost the ticket, the dmg is no better than the
  # one before it, and saying "notarized" about it would be false.
  echo "==> Confirming the app in the image still carries its ticket"
  if ! xcrun stapler validate "$STAGE/FCPCaption.app"; then
    echo "ERROR: the staged app has no stapled ticket — an offline first launch would be blocked." >&2
    exit 1
  fi
fi

hdiutil create -volname "FCPCaption" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$FCPCAPTION_CODE_SIGN_IDENTITY" "$DMG"

if [ "$NOTARIZE" = 0 ]; then
  exit 0
fi

echo "==> Notarizing the disk image"
notarize_and_staple "$DMG"

echo "==> Checking the result the way Gatekeeper will"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type execute -vv "$APP"

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
