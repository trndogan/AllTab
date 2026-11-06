#!/bin/zsh
# Builds AllTab, zips it as build/AllTab.zip and (with "publish") creates a GitHub release.
# The in-app updater downloads that zip, so a release is how an update reaches users.
#
#   ./release.sh            → build and zip only
#   ./release.sh publish    → also tag v<version> and publish it with the gh CLI
#
# Bump CFBundleShortVersionString in Info.plist first. The updater only installs apps signed by the
# official team (Updater.teamID), so build with that Developer ID certificate.
set -e
cd "$(dirname "$0")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
./build.sh
rm -f build/AllTab.zip
(cd build && ditto -c -k --keepParent AllTab.app AllTab.zip)
echo "Zipped: build/AllTab.zip (v$VERSION)"
if [ "$1" = "publish" ]; then
  gh release create "v$VERSION" build/AllTab.zip --title "AllTab $VERSION" --notes "${RELEASE_NOTES:-AllTab $VERSION}"
fi
