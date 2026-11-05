#!/bin/zsh
# WinTab'ı derler ve build/WinTab.app olarak paketler.
#
#   ./build.sh            → derle
#   ./build.sh install    → derle ve /Applications/WinTab.app olarak kur, başlat
#
# İmza: SIGN_IDENTITY ortam değişkeni ya da "WinTab Yerel Imza" adlı yerel sertifika
# (bkz. make-cert.sh). İkisi de yoksa ad-hoc imzalanır; ad-hoc imza her derlemede
# değiştiği için macOS Erişilebilirlik / Ekran Kaydı izinlerini yeniden ister.
set -e
cd "$(dirname "$0")"
APP="build/WinTab.app"
IDENTITY="${SIGN_IDENTITY:-WinTab Yerel Imza}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift \
  -o "$APP/Contents/MacOS/WinTab" \
  -framework AppKit -framework ScreenCaptureKit -framework ApplicationServices -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
  echo "İmza: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "İmza: ad-hoc (sertifika yok, izinler her derlemede yenilenir; bkz. make-cert.sh)"
fi
echo "Hazır: $APP"

if [ "$1" = "install" ]; then
  pkill -x WinTab 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/WinTab.app
  cp -R "$APP" /Applications/WinTab.app
  open /Applications/WinTab.app
  echo "Kuruldu ve başlatıldı: /Applications/WinTab.app"
fi
