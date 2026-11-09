# Berth, macOS: mühendislik notları

Mac sürümünün nasıl çalıştığı ve hangi kararın neden alındığı (ölçümlerle). Kullanıcı belgesi için ana dizindeki README.

```bash
./Scripts/make-app.sh debug && open "/Applications/Berth.app"
```

```bash
swift test
```

Açmak için ⌥⇧Space ya da menü çubuğu simgesi. Kapatmak için Esc, boşluğa tıklama ya da aynı kısayol.
Ekran Kaydı (önizleme, başlık) ve Erişilebilirlik (pencereye geçiş) izni gerekir.

## Yapı

- `Sources/BerthCore`: yerleşim ve kurallar. AppKit yok, testli.
- `Sources/Berth/SkyLight.swift`: belgesiz API'nin tamamı, yalnızca okuma. Bozulursa masaüstü bilgisi kaybolur, uygulama çalışır.
- `SceneSnapshot`: sistemden o anki durumu okur.
- `SceneView`: Core Animation ile sahne, animasyon, fare ve klavye.
- `WindowActivator`: ölçülmüş pencereye geçiş yolları.

## Kurallar

- Hücrenin yeri yalnızca sıra ve hücre boyutundan gelir; pencere sayısı girdi değildir.
- Hücre boyutu ilk görüldüğünde pencere sayısından seçilir, sonra yalnızca kullanıcı değiştirir.
- Yığındaki pencere sırası açılış sırasıdır; kullanım sırayı değiştirmez.

## Sahnede kaydırma ve sıralama

Ayarlar > Genel > Sahne açıkken (varsayılan kapalı) sabit olmayan uygulamalar ilk görünümün altında kendi hücreleriyle listelenir. İlk görünüm ayar kapalıykenkiyle aynıdır, çipler de yerinde kalır.

- **Katmanlar.** `chrome` kaymaz (şerit, arama). `page` kırpan katmandır; `pageChrome` ve `tileHost` onun içinde görünüm uzayında kurulur, kaydırma yalnızca `page.bounds.origin` değiştirir. Bu yüzden hedefler de ikiye ayrıldı: `hits` görünüm uzayında, `pageHits` sayfa uzayında.
- **Üst kırpma yalnızca kaydırılmışken.** Sahne açılırken pencereler gerçek yerlerinden uçar; üst kenar baştan kırpılsa şeridin hizasında kesilirlerdi. Görünmeyen önizlemeler uçmaz, solarak gelir.
- **Yerleşim.** Bu bölüm `StageLayout.placeFlowing` ile kurulur: yukarıdan başlar, 12 hücrede bir uzar, böylece uygulama çoğaldıkça hücreler ekrana sığmak için küçülmez. Sabit olmayan uygulamanın yeri ada göre değişebilir; "yeri sabit" kuralı yalnızca sabitlenenler için geçerlidir.

Sabit hücre herhangi bir yerinden (önizleme, etiket, boş kısım) sürüklenir. Bırakılan yer belirler: hücrelerin arası sırayı değiştirir, önizleme için şerit eskisi gibi tam ekrana alır. Tam ekran pencere şeride bırakılamaz ama hücresiyle sıralanabilir. Arama ya da pencere paneli açıkken sıralama yoktur.

## Pencereyi tam ekranlar arasına yerleştirme

Önizleme üstteki şeride sürüklenip iki alanın arasına bırakılır. Pencere tam ekrana geçer, sonra yeni alan bırakılan yere taşınır. Tam ekran alanların sırası buradan değiştirilemez: bunu macOS yalnızca kendi Mission Control'ünde yapıyor, o yüzden tam ekran pencereler ve şeritteki küçük resimler sürüklenmez.

macOS sırayı değiştiren bir API sunmuyor, `yabai` de bunun için SIP'in kapatılmasını istiyor. Bu yüzden `MissionControlDriver` Mission Control'ü açıp şeridindeki sürüklemeyi taklit ediyor. Mission Control birkaç saniye görünür ve imleç bu sırada kullanılır.

Ölçülen kurallar:

