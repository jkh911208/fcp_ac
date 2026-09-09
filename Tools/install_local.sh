#!/bin/bash
# Builds FCPCaption and installs it where Final Cut Pro should find it.
#
#   Tools/install_local.sh
#
# The last step is the one that matters. macOS discovers workflow extensions by scanning apps
# wherever they happen to be, **including build directories**, and the SDK release notes say
# outright that when several copies exist "which one the OS service will choose is undetermined".
# A build left in DerivedData is therefore not harmless: Final Cut Pro can pick it, and if it sits
# in a temporary directory the panel hangs on "Loading..." forever with no crash and no log.
#
# So this script deletes the built copy after installing, and then refuses to finish unless
# pluginkit lists exactly one registration, from /Applications.

set -euo pipefail

cd "$(dirname "$0")/.."
BUILD="$PWD/build/local"
APP="$BUILD/Build/Products/Release/FCPCaption.app"

echo "==> Building"
ruby Tools/generate_project.rb >/dev/null
xcodebuild -project FCPCaption.xcodeproj -scheme FCPCaption -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" build | tail -2

echo "==> Installing to /Applications"
pkill -f FCPCaptionExtension 2>/dev/null || true
rm -rf /Applications/FCPCaption.app
cp -R "$APP" /Applications/

echo "==> Removing the build copy so it cannot be discovered instead"
rm -rf "$BUILD"

echo "==> Registering"
# Ask LaunchServices to forget stale paths, then register the installed copy by launching it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
open -a /Applications/FCPCaption.app
sleep 3

echo "==> Checking what Final Cut Pro will find"
registrations=$(pluginkit -mAv 2>/dev/null | grep -i "FCPCaptionExtension.appex" || true)
echo "$registrations"
count=$(printf '%s\n' "$registrations" | grep -c "FCPCaptionExtension.appex" || true)
if [ "$count" -ne 1 ]; then
  echo "ERROR: expected exactly one registration, found $count. Final Cut Pro may load the wrong one." >&2
  exit 1
fi
if ! printf '%s' "$registrations" | grep -q "^/Applications/FCPCaption.app\|/Applications/FCPCaption.app"; then
  echo "ERROR: the registered copy is not the one in /Applications." >&2
  exit 1
fi

echo
echo "Installed. In Final Cut Pro: Window ▸ Extensions ▸ FCPCaption (close and reopen the panel)."
