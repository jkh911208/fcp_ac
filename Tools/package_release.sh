#!/bin/bash
# Builds, signs, notarizes and staples FCPCaption.pkg.
#
#   Tools/package_release.sh
#
# Everything it needs comes from the environment, so no secret is ever written into the repo:
#
#   FCPCAPTION_DEVELOPMENT_TEAM    your 10-character team id
#   FCPCAPTION_CODE_SIGN_IDENTITY  usually "Developer ID Application: NAME (TEAM)"
#   FCPCAPTION_INSTALLER_IDENTITY  usually "Developer ID Installer: NAME (TEAM)" — a different
#                                  certificate; a pkg cannot be signed with the Application one
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
STAGE="$ROOT/build/pkg-root"
COMPONENT="$ROOT/build/FCPCaption-component.pkg"
PKG="$ROOT/build/FCPCaption.pkg"

: "${FCPCAPTION_DEVELOPMENT_TEAM:?set FCPCAPTION_DEVELOPMENT_TEAM to your team id}"
: "${FCPCAPTION_CODE_SIGN_IDENTITY:?set FCPCAPTION_CODE_SIGN_IDENTITY, e.g. \"Developer ID Application: Name (TEAM)\"}"
: "${FCPCAPTION_INSTALLER_IDENTITY:?set FCPCAPTION_INSTALLER_IDENTITY, e.g. \"Developer ID Installer: Name (TEAM)\"}"

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

# Called twice, for the app and then for the pkg, because a ticket belongs to one artifact:
# stapling only the pkg leaves the app inside it without one, and the app is the part that
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

# A pkg, not a dmg, because of what a drag-install does to an update. A dmg's app arrives
# quarantined, and macOS will not load a quarantined app's extensions until someone launches the
# app once — so every update by drag made FCPCaption vanish from Final Cut Pro until the user
# thought to open an app they otherwise never open (seen on a second Mac, 2026-10-21). Installer
# writes its payload without quarantine, replaces the old copy without a Replace/Keep Both
# question, and registers the bundle, so an update is: open, Continue, Install, done.
echo "==> Building the installer"
rm -rf "$STAGE" "$COMPONENT" "$PKG"
mkdir -p "$STAGE"
# ditto, not cp -R: the stapled ticket has to survive the copy, and cp does not carry every piece
# of bundle metadata.
ditto "$APP" "$STAGE/FCPCaption.app"

# Relocation off. By default Installer looks for an app with the same bundle id anywhere on the
# disk and updates *that* — a copy in Downloads, an Xcode build in DerivedData — leaving
# /Applications stale while reporting success.
COMPONENT_PLIST="$ROOT/build/FCPCaption-component.plist"
pkgbuild --analyze --root "$STAGE" "$COMPONENT_PLIST" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENT_PLIST"
if [ "$(plutil -extract 0.BundleIsRelocatable raw "$COMPONENT_PLIST")" != "false" ]; then
  echo "ERROR: could not turn off relocation in $COMPONENT_PLIST." >&2
  exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
pkgbuild --root "$STAGE" --component-plist "$COMPONENT_PLIST" \
  --identifier com.jkh911208.FCPCaption.pkg --version "$APP_VERSION" \
  --install-location /Applications "$COMPONENT" >/dev/null
productbuild --package "$COMPONENT" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
  --sign "$FCPCAPTION_INSTALLER_IDENTITY" --timestamp "$PKG" >/dev/null
rm -f "$COMPONENT" "$COMPONENT_PLIST"

# Check the package that was actually built, not the settings that went into it.
echo "==> Confirming what the installer will put on disk"
EXPANDED="$ROOT/build/pkg-expanded"
rm -rf "$EXPANDED"
# It prints "write: Permission denied" while restoring ownership as a non-root user; harmless,
# and the exit status still stops the script on a real failure.
pkgutil --expand-full "$PKG" "$EXPANDED" 2>/dev/null
PACKAGE_INFO="$(find "$EXPANDED" -maxdepth 2 -name PackageInfo -print -quit)"
PAYLOAD_APP="$(find "$EXPANDED" -maxdepth 3 -type d -path "*/Payload/FCPCaption.app" -print -quit)"
if [ -z "$PACKAGE_INFO" ] || [ -z "$PAYLOAD_APP" ]; then
  echo "ERROR: could not find PackageInfo or the app in the expanded package." >&2
  exit 1
fi
if grep -q "<relocate>" "$PACKAGE_INFO"; then
  echo "ERROR: the package is relocatable — it could update a stray copy instead of /Applications." >&2
  exit 1
fi
if ! grep -q 'install-location="/Applications"' "$PACKAGE_INFO"; then
  echo "ERROR: the package does not install into /Applications." >&2
  exit 1
fi
if [ "$NOTARIZE" = 1 ]; then
  # The whole point of stapling the app first. If the payload lost the ticket, an offline first
  # launch would be blocked, and calling the release notarized would be false.
  if ! xcrun stapler validate "$PAYLOAD_APP"; then
    echo "ERROR: the app inside the package has no stapled ticket." >&2
    exit 1
  fi
fi
rm -rf "$EXPANDED"

if [ "$NOTARIZE" = 0 ]; then
  exit 0
fi

echo "==> Notarizing the installer"
notarize_and_staple "$PKG"

echo "==> Checking the result the way Gatekeeper will"
spctl --assess --type install -vv "$PKG"
spctl --assess --type execute -vv "$APP"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo
  echo "Done: $PKG"
  echo "To publish it:  Tools/package_release.sh <tag>   (or: gh release create <tag> $PKG)"
  exit 0
fi

echo "==> Publishing $VERSION"
# The asset name is load-bearing: the website picks the .pkg out of the latest release.
if gh release view "$VERSION" >/dev/null 2>&1; then
  gh release upload "$VERSION" "$PKG" --clobber
else
  gh release create "$VERSION" "$PKG" --title "FCPCaption ${VERSION#v}" --generate-notes
fi

echo
echo "Published: $(gh release view "$VERSION" --json url --jq .url)"
