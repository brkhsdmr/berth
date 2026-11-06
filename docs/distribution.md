# Dağıtım

Berth ücretsiz ve açık kaynaktır (GPL-3.0). Bu belge sürüm çıkarmanın adımlarını ve mağazalar hakkındaki ölçümleri tutar. Ücret ve kurallar zamanla değişir; yayından önce Apple ve Microsoft'un güncel sayfalarından doğrulanmalı.

## Mac

### Mac App Store: uygun değil

App Store'daki her uygulama App Sandbox içinde çalışmak zorunda ve belgelenmemiş API kullanamaz (App Review Guidelines 2.5.1). Berth'in temel özellikleri bu iki kurala takılıyor:

| Özellik | Dayandığı | Sandbox / inceleme |
|---|---|---|
| Masaüstü şeridi, alan etiketleri | SkyLight (belgesiz) | 2.5.1'e takılır |
| 3/4 parmak ayrımı | MultitouchSupport (belgesiz) | 2.5.1'e takılır |
| Trackpad hareketini yakalama | CGEventTap, Dock olayı | Sandbox'ta izin yok |
| Yaslama, kapatma, küçültme, öne getirme | Erişilebilirlik ile başka uygulamaları yönetme | Sandbox'ta izin yok |
| Tam ekrana alıp sıraya yerleştirme | Mission Control'ü yapay fareyle sürükleme | 2.5.1 ve sandbox |

Benzer uygulamalar (AltTab, DockDoor, BetterTouchTool) da bu yüzden App Store dışında dağıtılıyor.

### GitHub Releases: Developer ID ve onay (notarization)

Apple Developer Program üyeliği (yıllık 99 USD) gerekir. Hesap sahibi bir kez:

1. Xcode > Settings > Accounts > Manage Certificates > "+" > Developer ID Application.
2. `xcrun notarytool store-credentials BERTH --apple-id <apple-id> --team-id <takım-kimliği>`. Uygulamaya özel parola ister; parola betiğe yazılmaz, anahtar zincirinde durur.

Sonra her sürüm için:

```bash
./Scripts/make-release.sh 1.0.0
```

Betik sürümü Info.plist'e yazar, hardened runtime ile imzalar, DMG hazırlar, Apple'a onaya gönderir ve onayı DMG'ye iliştirir. Onaylı DMG başka Mac'lerde "doğrulanamayan geliştirici" uyarısı vermez. DMG GitHub'daki sürüme eklenir.

Kaynaktan derleyenler imzasız derlemeyi de kullanabilir: macOS ilk açılışta uyarır, Sistem Ayarları > Gizlilik ve Güvenlik'ten "Yine de aç" ile açılır.

## Windows

### Microsoft Store: ücretsiz

Microsoft Store, Win32 uygulamalarını MSIX paketi olarak kabul ediyor; bireysel geliştirici hesabı ücretsiz ve Store paketi kendisi imzalar. Kurallarda belgelenmemiş Windows arayüzlerini yasaklayan açık bir madde yok, ama bir risk var: sanal masaüstü arayüzü (`IVirtualDesktopManagerInternal`) belgesiz ve Windows büyük güncellemelerinde kimliği değişebiliyor; değişince masaüstü şeridi ve taşıma çalışmaz, uygulamanın geri kalanı çalışır.

```powershell
windows\scripts\build.ps1 Release -Version 1.0.0
windows\scripts\package.ps1 -Version 1.0.0 -StoreName <Partner Center paket adı> -StorePublisher "CN=<yayıncı kimliği>"
```

`build\dist` altında iki dosya çıkar:
- `Berth-1.0.0-Setup.exe`: Inno Setup ile yönetici izni gerektirmeyen kurulum (GitHub Releases için).
- `Berth-1.0.0.msix`: Store'a yüklenecek paket. İmzasız; Store imzalar.