- Küçük resimler kapalıyken ekranın üstündedir. Şerit açılmadan sürükleme başlamaz.
- Bir alanın üstüne ya da ilk alanın soluna bırakmak Split View oluşturabilir. Bu yüzden yalnızca aralara ve en sağa bırakılır; en sol iki sürüklemeyle elde edilir (`SpaceOrder.plan`).
- Alan tutulunca diğer küçük resimler kayar. Bırakma noktası önceden hesaplanmaz, iki komşunun o anki konumundan okunur; yoksa alanlar yan yana birleşir.
- Şerit başlıkları beklenen alanlarla tutmazsa hiçbir şey sürüklenmez. Başlık uygulama ya da pencere adı olabilir.
- Sonuç her seferinde macOS'tan geri okunur; olmadıysa pencere tam ekran kalır ve uyarı çıkar.

## Dock önizlemesi ve ayarlar

Dock simgesinin üstüne gelince uygulamanın tüm masaüstlerindeki pencereleri simgenin yanında açılır. Yoklama yok: Dock seçili simge değişince Erişilebilirlik bildirimi gönderiyor. Panelin kapanması Dock seçimine değil imlecin yerine bakar, çünkü imleç panele geçince seçim temizlenmeyebiliyor.

Menü çubuğu simgesi: sol tık sahneyi açar, sağ tık menüyü (Ayarlar, Çık). Ayarlarda kısayol, Dock önizlemesi, oturum açılışı, sabit uygulamalar ve izin durumu bulunur.

## Ekran Kaydı izni isteğe bağlıdır

Ayarlar > Genel > Pencere önizlemeleri. İzin ilk açılışta istenmez; kullanıcı önizlemeleri açarsa istenir.

- **Açıkken:** Görüntüler yalnızca sahne ya da Dock önizlemesi açılınca alınır. Arka planda yakalama yoktur.
- **Kapalıyken:** Hiç ekran yakalaması yapılmaz. Kartlar simge ve başlıkla çizilir. Başlıklar Erişilebilirlik'ten okunur; başka alandaki pencerelerde ve aynı kareyi paylaşan pencerelerde "Uygulama · Pencere N" görünür.
- **Duvar kağıdı:** Her iki durumda dosyasından okunur, yakalama yalnızca dosya okunamazsa denenir.

Debug derlemede izinsiz durumu sınamak için: `defaults write io.github.brkhsdmr.berth simulateNoScreenRecording -bool YES`

## Açılış yolları

Ayarlar > Açılış sekmesinde seçilir; hiçbiri sistem ayarını değiştirmez:

- **Klavye kısayolu:** açılıp kapatılabilir, tuşları değiştirilebilir.
- **Trackpad:** Kapalı, 3 parmak ya da 4 parmakla yukarı kaydırma.
- **Sıcak köşe:** dört köşeden biri ve bekleme süresi. macOS aynı köşeye bir eylem atamışsa ayarlarda uyarı çıkar.
- **Menü çubuğu simgesi:** her zaman açar ya da kapatır.

## Sahnede klavye

- Arama kutusuna tıklanır ya da doğrudan yazılır; ⌘V yapıştırır, ⌘⌫ siler, Esc önce aramayı temizler.
- Oklar seçimi en yakın önizlemeye taşır, ↩ seçilene geçer. ⌘1…⌘9 şeritteki o alana geçer.
- Windows App gibi uzak masaüstü uygulamaları öndeyken klavyeyi kendileri yakalar; sahne açıkken uygulama öne alınır, kapanınca eski uygulama geri gelir.

## Birden çok ekran

Sahne imlecin olduğu ekranda açılır, tüm ekranların pencerelerini gösterir. Başka ekrandaki pencerenin rozetinde ekranın adı yazar ("Dahili ekran · Masaüstü"). Önizleme köşesindeki ekran düğmesi pencereyi sıradaki ekrana, aynı göreli yer ve boyutla taşır.

## Çalışma düzenleri

