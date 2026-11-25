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

Panelin başlığında Dock'ta tutulan uygulamalar için "Dock'tan çıkar" düğmesi var; kapalı ama Dock'ta duran uygulamada yalnızca bu düğmeyle küçük bir panel açılır. Tutulup tutulmadığı `com.apple.dock persistent-apps`'ten okunur. Çıkarma Dock'un kendi menüsüyle yapılır (`DockKeep`): simgede `AXShowMenu`, Seçenekler altında çalışan uygulamada işaretli "Dock'ta Tut", kapalı uygulamada "Dock'tan Çıkar" seçilir. Ayar dosyasını yazıp Dock'u yeniden başlatmaktan temiz: kullanıcının sağ tıkla yaptığının aynısı. Başlıklar Dock'un `DockMenus.strings` dosyalarından (`OPTIONS`, `KEEP_IN_DOCK`, `REMOVE_FROM_DOCK`) her dil için okunur. Çalışan uygulamanın simgesi, macOS'ta da olduğu gibi, uygulama kapanana kadar durur.

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
- Windows App gibi uzak masaüstü uygulamaları öndeyken klavyeyi kendileri yakalar; sahne açıkken uygulama öne alınır, kapanınca eski uygulama geri gelir. Windows App tam ekrandayken sol üst sıcak köşeden açılınca (imleç köşede, harici fareyle) Windows App Berth öne geçer geçmez kendini yeniden öne alıyordu ve sahne kapanıyordu; klavye alındıktan sonraki 1 sn içinde aynı uygulama kendiliğinden öne gelirse Berth odağı geri alır (en çok 3 kez).
- Windows App tam ekrandayken Dock (Berth'ün kenar şeridi ve macOS'un Dock'u) varsayılan olarak açılmaz (Ayarlar > Genel > "Windows App tam ekrandayken Dock'u göster"). macOS tam ekranda Dock'u başka bir uygulama için kapatmaya izin vermiyor; `FullScreenEdgeGuard` etkin bir olay musluğunda fare olaylarının konumunu Dock kenarından 6 nokta içeride tutar ve kenara doğru hareketi sıfırlar. 2 nokta yetmedi (imleç 1200 yükseklikte 1198'de dururken Dock açıldı). `CGWarpMouseCursorPosition` gerekmedi ve kenarda imleci takıltıyordu; yalnızca olay konumunu değiştirmek yetiyor (27.2). Bedeli: Windows'ta aynı kenardaki otomatik gizlenen görev çubuğu açılmayabilir. Aynı musluk (`FullScreenEdgeGuard`) üst kenarı da korur ("Windows App tam ekrandayken menü çubuğunu göster", varsayılan kapalı): imleç üst kenardan 6 nokta aşağıda tutulur, menü çubuğu ve Windows App'in başlığı inmez. Sol ve sağ uçtaki 24 nokta serbest: sıcak köşe çalışsın. Musluk etkin olduğu için her fare hareketi geri dönmesini bekler: ilk sürüm ana iş parçacığında çalışıp her olayda ekranları okuyordu ve Windows App öndeyken imleç yavaşladı. Şimdi musluk kendi iş parçacığında; ekranlar ve tam ekran durumu uygulama, masaüstü ya da ekran değişince ana iş parçacığında hesaplanır (0,6 sn sonra bir kez daha), Windows App önde değilken musluk kapalıdır.

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

## Harici fare: hız ve ivme ayrı

macOS'ta "İzleme hızı" tek kaydırıcıdır: hızı artırmak ivme eğrisini de dikleştirir. Ayarlar > Fare ve klavye'de açıkken ayarı açık olan her bağlı harici fareye kendi iki değeri yazılır (fareler ürün adıyla ayrı saklanır, `mouseProfiles`; ayarı olmayan fare macOS'un ayarıyla çalışır) (`hidutil property --matching '{"Product":…}' --set …`, izin gerekmez, kalıcı değil):

- Hız: `HIDPointerResolution` = 400 / hız DPI (16.16). Fare düşük DPI'lı gibi gösterilir, kısa hareket hızlanır.
- İvme: `HIDMouseAcceleration` (16.16), sistem kaydırıcısıyla aynı ölçek (0 düz, 3 sistemin en diki, 5'e kadar).

Fare ürün adıyla eşlenir: HP Z3700 üretici ve ürün kimliğini ters bildiriyor. macOS değerleri fare yeniden bağlanınca, uyanışta ve Sistem Ayarları'nda fare kaydırıcısı oynatılınca ezer; bu üç durumda yeniden yazılır (bağlanma ve uyanışta 1 ve 3 sn sonra). Kapatılınca ya da Berth kapanınca varsayılan çözünürlük ve `com.apple.mouse.scaling` geri yazılır. "Berth önerisi" (2×, 3) HP Z3700 ile Windows'ta EPP açık, hız 20/20 hissine göre seçildi. "macOS değerleri" (1×, izleme hızı) farenin macOS'taki hissinin karşılığıdır.

Bluetooth LE fareler (DriverKit sürücüsü, `AppleUserHIDEventService`; Logi M240 ile denendi, macOS 27.2) yazılan çözünürlüğü yok sayar: işaretçi ivme filtresi (IOHIDFamily `IOHIDPointerScrollFilter`) çözünürlüğü önbellekten değil sürücünün kendi özelliğinden okur. Aynı farede `HIDPointerAccelerationMultiplier` (yalnız eğriye giren hızı kaydırır) ve `HIDUserPointerAccelCurves` (+ `HIDPointerAccelerationAlgorithm` = 1) da 16×'te bile etkisiz kaldı. İşleyen tek yol `HIDUseLinearScalingMouseAcceleration` = 1: ivme eğrisi kapanır, hareket `HIDMouseAcceleration` kadar büyür. Bu farelerde hız bu düz çarpana yazılır; ivmeyi Berth hesaplar (`PointerAccelerator`): yalnızca dinleyen bir olay musluğu imleç hareketinin hızını ölçer (çarpana bölünerek ham sayıma çevrilir, 30 ms'de yumuşatılır), çarpan `hız × (1 + ivme/2 × min(ham hız/1500, 1,5))` olarak `IOHIDServiceClientSetProperty` ile anlık yazılır (%4'ten küçük değişiklik yazılmaz), hareket 80 ms durunca hıza döner. Çarpan yalnızca değişince yazıldığı için macOS değeri dışarıdan kendi değerine çekerse fare bir sonraki hız değişimine kadar yanlış hızda kalabiliyordu (kullanıcı ara ara yavaşlama bildirdi, kaynağı görülemedi). Fare durgunken saniyede bir değer okunur; sapma varsa yeniden yazılır, servis düştüyse yeniden aranır (`MouseTuner` günlük kategorisi, notice). Başka bir istemciden 2,5 yazınca 1 sn içinde 3'e döndüğü denendi. Pebble M350s ile hız 2, ivme 3 doğal bulundu (2026-11-20). Hangi aygıtın hareket ettiği olaydan bilinmiyor; trackpad aynı anda kullanılırsa tahmin karışabilir. kapatılınca `HIDUseLinearScalingMouseAcceleration` = 0 ile macOS'un eğrisi geri gelir.

## Fare tekerleği

macOS tekerleğe ivme uygular: yavaş çevrilen tek çentik çok az kaydırır. Ayarlar > Fare ve klavye > Fare tekerleği açıkken `ScrollWheelTuner` satırlı (`kCGScrollWheelEventIsContinuous` = 0) tekerlek olaylarını yutar; her çentik yön korunarak "satır × 40 piksel" hedefe eklenir (Windows'ta 3 satır Chrome'da yaklaşık 100 piksel; 33 Mac'te yavaş bulundu) ve hedef 120 Hz'de kalanın %35'i kadar adımlarla, piksel cinsinden sürekli olaylar olarak gönderilir (`SmoothScroll`, yaklaşık 100 ms; %25 ağır geldi). Satırlı olayı yalnızca büyütmek (ilk deneme) Chrome'da çentikte sıçrama gibi, takılır gibi görünüyordu. Aynı yönde art arda gelen çentiklerde aralık 100 ms'den kısaysa mesafe `0,1 / aralık` katına (en çok 4) büyür: tek tek çevirmede Windows gibi sabit, hızlı çevirmede tekrar tekrar çevirmeden uzağa gidilir (sabit mesafe Mac'te yetersiz bulundu). Ters yöne dönülünce kalan bırakılır. Musluk ve adımlar kendi iş parçacığında: ana iş parçacığı meşgulken tekerlek takılmasın. Trackpad, Magic Mouse ve Berth'ün kendi olayları sürekli olduğu için değişmez. Windows App öndeyken dokunulmaz: Windows'ta tekerlek zaten Windows'un ayarıyla çalışıyor. macOS'un ayarına yazmadığı için Bluetooth LE fare sınırına takılmaz.

## Kenar geçişi

Ayarlar > Fare ve klavye > Kenar geçişi (varsayılan kapalı): imleç bir dış sol/sağ kenara, dikeyde seçilen ortadaki banda değince bir masaüstü geçilir. İmleç kenara dayanınca konumu değişmiyor, fare hareketi olayına güvenilmiyor; açıkken saniyede 30 kez yoklanır. Fare düğmesi basılıyken ve sahne açıkken tetiklenmez; tetikledikten sonra imleç kenardan 6 nokta ayrılmadan yeniden tetiklenmez. İsteğe bağlı basılı tutulacak niteleme tuşları (`edgeSwitchHoldKeys`; ⌃ ⌥ ⇧ ⌘ fn, birlikte de): seçildiyse yalnızca basılıyken geçer, tuşa kenarda beklerken basmak da geçirir (durum `NSEvent.modifierFlags`'ten okunur, izin gerekmez).

Geçiş Dock'a yapay dört parmak yatay kaydırma olayı göndererek yapılır (yöntem InstantSpaceSwitcher'dan, MIT): yapay ^←/^→ Dock'ta masaüstü değiştirmiyor, uzak masaüstü öndeyken klavye de oraya gidiyor. İlerleme 0,15 sn'de 8 adımda artar, macOS'un kayma animasyonu görünür. macOS 27'de Dock yapay olayı yok sayıyor; olay verisine ham IOHID yükü (alan 4205: kuyruk başlığı, akışkan dokunma hareketi, hız) eklenip ardından boş bir hareket olayı (tip 29) gönderilince kabul ediyor, yön de doğal kaydırma ayarına bağlı (ölçüldü, 27.2; iki yön de geçti). Hız eski yoldaki gibi 1: InstantSpaceSwitcher bitişte 9999 gönderiyor, kayma fırlatılmış gibi hızlı geliyor. Sahnede üst şeritteki masaüstüne tıklama ve pencereye giderken masaüstü değiştirme de aynı yolu kullanır (`SpaceSwitcher`); önceden eski olayla gidiyordu ve macOS 27'de tam ekran masaüstlerine geçmiyordu. Debug derlemede `edgeSwitchTest` bildirimi ("left"/"right") geçişi doğrudan dener.

## Trackpad hareket tablosu

Ayarlar > Trackpad: 3 ve 4 parmakla yukarı/aşağı kaydırmanın işi (Berth sahnesi, Mission Control, App Exposé, hiçbir şey); `trackpadGestures`, eski tek seçenekli `trackpadFingers` açılışta taşınır (sahne o parmak sayısında yukarı, kalan hücreler macOS'un o an yaptığı). Kurallar `TrackpadGestureMap` / `GestureRouting` içinde ve testli.

macOS dikey kaydırmayı parmak sayısı başına açıp kapatır (`TrackpadThree/FourFingerVertSwipeGesture` iki trackpad alanında ve `com.apple.trackpad.*VertSwipeGesture` bu bilgisayara özel genel alanda), açıksa yukarı Mission Control, aşağı App Exposé; ikisi Dock'ta ayrı açılır (`showMissionControlGestureEnabled`, `showAppExposeGestureEnabled`). Sistem Ayarları her biri için tek parmak sayısı gösteriyor: 3 ve 4 birlikte açıkken ekranda eksik görünür ama çalışır.

Hücrenin işi macOS'un o harekette zaten yapacağıysa Dock olayı macOS'a bırakılır (parmağı izleyen animasyon), değilse yutulup iş Berth'te yapılır (Mission Control `com.apple.expose.awake`, App Exposé `com.apple.expose.front.awake`). macOS o parmak sayısını kapatmışsa ham dokunmalardan tanınır. Bir hücre değişince macOS'un ayarı tabloya en yakın hâle yazılır (`systemEquivalent`): Berth kapalıyken de benzer davranılsın, Sistem Ayarları çelişmesin. macOS'un bu yazımı hemen mi yoksa oturum yeniden açılınca mı uyguladığı ölçülmedi; Berth açıkken tablo her iki durumda geçerli. Sistem Ayarları kapanınca macOS'un ayarı yeniden okunur.

## Niteleme tuşları

Ayarlar > Fare ve klavye > Klavye: dahili klavye için Windows'a yakın dizilim (Kontrol → Dünya, Komut → Kontrol, Dünya → Komut; Sistem Ayarları'nın bu seçimde yazdığı çiftler), her harici klavye için Windows klavyesi dizilimi (Ctrl → ⌘, Windows → ⌥, Alt → ⌃). macOS'un kendi ayarına yazılır (`com.apple.keyboard.modifiermapping.<üretici>-<ürün>-0`, bu bilgisayara özel genel alan; dahili klavye 0-0) ve hemen etkili olsun diye klavye servisine `hidutil` ile uygulanır: dahili klavyede `HIDKeyboardModifierMappingPairs`, harici klavyede `UserKeyMapping`. Bluetooth LE klavyeler (DriverKit, Designer Compact Keyboard ile denendi, 27.2) `hidutil` ile yazılan çifti yok sayıyor; macOS kendi ayarını onlara yalnızca bağlanma anında uyguluyor (olay servisinin `HIDEventServiceProperties` sözlüğündeki `HIDKeyboardModifierMappingPairs`). Ayar yazıldığında klavye bağlıysa eşleme bir sonraki bağlanmaya kadar gelmez. İlk sürüm `UserKeyMapping`'i her zaman tam yazıyordu; yeniden bağlanınca macOS'unki de devreye girip eşleme iki kez uygulandı (Ctrl → ⌘ → ⌥, Windows → ⌥ → ⌃, Alt → ⌃ → ⌘; olay dinleyicisiyle ölçüldü). Şimdi Berth macOS'un o an uyguladığı çiftleri okuyup yalnızca farkı `UserKeyMapping` olarak yazar: macOS uyguladıysa boş, uygulamadıysa eşlemenin kendisi, Windows App öndeyken macOS'unkinin tersi. Açılışta, klavye bağlanınca ve uyanışta (1 ve 3 sn sonra) yeniden hesaplanır.

Windows bağlantısı > "Windows App öndeyken … eşlemesini kaldır": Windows App öne gelince eşlemesi olan harici klavyelerin servisine boş eşleme yazılır, arkaya geçince macOS'un ayarındaki eşleme geri yazılır. Niteleme tuşu basılıyken değiştirilmez. Dahili klavyeye dokunulmaz.