MSIX paketinde Run kayıt anahtarı çalışmaz. Ayarlardaki "Oturum açıldığında başlat" kutusu paketli sürümde paket bildirimindeki başlangıç görevini (StartupTask) açıp kapatır. Kullanıcı Görev Yöneticisi > Başlangıç uygulamaları'ndan kapattıysa uygulama yeniden açamaz, kutu bunu söyler.

### Yerelde deneme

İmzasız .msix kurulamıyor: Windows, tam güvenli (runFullTrust) paketlerde imza şartı koyuyor (`-AllowUnsigned` "unsigned package cannot include Executable activations" hatası veriyor). Geliştirici modu açıkken paket klasörü imzasız kaydedilebiliyor:

```powershell
Add-AppxPackage -Register windows\build\msix\AppxManifest.xml
Start-Process "shell:AppsFolder\<paket ailesi adı>!Berth"
Get-AppxPackage <paket adı> | Remove-AppxPackage   # kaldırma
```

Komutlar uzak oturumdan (SSH) değil, kullanıcının oturumundan çalıştırılmalı; yoksa "Access is denied" verir.

### Windows App Certification Kit

Klasörden kaydedilmiş pakette WACK testlerin çoğunu çalıştıramıyor ("manifest file could not be found"). Anlamlı iki sonuç çıktı:
- DPI farkındalığı bildirimde yoktu; `windows\packaging\app.manifest` ile eklendi.
- `ShellExecuteW` "süreç başlatan API" diye işaretlendi. Masaüstü (full trust) uygulamalarında izinli; ayarlar sayfasını açmak ve kapalı uygulamaları başlatmak için gerekli.

Partner Center paketi yükleyince aynı denetimleri kendisi yapıp sorunları sertifikasyondan önce gösteriyor.

### Store'a gönderme adımları

1. [Partner Center](https://partner.microsoft.com/dashboard)'da bireysel geliştirici hesabı.
2. "Berth" adını ayır; ürün kimliği sayfasındaki **Package/Identity/Name** ve **Package/Identity/Publisher** değerlerini al.
3. `package.ps1` ile bu değerlerle MSIX üret. Sürüm her gönderimde artmalı; dördüncü hane 0 kalmalı.
4. Mağaza metinleri: `store/listing.md`. Gizlilik politikası: `store/privacy.md` (GitHub'daki adresi verilir).
5. En az bir ekran görüntüsü (1366×768+), kişisel içerik görünmeyen bir masaüstünde.
6. "runFullTrust" kısıtlı yetenek; gerekçe `store/listing.md`'deki sertifikasyon notunda.

### Store dışı kurulum dosyası

İmzasız EXE indirilince SmartScreen "tanınmayan uygulama" uyarısı verir ("Ek bilgi > Yine de çalıştır"). İmzalamak için seçenekler: Azure Artifact Signing (ayda yaklaşık 10 USD, bireylere açık ülkeler sınırlı) ya da OV kod imzalama sertifikası (yıllık 200–400 USD). Açık kaynak projelere ücretsiz imzalama sunan kuruluşlar da var (örneğin SignPath Foundation); başvuru koşullarına bakılmalı.

## Destek

Proje ücretsiz; hiçbir özellik ücretli değildir. İsteyen GitHub Sponsors ile destek olabilir.

## Yayından önce

- **Ad:** "Mission Control" Apple'ın markası. Uygulama adında ve tanıtımda ad olarak kullanılmamalı; "Mission Control yerine" demek açıklayıcı kullanım olarak genelde sorun olmaz.
- **Gizlilik:** uygulama hiçbir veri toplamıyor ve göndermiyor. Ekran görüntüleri yalnızca bellekte tutuluyor. Ağ yalnızca kullanıcı açarsa, Mac ile Windows arasında yerel ağda ya da Tailscale'de kullanılıyor.
- **Güncelleme:** Mac'te Sparkle, Windows'ta Store güncellemesi ya da kurulum dosyasında sürüm denetimi eklenebilir.
