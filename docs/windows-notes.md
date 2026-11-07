# Berth, Windows 11: mühendislik notları

Mac sürümünün C++ karşılığı: Win32, DWM önizlemeleri, Direct2D. Çerçeve yok, tek `.exe`.

```powershell
windows\scripts\build.ps1
windows\scripts\install.ps1
```

Açmak için Alt+Shift+Space ya da tepsi simgesi. Kapatmak için Esc, boşluğa tıklama ya da aynı kısayol.

Sahnede: arama kutusuna tıklanır ya da yazılır (Ctrl+V yapıştırır); oklar önizlemeler arasında gezer, Enter seçilene geçer; Ctrl+1…9 o masaüstüne geçer. Şeritteki masaüstü kartları, o masaüstündeki pencerelerin DWM önizlemeleriyle kurulur. Birden çok ekranda, sahnenin ekranı dışındaki pencerenin rozetinde "Ekran N" yazar.

Tepsi menüsü > Çalışma düzenini kaydet / yükle / sil: tüm masaüstlerindeki pencerelerin masaüstü, yer, boyut ve küçültülme durumu `%APPDATA%\Berth\layouts.txt` dosyasına yazılır.

Mac'ten hareket: Ayarlar'a Mac'in adı ve Mac'teki eşleştirme kodu girilince uygulama Mac'e bağlanır (`remote.cpp`); Mac'te Windows App'te bu bilgisayar öndeyken yukarı kaydırma buradaki sahneyi açar. Bağlantıyı Windows açar, güvenlik duvarı kuralı gerekmez.

Dil: Türkçe ve İngilizce (`src/app/text.h`); Windows'un görüntü diline uyar, Ayarlar > Kullanım > Dil'den değişir.

Paketleme: `scripts\build.ps1 Release -Version 1.0.0` simge ve sürüm bilgisini gömer; `scripts\package.ps1` Inno Setup kurulumu ve Store için MSIX üretir (`build\dist`). Ayrıntı: `docs/distribution.md`.

Tepsi simgesine sağ tık > Ayarlar (ya da `Berth.exe --settings`): kısayolu açma/kapatma ve değiştirme, sıcak köşe ve bekleme süresi, görev çubuğu önizlemesi, oturum açılınca başlatma, sabit uygulamaların sırası ve boyutu. Ayarlar `%APPDATA%\Berth\settings.ini` dosyasında. Dokunmatik yüzey hareketini Windows kendisi işler; üç ya da dört parmakla yukarı kaydırma Windows Ayarları'nda "Özel kısayol" yapılıp uygulamanın kısayoluna atanır.

Sahnede: önizleme köşesinde sola/sağa yaslama, ekranı kapla, görev çubuğuna küçült ve kapat; önizlemeyi şeritte bir masaüstüne ya da "+" üzerine sürükleme; şeritteki masaüstünü sürükleyip sıralama; yazarak arama; hücreye sağ tıkla taşıma, boyut ve sabitleme.

## Yapı

- `windows/src/core`: yerleşim kuralları, platform bağımsız. `windows/tests/core_tests.cpp` Mac'te de derlenir.
- `windows/src/app/vdesktop`: belgesiz sanal masaüstü arayüzü, yalnızca burada. Kimlikler değişirse şerit kaybolur, uygulama çalışır.
- `windows/src/app/source`: pencere ve masaüstü listesi.
- `windows/src/app/main`: arka pencere zemini çizer ve önizlemeleri taşır, ön pencere önizlemelerin üstündeki öğeleri çizer ve fareyi alır.

## Sahnede kaydırma ve sıralama

Davranış Mac'teki gibidir (docs/mac-notes.md). Windows'a özgü olanlar:

- **Kırpma kaynaktan yapılır.** DWM önizlemesi pencerenin üstünde çizilir, Direct2D kırpması ona etki etmez. Yarım görünen önizlemenin kaynak dikdörtgeni kesilir, tamamen görünmeyen gizlenir (`placeThumbnail`).
- **Yerler iki uzayda.** `Tile.page` ve `Hit.page` sayfa uzayında, `target` ve `rect` görünen yerdir; `applyScroll` ikisini eşitler. Mevcut fare kodu görünen yerle çalışmaya devam eder.
- **Akıcılık.** Tekerlek hedefi değiştirir, 15 ms'lik zamanlayıcı yumuşatır. Bulanık duvar kağıdı bir kez çizilip saklanır, yoksa her karede yeniden hesaplanırdı.
- **Sürükleme.** Önizleme şeritte bir masaüstüne bırakılırsa pencere taşınır, hücrelerin arasına bırakılırsa sıra değişir. Etiket ve boş hücre yalnızca sıralar.

## Windows 11 25H2 (26200) üzerinde ölçülenler

- DWM önizlemesi başka masaüstündeki ve küçültülmüş pencerelerde de görüntü veriyor, izin istemiyor.
- Başka sürecin penceresi başka masaüstüne taşınabiliyor; masaüstleri sıralanabiliyor ve oluşturulabiliyor.
- `SetForegroundWindow` masaüstü değiştirmiyor; önce masaüstüne geçmek gerekiyor.
- Görev çubuğu düğmeleri UI Automation ile uygulama kimliği ve konumuyla okunuyor.
- Görev çubuğu simgesinin üstünde Windows'un kendi önizlemesi de açılıyor ve 24H2'den beri yerleşik ayarla kapanmıyor (`ExtendedUIHoverTime` ve `TaskbarNoThumbnail` denendi, etkisiz). Bu önizleme ayrı bir pencere değil, görev çubuğunun içinde çiziliyor. Panel bu yüzden onun üstünde (yaklaşık 171 nokta yukarıda) açılır; aradaki koridor panelden sayılır.