Ayarlar > Düzenler ya da menü çubuğu simgesine sağ tık: bu alanlardaki görünen ve küçültülmüş pencerelerin yeri, boyutu ve durumu adla saklanır. Düzen yeniden adlandırılabilir ve kısayol atanabilir. Yüklerken kapalı uygulamalar açılır, pencereleri gelince yerlerine konur. Eşleştirme önce aynı pencere, sonra aynı uygulama ve başlık, sonra uygulamanın kalan pencereleri (`LayoutMatcher`). Başka alandaki ve tam ekran pencereler kaydedilmez; macOS pencereyi alana taşımaya izin vermiyor.

## Windows'a köprü (RDP)

Ayarlar > Açılış > Uzak masaüstü açılınca uygulama 47654 numaralı TCP kapısını dinler (yalnızca Tailscale ve yerel ağ adresleri). Windows'taki uygulamaya bu Mac'in adı ve eşleştirme kodu girilince Windows bağlanır. Windows App'te o oturum öndeyken yukarı kaydırma, Windows'taki sahneyi açar ya da kapatır. Bağlantıyı Windows açtığı için orada güvenlik duvarı kuralı gerekmez. Tuşla iletmek denendi: Windows App yapay değiştirici tuşları geçirmiyor.

Birden çok bilgisayar bağlanabilir. Hareket, öndeki oturumun başlığında bilgisayarın adı ya da ayarlarda ona yazılan oturum adı geçen bilgisayara gider. Ayarlardan bağlantısı kesilen bilgisayara "BLOCKED" denir, izin verilene kadar bağlanamaz.

Aşağı kaydırma normalde macOS'un App Exposé'sine bırakılır. Bağlı bir bilgisayarın oturumu öndeyken alınır ve "APPWINDOWS" olarak gider. Karar hareketten önce verilmeli (tap iş parçacığı beklerse macOS onu kapatır): Windows App öndeyken yarım saniyede bir yenilenen bir bayrak tutulur. Hareket anında oturum değişmişse `CoreDockSendNotification` ile App Exposé açılır.

## Bellek

Program kodu ~2 MB. Asıl yük görüntüler: bulanık zemin küçük görüntüden üretilir (katman büyütür), pencere görüntüleri sahne kapandıktan 30 sn sonra bırakılır. Ölçüm (release, iki ekran): boşta ~29 MB, sahne açıkken ~60 MB; önce 107 MB'tı. Dili değiştirmek bunu değiştirmez: Swift de C++ gibi makine koduna derlenir, fark birkaç MB.

## Uyumluluk denetimi

Açılışta belgesiz işlevlerin (SkyLight, MultitouchSupport) bu macOS'ta bulunup bulunmadığı okunur. Bozulan varsa bir kez bildirilir; durum Ayarlar > İzinler'de görünür.

## Dağıtım

`./Scripts/make-release.sh <sürüm>`: Developer ID imzası, DMG ve Apple onayı. Ayrıntılar ve mağaza değerlendirmesi: `docs/distribution.md`.

## Trackpad hareketi

Mission Control'e atanan yukarı kaydırma, Dock'a ulaşmadan `CGEventTap` ile yakalanır ve sahneyi açar. Sistem ayarı değişmez, SIP gerekmez. Seçenek kapanınca ya da uygulama çıkınca Mission Control geri gelir.

Parmak sayısı ham dokunmalardan okunur (`MultitouchSupport`, belgesiz, izin gerektirmez). Dock hareketi seçilenden farklı parmakla geldiyse macOS'a bırakılır; 3 parmak seçilince 4 parmak Mission Control'ü açmaya devam eder. Seçilen parmak sayısı macOS'ta Mission Control'e atanmamışsa Dock hareketi hiç gelmez, kaydırma ham dokunmalardan tanınır (`MultiFingerSwipe`). Dokunma okunamazsa her parmak sayısı eskisi gibi yakalanır.

Ölçülen olay alanları belgesizdir (eksen 2 dikey, faz 1/2/4, ilerleme işareti yön), bir macOS güncellemesi bozabilir. Alanlar değişirse hareket olduğu gibi Dock'a geçer, Mission Control açılır. Kurallar `SwipeGestureInterpreter` içinde ve testli.
