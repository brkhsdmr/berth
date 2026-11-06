#!/bin/bash
# Paketi derler, imzalar ve /Applications'a kurar.
#   ./Scripts/make-app.sh [debug|release]
#
# Gerçek bir geliştirici kimliğiyle imzalanır: ad-hoc imzada macOS her derlemeyi başka
# bir uygulama sayar ve Ekran Kaydı / Erişilebilirlik izinleri sıfırlanır.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="io.github.brkhsdmr.berth"
APP_NAME="Berth"
EXE="Berth"
INSTALL_DIR="${BERTH_INSTALL_DIR-/Applications}"
SIGN_IDENTITY="${BERTH_SIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  ALL="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development[^"]*"' | tr -d '"')" || true
  REAL_NAME="$(id -F 2>/dev/null || true)"
  [[ -n "$REAL_NAME" ]] && SIGN_IDENTITY="$(printf '%s\n' "$ALL" | grep -F "$REAL_NAME" | head -1)" || true
  [[ -z "$SIGN_IDENTITY" ]] && SIGN_IDENTITY="$(printf '%s\n' "$ALL" | head -1)"
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$EXE" "$APP/Contents/MacOS/$EXE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
  echo "İmzalandı: $SIGN_IDENTITY"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "UYARI: geliştirici kimliği yok, ad-hoc imza. İzinler her derlemede sıfırlanır."
fi

if [[ -z "$INSTALL_DIR" ]]; then
  echo "Hazır: $APP (kurulum atlandı)"
  exit 0
fi

INSTALLED="$INSTALL_DIR/$APP_NAME.app"
pkill -f "$APP_NAME.app/Contents/MacOS/$EXE" 2>/dev/null && sleep 1 || true
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
echo "Kuruldu: $INSTALLED"
