# Berth: çalışma notları

macOS (Swift/AppKit) ve Windows 11 (C++20/Win32) için sabit yerleşimli pencere ve masaüstü genel görünümü. Ücretsiz, açık kaynak, GPL-3.0. Kullanıcıya genel bakış için README.md; kararların arkasındaki ölçümler için docs/mac-notes.md ve docs/windows-notes.md; sürüm çıkarma için docs/distribution.md.

Kökte `NOTES.local.md` varsa önce onu oku: makineler, uzak çalışma akışı ve açık işler orada (git dışı).

## Dil ve üslup

- Kullanıcıyla Türkçe konuşulur. Kod yorumları, günlükler ve commit iletileri Türkçe; README ve mağaza metinleri İngilizce (README.tr.md Türkçe karşılığı).
- Arayüz metinleri iki dilli: macOS'ta `tx("Türkçe", "English")` (Sources/BerthCore/Localization.swift), Windows'ta `tx(L"…", L"…")` (windows/src/app/text.h). Yeni metin eklerken iki dili birden yaz. Günlükler, `fatalError` ve pencere menüsü başlık eşleştirmeleri çevrilmez.
- Uygulama adları kullanıcının seçtiği dile göre: macOS'ta `InstalledApps.name(bundleURL:fallback:)`, Windows'ta paketli uygulamalar için AUMID ile Başlat menüsü adı.

## Derleme ve sınama

```bash
swift test                          # BerthCore yerleşim testleri
./Scripts/make-app.sh debug|release # derler, Apple Development kimliğiyle imzalar, /Applications'a kurar
```

İmza kimliği hep aynı kalmalı; ad-hoc imzada Erişilebilirlik ve Ekran Kaydı izinleri her derlemede sıfırlanır.

Windows (Visual Studio 2022+ C++ iş yükü):

```powershell
windows\scripts\build.ps1 Release -Version 1.0.0   # derleme + çekirdek testleri ("N kontrol, 0 hata")
windows\scripts\package.ps1 -Version 1.0.0         # build\dist altında Setup.exe ve .msix
windows\scripts\install.ps1
```

Kurulu Windows uygulaması: `%LOCALAPPDATA%\Programs\Berth\Berth.exe` (`--toggle`, `--settings`, `--quit`). Ayarlar `%APPDATA%\Berth\settings.ini`.

## Yapı

- `Sources/BerthCore`: platformdan bağımsız kurallar (hücre yerleşimi, yığınlar, arama sıralaması, düzen eşleştirme). AppKit içermez, testli.
- `Sources/Berth`: macOS uygulaması. Belgesiz API'ler (SkyLight, MultitouchSupport, CoreDock) `dlsym` ile çalışma anında aranır ve bulunamazsa sessizce devre dışı kalır; bu ilke korunmalı.
- `windows/src/core` testli çekirdek, `windows/src/app` uygulama (Direct2D, DWM önizlemeleri, `IVirtualDesktopManagerInternal`).

## Hata ayıklama kancaları

Yalnızca debug derlemesinde. macOS'ta `DistributedNotificationCenter` bildirimleri, ad öneki `io.github.brkhsdmr.berth.`:

| Bildirim | Nesne | İş |
|---|---|---|
| `toggle` | | sahneyi aç/kapat |
| `searchPreview` | sorgu (boş: kapat) | sahneyi aramayla aç |
| `settings`, `settingsPage` | sayfa raw değeri | ayarları aç |
| `dockPreview` | bundle id (boş: kapat) | o Dock simgesinin önizlemesini aç ve açık tut |
| `remoteToggle`, `layoutCapture`, `snapTest` | | köprü ve düzen sınamaları |

Ekran görüntüsü modu (debug): `defaults write io.github.brkhsdmr.berth mosaicPreviews -bool YES` önizlemeleri pikselleştirir ve pencere başlıklarını gizler; `demoApps` sahneyi verilen uygulamalarla sınırlar. Bitince `defaults delete … mosaicPreviews` ve release derlemesini yeniden kur.

Windows'ta debug derlemede `%APPDATA%\Berth\mosaic.on` dosyası varsa sahne önizlemeleri pikselleşir, başlık yerine uygulama adı görünür (`windows/src/app/demo.h`). Görev çubuğu önizlemesi bu moda dahil değil.

Günlük: `~/Library/Logs/Berth/dock.log`. Windows'ta `%APPDATA%\Berth\trace.on` dosyası varsa sahne yerleşimi `layout.txt`'ye yazılır (T: önizleme, D: masaüstü, N: yeni masaüstü, H: arama kutusu, A: köşe düğmeleri).

## Ekran görüntüleri (docs/images)

Gerçek kullanımdan alınır, kişisel içerik görünmez:
- Pencere içerikleri kaba bloklarla pikselleştirilir (önizleme genişliğine ~25 blok). Kısa metinler (makine adı, kod) pikselleştirilmez, düz kutuyla kapatılır: küçük bloklu kısa metin geri çözülebilir.
- Yarı saydam yüzeylerin (arama paneli, rozetler) arkasında kalan içeriğe dikkat; gerekirse sorgu ya da konum değiştirilerek çakışma önlenir.
- Ham görüntüler depoya girmez; yayından önce görüntüler kullanıcıya gösterilip onay alınır.

## Kurallar

- Doğrulanmamış işi push etme; force push yok. `origin` HTTPS (GitHub Desktop); push gerekiyorsa kullanıcıdan GitHub Desktop'ta "Push origin" istemek en kolayı.
- Kullanıcının açık belgelerine ve pencerelerine dokunma; parola girme; sistem ayarı değiştirmeden önce sor.
- "Mission Control" Apple'ın markası; ürün adında ya da tanıtımda ad olarak kullanılmaz.
