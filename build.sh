#!/bin/zsh
# AllTab'ı derler ve build/AllTab.app olarak paketler.
#
#   ./build.sh            → derle
#   ./build.sh install    → derle ve /Applications/AllTab.app olarak kur, başlat
#
# Signing identity, first match wins:
#   SIGN_IDENTITY env var → "Developer ID Application" → "Apple Development" → "AllTab Local Signing" (make-cert.sh) → ad-hoc.
# Ad-hoc signatures change on every build, so macOS drops Accessibility / Screen Recording permissions each time.
set -e
cd "$(dirname "$0")"
APP="build/AllTab.app"
IDS="$(security find-identity -v -p codesigning 2>/dev/null)"
pick() { echo "$IDS" | grep -o "\"$1[^\"]*\"" | head -1 | tr -d '"'; }
IDENTITY="${SIGN_IDENTITY:-}"
[ -z "$IDENTITY" ] && IDENTITY="$(pick 'Developer ID Application')"
[ -z "$IDENTITY" ] && IDENTITY="$(pick 'Apple Development')"
[ -z "$IDENTITY" ] && IDENTITY="$(pick 'AllTab Local Signing')"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift Screenshot.swift Gestures.swift Updater.swift \
  -o "$APP/Contents/MacOS/AllTab" \
  -framework AppKit -framework ScreenCaptureKit -framework ApplicationServices -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" --timestamp=none "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc (no certificate found; permissions reset on every rebuild, see README)"
fi
echo "Built: $APP"

if [ "$1" = "install" ]; then
  pkill -x AllTab 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/AllTab.app
  cp -R "$APP" /Applications/AllTab.app
  # LaunchServices kaydını yenile: macOS'un "Çık ve Yeniden Aç" düğmesi uygulamayı bundle id ile bulur
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -u "$PWD/$APP" >/dev/null 2>&1 || true
  "$LSREG" -f /Applications/AllTab.app >/dev/null 2>&1 || true
  open /Applications/AllTab.app
  echo "Installed and launched: /Applications/AllTab.app"
fi
