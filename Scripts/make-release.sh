#!/bin/bash
# Başkalarına dağıtılacak Mac sürümü: Developer ID imzası, hardened runtime, DMG ve Apple onayı
# (notarization). Mac App Store için değil; uygulama belgelenmemiş sistem işlevleri ve Erişilebilirlik
# kullandığı için oraya uygun değil (bkz. DISTRIBUTION.md).
#
#   ./Scripts/make-release.sh 2.0.0
#
# Bir kerelik hazırlık (hesap sahibi yapar, parola betiğe girmez):
#   1. Xcode > Settings > Accounts > Manage Certificates > "+" > Developer ID Application
#   2. xcrun notarytool store-credentials BERTH --apple-id <apple-id> --team-id <takım-kimliği>
#      (uygulamaya özel parola ister: appleid.apple.com > Giriş ve Güvenlik > Uygulamaya Özel Parolalar)
set -euo pipefail

VERSION="${1:?Sürüm verin, ör. 2.0.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP_NAME="Berth"
PROFILE="${BERTH_NOTARY_PROFILE:-BERTH}"

IDENTITY="$(security find-identity -v -p codesigning | grep -oE '"Developer ID Application[^"]*"' | tr -d '"' | head -1 || true)"
if [[ -z "$IDENTITY" ]]; then
  echo "Developer ID Application sertifikası yok. Yukarıdaki 1. adımı yapın." >&2
  exit 1
fi

# Sürüm Info.plist'e yazılır; derleme numarası tarih.
PLIST="$ROOT/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$PLIST"

BERTH_INSTALL_DIR="" BERTH_SIGN_IDENTITY="$IDENTITY" ./Scripts/make-app.sh release
APP="$ROOT/build/$APP_NAME.app"

# Hardened runtime ve güvenli zaman damgası onay için şart.
codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier io.github.brkhsdmr.berth "$APP"
codesign --verify --strict --verbose=2 "$APP"

DIST="$ROOT/build/dist"
mkdir -p "$DIST"
DMG="$DIST/Berth-$VERSION.dmg"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
  echo "Hazır ve onaylı: $DMG"
else
  echo "Onay profili '$PROFILE' yok; DMG imzalı ama onaysız: $DMG. Yukarıdaki 2. adımı yapın." >&2
fi
