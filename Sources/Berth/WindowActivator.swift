import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

// MARK: - Ayarlar ve günlük

/// Etkinleştirme katmanının sabitleri ve günlükçüsü.
private enum Activator {
    static let log = Logger(subsystem: "io.github.brkhsdmr.berth", category: "WindowActivator")

    /// Tek bir AX mesajının bekleyebileceği en uzun süre.
    ///
    /// Varsayılan 6 saniyedir; takılmış bir uygulama bu süre boyunca ana
    /// thread'i tutabilir. Kaplama tıklamayla kapandığı için 0.5 sn hem
    /// yeterince cömert hem de kullanıcının fark etmeyeceği kadar kısa.
    static let messagingTimeout: Float = 1.5

    /// Konum + boyut ile eşleştirmede kabul edilen sapma (nokta).
    ///
    /// CGWindowList'ten okunan kare ile AX'in bildirdiği kare arasında
    /// gölge/çerçeve farkı ve yuvarlama nedeniyle birkaç noktalık sapma olur.
    static let frameTolerance: CGFloat = 6
}

// MARK: - Hatalar

/// Pencere eylemlerinde oluşabilecek, kullanıcıya gösterilebilir hatalar.
///
/// Sessiz başarısızlık yok: `WindowActivator` üzerindeki her eylem
/// başarısızlıkta bunlardan birini fırlatır.
enum WindowActionError: Error, Equatable, CustomStringConvertible {

    /// Erişilebilirlik izni verilmemiş; hiçbir AX çağrısı denenmedi.
    case accessibilityDenied

    /// Süreç artık çalışmıyor (kapanmış ya da çökmüş).
    case applicationGone

    /// Uygulama çalışıyor ama hedef pencere bulunamadı.
    case windowNotFound

    /// Eylem bu uygulama/pencere için mümkün değil. Metin doğrudan gösterilir.
    case unsupported(String)

    /// Bir AX çağrısı `.success` dışında bir değer döndürdü.
    /// Sarmalanan değer `AXError.rawValue`.
    case axFailed(Int32)

    var description: String {
        switch self {
        case .accessibilityDenied:
            return "Erişilebilirlik izni yok. Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik bölümünden bu uygulamaya izin verin."
        case .applicationGone:
            return "Uygulama artık çalışmıyor."
        case .windowNotFound:
            return "Pencere bulunamadı; kapatılmış ya da başka bir uygulamaya devredilmiş olabilir."
        case .unsupported(let reason):
            return reason
        case .axFailed(let code):
            return "Erişilebilirlik çağrısı başarısız oldu: \(WindowActionError.axReason(code)) (kod \(code))."
        }
    }

    /// Ham `AXError` değerinin Türkçe karşılığı.
    private static func axReason(_ code: Int32) -> String {
        switch code {
        case -25200: return "genel hata"
        case -25201: return "geçersiz argüman"
        case -25202: return "pencere geçersiz"
        case -25204: return "uygulama yanıt vermedi"
        case -25205: return "özellik desteklenmiyor"
        case -25206: return "eylem desteklenmiyor"
        case -25208: return "uygulama bu çağrıyı uygulamamış"
        case -25211: return "erişilebilirlik API'si kapalı"
        case -25212: return "değer yok"
        default: return "bilinmeyen hata"
        }
    }
}

// MARK: - Etkinleştirici

/// Gerçek pencereleri öne getiren, kapatan ve uygulama düzeyinde işlem yapan
/// ince katman.
///
/// Tasarım kararları:
///
/// - **Durum tutmaz.** Her çağrı pencereyi o anda yeniden bulur; kaplama
///   açıldıktan sonra pencereler taşınmış ya da kapanmış olabilir.
/// - **Boşta maliyeti sıfırdır.** Zamanlayıcı, gözlemci ya da AX observer
///   kurulmaz; yalnızca çağrıldığında iş yapar.
/// - **Ana thread bloklanmaz.** AX mesajlaşma zaman aşımı süreç genelinde
///   `Activator.messagingTimeout` değerine çekilir.
///
/// ## Koordinat uzayı
///
/// `frame` parametreleri **CGWindowList uzayındadır**: ana ekranın sol ÜST
/// köşesi orijin, y aşağı doğru büyür. `kAXPositionAttribute` de tam olarak
/// aynı uzayı kullanır, bu yüzden burada hiçbir çevrim yapılmaz.
/// Dikkat: `NSScreen.frame` sol ALT orijinlidir — çağıran taraf NSScreen
/// uzayında bir dikdörtgen verirse konum eşleşmesi tutmaz ve eşleştirme
/// sıra indeksine düşer.
@MainActor
enum WindowActivator {

    // MARK: - Erişilebilirlik izni

    /// İzin durumunu **istem göstermeden** okur.
    ///
    /// Arayüzde her yeniden çizimde okunabilir; sistem çağrısı ucuzdur ve
    /// hiçbir yan etkisi yoktur.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Sistem iznini ister; macOS'un izin uyarısını gösterir.
    ///
    /// Uyarı süreç başına yalnızca bir kez gösterilir. Kullanıcı izni Sistem
    /// Ayarları'ndan verdikten sonra uygulamanın yeniden başlatılması
    /// gerekebilir — bu, macOS'un davranışıdır, burada telafi edilemez.
    static func requestTrust() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    // MARK: - Pencere eylemleri

    /// Verilen pencereyi öne getirir ve uygulamasını etkinleştirir.
    ///
    /// Sıra önemlidir ve üç adımın hepsi gereklidir:
    /// 1. `kAXMainAttribute = true` — uygulama içinde bu pencere "ana" olur.
    /// 2. `kAXRaiseAction` — pencere kendi uygulamasının yığınında en öne gelir.
    /// 3. `NSRunningApplication.activate()` — uygulama sistemde öne gelir.
    ///
    /// Adım 1 bazı pencerelerde (panel, sayfa, yardımcı pencere) desteklenmez.
    /// Bu tek başına ölümcül sayılmaz: adım 2 + 3 pencereyi zaten öne getirir.
    /// İkisi birden başarısız olursa hata fırlatılır.
    ///
    /// - Parameters:
    ///   - pid: Pencerenin sahibi sürecin kimliği.
    ///   - title: CGWindowList'ten okunan pencere başlığı. Boş olabilir.
    ///   - frame: CGWindowList uzayındaki kare (sol üst orijin).
    ///   - order: Uygulamanın pencere listesindeki sıra indeksi (son çare).
    ///   - windowID: CGWindowList kimliği. Hedefin başka bir Space'te olup
    ///     olmadığını anlamak ve geçişi DOĞRULAMAK için kullanılır; 0 ise bilinmiyor.
    static func activateWindow(pid: pid_t, windowID: CGWindowID, title: String, frame: CGRect, order: Int) throws {
        let app = try runningApplication(pid: pid)
        guard isTrusted else { throw WindowActionError.accessibilityDenied }

        if app.isHidden { app.unhide() }

        // Hedef başka bir Space'te mi? Tam ekran pencereler kendi Space'lerinde
        // yaşar ve ÖLÇÜLDÜ: Chromium tabanlı uygulamalar bu pencereleri
        // `kAXWindows` listesinde HİÇ döndürmüyor. Yani AX yolu onları ne
        // bulabilir ne de yükseltebilir; sıra indeksine düşmek her seferinde
        // masaüstündeki yanlış pencereyi seçer. Bu durumda tek doğru yol
        // uygulamanın kendi "Pencere" menüsüdür.
        if windowID != 0, !isOnActiveSpace(windowID) {
            // Menü öğesi, uygulama öne alınmadan da okunabiliyor. Öğe yoksa uygulamayı
            // KAYMADAN ÖNCE öne almamalı: ölçüldü, Windows App'te "Devices" penceresine
            // tıklanınca uygulamayı öne almak macOS'u uygulamanın tam ekran penceresinin
            // (Home PC) alanına geçirdi, ardından başlayan kayma da onunla çakışıp
            // kullanıcıyı yanlış pencerede bıraktı.
            if let item = windowMenuItem(pid: pid, title: title) {
                // ÖN KOŞUL: uygulama öne alınmış olmalı. Ölçümde, aktive edilmeden
                // yapılan menü basışı `.success` döndürdü ama hiçbir şey yapmadı;
                // aktive edildikten sonra aynı basış Space'i değiştirdi.
                try activate(app)
                if performAction(item, kAXPressAction) == .success {
                    verifySpaceSwitch(windowID: windowID, pid: pid, title: title, frame: frame, order: order, app: app)
                    return
                }
            }

            // Pencere menüde olmayabilir (ölçüldü: Windows App'in "Devices" penceresi menüde
            // "Connection Center" adıyla duruyor). Pencerenin alanı biliniyor: doğrudan oraya kay,
            // uygulamayı vardıktan sonra hedef pencere ana pencere yapılarak öne al.
            if slideToWindow(windowID: windowID, pid: pid, title: title, frame: frame, order: order) {
                return
            }

            // Alan bilinmiyorsa Dock simgesi. Yalnızca uygulamanın tüm pencereleri tam ekransa
            // doğru yere gider; yoksa tam ekranlar arasında dönüp kullanıcıyı geri atar.
            try activate(app)
            pressDockItem(for: app)
            scheduleDeferredRaise(pid: pid, title: title, frame: frame, order: order)
            return
        }

        let windows = try windowList(of: applicationElement(pid: pid))
        guard let window = matchWindow(in: windows, title: title, frame: frame, order: order) else {
            // AX ağacı henüz hazır değil ya da eşleşme kurulamadı.
            //
            // Chromium tabanlı uygulamalar (Chrome, VS Code, Electron) erişilebilirlik
            // ağacını TEMBEL kurar: başka bir Space'ten gelen ilk `kAXWindows` sorgusu
            // ölçümde BOŞ döndü. Kullanıcıyı "Pencere bulunamadı" ile eli boş bırakmak
            // yerine uygulamayı hemen öne alıyoruz — bu izin gerektirmez — sonra ağaç
            // ısınınca hedef pencereyi yükseltiyoruz.
            try activate(app)
            if !pressWindowMenuItem(pid: pid, title: title) {
                scheduleDeferredRaise(pid: pid, title: title, frame: frame, order: order)
            }
            return
        }

        // Simge durumundaki pencere Dock'tadır; AXRaise onu geri getirmez.
        // Öznitelik desteklenmiyorsa pencere zaten simge durumunda olamaz.
        if boolAttribute(window, kAXMinimizedAttribute) == true {
            setAttribute(window, kAXMinimizedAttribute, false as CFTypeRef)
        }

        // SIRA ÖNEMLİ ve iki yönlü bir kısıt var:
        //
        // - Hedef pencere uygulamanın "ana" penceresi olarak AKTİVASYONDAN ÖNCE
        //   işaretlenmeli; aktivasyon ana pencerenin bağlamında gerçekleşir.
        // - Ama bazı uygulamalar aktivasyonu işlerken kendi eski penceresini
        //   geri yükseltir. Bu yüzden aktivasyondan SONRA da tekrar ediyoruz.
        let mainError = setAttribute(window, kAXMainAttribute, true as CFTypeRef)
        _ = setAttribute(window, kAXFocusedAttribute, true as CFTypeRef)
        _ = setAttribute(applicationElement(pid: pid), kAXFrontmostAttribute, true as CFTypeRef)
        let raiseError = performAction(window, kAXRaiseAction)

        if mainError != .success && raiseError != .success {
            // AXRaise'in hatası daha açıklayıcı — onu bildiriyoruz.
            throw WindowActionError.axFailed(raiseError.rawValue)
        }
        if mainError != .success {
            Activator.log.debug("AXMain ayarlanamadı (kod \(mainError.rawValue, privacy: .public)); AXRaise yeterli oldu.")
        }

        try activate(app)
        reassertAfterActivation(window: window, pid: pid)
    }

    /// Pencereyi tam ekrandan çıkarır ve geçişin bitmesini bekler.
    ///
    /// **Neden beklemek şart:** çıkış animasyonlu (~0.5–1 sn) ve Space çöküyor.
    /// Geçiş sürerken yazılan konum/boyut sessizce kayboluyor — pencere eski
    /// yerine oturuyor ve kullanıcı "yaslamadı" diyor.
    ///
    /// Sabit bir gecikmeyle beklemek yerine özniteliği yokluyoruz: hızlı
    /// uygulamalarda gecikme yaratmıyor, yavaşlarda yetiyor. Yoklama bittikten
    /// sonra da kısa bir soluk veriliyor; `AXFullScreen` false olduğu anda
    /// pencere henüz masaüstüne oturmuş olmuyor.
    private static func exitFullScreen(_ window: AXUIElement) async throws {
        let error = setAttribute(window, "AXFullScreen", false as CFTypeRef)
        if error == .attributeUnsupported || error == .actionUnsupported {
            throw WindowActionError.unsupported("Bu pencere tam ekrandan çıkarılamıyor.")
        }

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if boolAttribute(window, "AXFullScreen") != true { break }
        }

        guard boolAttribute(window, "AXFullScreen") != true else {
            throw WindowActionError.unsupported("Pencere tam ekrandan çıkmadı; yerleştirme yapılamadı.")
        }

        // Space çöküşü ve pencerenin masaüstüne oturması için ek soluk.
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    /// Pencere macOS tam ekran modunda mı?
    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        boolAttribute(window, "AXFullScreen") == true
    }

    // MARK: - Pencere yerleştirme

    /// Verilen pencereyi hedef kareye taşır ve boyutlandırır.
    ///
    /// - Parameters:
    ///   - pid: Pencerenin sahibi sürecin kimliği.
    ///   - title: CGWindowList'ten okunan ham başlık. Boş olabilir.
    ///   - frame: Pencerenin **şu anki** karesi; eşleştirme için (CGWindowList uzayı).
    ///   - order: Uygulamanın pencere listesindeki sıra indeksi (son çare).
    ///   - target: Pencerenin taşınacağı kare — **CGWindowList uzayında**, yani
    ///     sol üst orijin. `kAXPosition` de aynı uzaydadır, çevrim yapılmaz.
    ///     `NSScreen` uzayındaki bir dikdörtgen verilirse hata dönmez, pencere
    ///     yalnızca yanlış yere gider: bkz. `TileLayout.flipVertically`.
    ///
    /// - Throws: Pencere tam ekransa, konum/boyut yazılamıyorsa ya da yazılan
    ///   kare tutmuyorsa `WindowActionError`.
    static func placeWindow(pid: pid_t, title: String, frame: CGRect, order: Int, to target: CGRect) async throws {
        guard target.width > 0, target.height > 0 else {
            throw WindowActionError.unsupported("Geçersiz hedef kare; pencere yerleştirilemedi.")
        }

        // Pencereyi bulmak `withWindow`'un işi: başka bir Space'teki pencereler
        // `kAXWindows` listesinde hiç görünmüyor ve uygulamayı bir an öne almak
        // şart (ölçüldü). Yazma işini closure'ın İÇİNDE yapmıyoruz çünkü iki
        // deneme arasında beklemek gerekiyor, closure ise senkron: öğeyi dışarı
        // alıp asıl işi burada yürütüyoruz. Öğe bulunduktan sonra geçerliliğini
        // korur; yazmak için uygulamanın önde olması gerekmez.
        let window = try await withWindow(pid: pid, title: title, frame: frame, order: order) { $0 }

        // Tam ekran pencere konum/boyut yazmayı KABUL ETMEZ: macOS onu kendi
        // Space'inde yönetir ve yazım ya hata döner ya da `.success` dönüp
        // hiçbir şey yapmaz.
        //
        // Kullanıcıya "önce tam ekrandan çıkın" demek, bizim yapabileceğimiz
        // bir işi ona yaptırmaktı. Artık kendimiz çıkıyoruz: niyet zaten net —
        // pencereyi bir yere yaslamak isteyen kişi onun tam ekran kalmasını
        // istemiyor.
        if isFullScreen(window) {
            try await exitFullScreen(window)
        }

        // Simge durumundaki pencerenin karesi Dock'tadır; önce geri getirilmeli.
        // Geri gelme animasyonu sürerken yazılan kare tutmuyor, bu yüzden kısa
        // bir soluk veriliyor.
        if boolAttribute(window, kAXMinimizedAttribute) == true {
            setAttribute(window, kAXMinimizedAttribute, false as CFTypeRef)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        var lastFailure: AXError?

        // NEDEN yazıp geri okuyoruz ve bir kez daha deniyoruz:
        //
        // - Bazı uygulamalar en küçük pencere boyutu dayatır (Terminal, bazı
        //   Electron uygulamaları); istenen boyut kırpılır ve konum kayar.
        // - Konumu önce yazmak, pencere ekranın sağ/alt kenarına yakınken
        //   sistemin kareyi kırpmasına yol açabilir; boyut yazıldıktan sonraki
        //   ikinci tur bunu düzeltir.
        // - Stage Manager açıkken yazılan kare geri alınabiliyor ve durumunu
        //   okumanın public bir API'si YOK; tek ölçülebilir sinyal, sonucu geri
        //   okumaktır.
        //
        // Sessizce yanlış yere koymak, açıkça başarısız olmaktan kötüdür:
        // kullanıcı düzenin neden bozuk olduğunu asla anlayamaz.
        for attempt in 0..<2 {
            if attempt > 0 {
                // Uygulamanın kendi yerleşim geçişini bitirmesi için kısa aralık.
                try? await Task.sleep(nanoseconds: 80_000_000)
            }

            let positionError = setPosition(window, target.origin)
            let sizeError = setSize(window, target.size)

            // Öznitelik hiç desteklenmiyorsa tekrar denemek zaman kaybı:
            // yardımcı paneller ve bazı sistem pencereleri taşınamaz.
            if positionError == .attributeUnsupported || sizeError == .attributeUnsupported {
                throw WindowActionError.unsupported("Bu pencere taşınamıyor veya yeniden boyutlandırılamıyor.")
            }
            if positionError != .success { lastFailure = positionError }
            if sizeError != .success { lastFailure = sizeError }

            guard let origin = pointAttribute(window, kAXPositionAttribute),
                  let size = sizeAttribute(window, kAXSizeAttribute)
            else { continue }

            let originDeviation = max(
                abs(origin.x - target.origin.x),
                abs(origin.y - target.origin.y)
            )
            let sizeDeviation = max(
                abs(size.width - target.width),
                abs(size.height - target.height)
            )

            if originDeviation <= Activator.frameTolerance,
               sizeDeviation <= Activator.frameTolerance {
                return
            }

            // BOYUT tutmadıysa bu bir başarısızlık DEĞİLDİR.
            //
            // Birçok uygulama en küçük pencere boyutu dayatır (Terminal, bazı
            // Electron ve Java uygulamaları). Kullanıcının kararı net: böyle bir
            // pencere en küçük hâline insin, SOL ÜST köşesi slota hizalansın ve
            // gerekiyorsa sağa/aşağı taşsın. Taşma sorun değil; hizasızlık ve
            // "dizemedim" demek sorun.
            //
            // Boyut yazmak pencereyi kaydırabildiği için konum SON olarak
            // yeniden yazılıyor.
            if originDeviation > Activator.frameTolerance {
                _ = setPosition(window, target.origin)
            }

            if attempt == 1 {
                guard let finalOrigin = pointAttribute(window, kAXPositionAttribute) else { break }
                let settled = max(
                    abs(finalOrigin.x - target.origin.x),
                    abs(finalOrigin.y - target.origin.y)
                )
                // Konum tuttuysa iş bitti: pencere küçülemedi ama doğru yerde.
                if settled <= Activator.frameTolerance { return }
            }

            Activator.log.debug("Yerleştirme sapması: konum \(originDeviation, privacy: .public), boyut \(sizeDeviation, privacy: .public)")
        }

        if let lastFailure, lastFailure != .success {
            throw WindowActionError.axFailed(lastFailure.rawValue)
        }
        // Buraya yalnızca KONUM tutmadığında geliyoruz; boyut zaten hoş görülüyor.
        throw WindowActionError.unsupported(
            "Pencere istenen konuma yerleşmedi; Stage Manager kareyi geri alıyor olabilir."
        )
    }

    /// Pencereyi diğer pencerelerin ÜSTÜNE çıkarır.
    ///
    /// Dizmeden sonra şart: yerleştirme yalnızca kareyi değiştirir, z-sırasına
    /// dokunmaz. Kullanıcı dizdiği pencerelerin bazılarını dizmediklerinin
    /// altında bulunca "yerleşmedi" sanıyor — oysa yerleşmiş, sadece görünmüyor.
    ///
    /// Uygulamayı da öne alır: `kAXRaise` yalnızca uygulamanın KENDİ yığınında
    /// yükseltir; uygulamalar arası sıra aktivasyonla belirlenir.
    static func raiseWindow(pid: pid_t, title: String, frame: CGRect, order: Int) async throws {
        let app = try runningApplication(pid: pid)
        let window = try await withWindow(pid: pid, title: title, frame: frame, order: order) { $0 }

        if boolAttribute(window, kAXMinimizedAttribute) == true {
            setAttribute(window, kAXMinimizedAttribute, false as CFTypeRef)
        }
        _ = setAttribute(window, kAXMainAttribute, true as CFTypeRef)
        _ = setAttribute(window, kAXFocusedAttribute, true as CFTypeRef)
        _ = performAction(window, kAXRaiseAction)
        if app.isHidden { app.unhide() }
        try activate(app)
    }

    /// `kAXPosition` yazar. `AXValue` kutulaması başarısız olursa `.failure`.
    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> AXError {
        var value = point
        guard let boxed = AXValueCreate(.cgPoint, &value) else { return .failure }
        return setAttribute(window, kAXPositionAttribute, boxed)
    }

    /// `kAXSize` yazar. `AXValue` kutulaması başarısız olursa `.failure`.
    private static func setSize(_ window: AXUIElement, _ size: CGSize) -> AXError {
        var value = size
        guard let boxed = AXValueCreate(.cgSize, &value) else { return .failure }
        return setAttribute(window, kAXSizeAttribute, boxed)
    }

    // MARK: - Pencere bulma

    /// İzni doğrular, uygulamanın pencerelerini toplar ve hedefi eşleştirir.
    private static func locateWindow(pid: pid_t, title: String, frame: CGRect, order: Int) throws -> AXUIElement {
        guard isTrusted else { throw WindowActionError.accessibilityDenied }

        let appElement = applicationElement(pid: pid)
        let windows = try windowList(of: appElement)
        guard let window = matchWindow(in: windows, title: title, frame: frame, order: order) else {
            throw WindowActionError.windowNotFound
        }
        return window
    }

    /// Pencereyi bulur; bulunamazsa uygulamayı **geçici olarak öne alıp** yeniden
    /// dener ve odağı geri verir.
    ///
    /// Neden gerekli: ölçüldü — başka bir Space'teki (özellikle tam ekran)
    /// pencereler `kAXWindows` listesinde **hiç görünmüyor**. TextEdit'te liste
    /// aktive edilmeden 0 pencere, aktive edildikten sonra 2 pencere döndü ve
    /// tam ekran pencerenin kapatma düğmesi oradaydı. Yani pencereye gitmeden
    /// kapatmak/küçültmek için önce uygulamayı bir an öne almak şart.
    ///
    /// Odak, işlem biter bitmez önceki uygulamaya iade edilir; kullanıcı
    /// gezginden ayrılmak istemedi.
    static func withWindow<T>(
        pid: pid_t,
        title: String,
        frame: CGRect,
        order: Int,
        perform body: (AXUIElement) throws -> T
    ) async throws -> T {
        guard isTrusted else { throw WindowActionError.accessibilityDenied }
        let app = try runningApplication(pid: pid)

        if let window = try? locateWindow(pid: pid, title: title, frame: frame, order: order) {
            return try body(window)
        }

        // Liste DOLUYSA ama eşleşme kurulamadıysa uygulamayı öne almak hiçbir
        // şey eklemez — yalnızca kullanıcıyı istemediği pencereye götürür.
        // Aktivasyon yalnızca listenin boş olduğu (başka Space) durumda anlamlı.
        let currentList = (try? windowList(of: applicationElement(pid: pid))) ?? []
        guard currentList.isEmpty else { throw WindowActionError.windowNotFound }

        let previous = NSWorkspace.shared.frontmostApplication
        if app.isHidden { app.unhide() }
        try activate(app)

        // AX ağacının dolması aktivasyondan biraz sonra tamamlanıyor; sabit bir
        // gecikme yerine kısa aralıklarla yokluyoruz.
        var located: AXUIElement?
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 90_000_000)
            if let window = try? locateWindow(pid: pid, title: title, frame: frame, order: order) {
                located = window
                break
            }
        }

        defer {
            if let previous, previous.processIdentifier != pid {
                previous.activate()
            }
        }

        guard let located else { throw WindowActionError.windowNotFound }
        return try body(located)
    }

    /// Verilen pencereyi kapatır.
    ///
    /// Pencerenin kapatma düğmesi (`kAXCloseButtonAttribute`) bulunur ve
    /// `kAXPressAction` uygulanır — yani kullanıcı kırmızı düğmeye basmış gibi
    /// olur. Kaydedilmemiş değişiklik varsa uygulamanın kendi uyarısı çıkar;
    /// veri kaybı riski bize ait değildir.
    ///
    /// Kapatma düğmesi olmayan pencereler (tam ekran paneller, bazı yardımcı
    /// pencereler) için `.unsupported` fırlatılır.
    static func closeWindow(pid: pid_t, title: String, frame: CGRect, order: Int) async throws {
        try await withWindow(pid: pid, title: title, frame: frame, order: order) { window in
            guard let button = elementAttribute(window, kAXCloseButtonAttribute) else {
                throw WindowActionError.unsupported("Bu pencerenin kapatma düğmesi yok; kapatılamıyor.")
            }

            let error = performAction(button, kAXPressAction)
            guard error == .success else {
                throw WindowActionError.axFailed(error.rawValue)
            }
        }
    }

    /// Pencereyi Dock'a küçültür; sarı düğmeye basmakla aynı.
    static func minimizeWindow(pid: pid_t, title: String, frame: CGRect, order: Int) async throws {
        try await withWindow(pid: pid, title: title, frame: frame, order: order) { window in
            let error = setAttribute(window, kAXMinimizedAttribute, true as CFTypeRef)
            guard error == .success else { throw WindowActionError.axFailed(error.rawValue) }
        }
    }

    /// Uygulamayı gizler. Erişilebilirlik izni gerekmez.
    ///
    /// Zaten gizliyse hiçbir şey yapmaz ve hata fırlatmaz — istenen sonuç
    /// zaten sağlanmıştır.
    static func hideApp(pid: pid_t) throws {
        let app = try runningApplication(pid: pid)
        guard !app.isHidden else { return }
        guard app.hide() else {
            throw WindowActionError.unsupported("\(displayName(app)) gizlenemedi.")
        }
    }

    /// Uygulamaya normal çıkış isteği gönderir. Erişilebilirlik izni gerekmez.
    ///
    /// `terminate()` yalnızca **isteğin gönderildiğini** bildirir; uygulama
    /// kaydedilmemiş belge nedeniyle çıkışı iptal edebilir. Zorla sonlandırma
    /// bilerek uygulanmaz.
    static func quitApp(pid: pid_t) throws {
        let app = try runningApplication(pid: pid)
        guard app.terminate() else {
            throw WindowActionError.unsupported("\(displayName(app)) için çıkış isteği gönderilemedi.")
        }
    }

    /// Pencereyi tam ekrandan çıkarır, geçişin bitmesini bekler.
    static func leaveFullScreen(pid: pid_t, title: String, frame: CGRect, order: Int) async throws {
        let window = try await withWindow(pid: pid, title: title, frame: frame, order: order) { $0 }
        guard isFullScreen(window) else { return }
        try await exitFullScreen(window)
    }

    /// Pencereyi macOS tam ekranına alır; yeni bir alan açılır.
    static func enterFullScreen(pid: pid_t, title: String, frame: CGRect, order: Int) async throws {
        let window = try await withWindow(pid: pid, title: title, frame: frame, order: order) { $0 }
        if boolAttribute(window, kAXMinimizedAttribute) == true {
            setAttribute(window, kAXMinimizedAttribute, false as CFTypeRef)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        let error = setAttribute(window, "AXFullScreen", true as CFTypeRef)
        if error == .attributeUnsupported || error == .actionUnsupported {
            throw WindowActionError.unsupported("Bu pencere tam ekran yapılamıyor.")
        }
        guard error == .success else { throw WindowActionError.axFailed(error.rawValue) }
    }

    /// Uygulamanın odaktaki penceresinin başlığı.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard isTrusted else { return nil }
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, 0.2)
        guard let window = elementAttribute(element, kAXFocusedWindowAttribute) else { return nil }
        return titleOf(window)
    }

    /// Uygulamanın o an erişilebilir pencereleri: Ekran Kaydı izni yokken başlık buradan okunur.
    /// Kısa zaman aşımı: takılan bir uygulama kaplamanın açılışını bekletmesin.
    /// Başka alandaki pencereler bu listede olmayabilir.
    static func accessibleWindows(pid: pid_t) -> [(title: String, frame: CGRect, minimized: Bool)] {
        guard isTrusted else { return [] }
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, 0.2)
        guard let windows = copyAttribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            _ = AXUIElementSetMessagingTimeout(window, 0.2)
            guard let origin = pointAttribute(window, kAXPositionAttribute),
                  let size = sizeAttribute(window, kAXSizeAttribute)
            else { return nil }
            return (titleOf(window) ?? "", CGRect(origin: origin, size: size), boolAttribute(window, kAXMinimizedAttribute) == true)
        }
    }

    /// Uygulamanın küçültülmüş pencerelerinin başlıkları.
    ///
    /// Kaplama açılırken çağrıldığı için takılan bir uygulama açılışı bekletmesin diye
    /// zaman aşımı kısadır; yanıt gelmezse liste boş döner.
    static func minimizedWindowTitles(pid: pid_t) -> [String] {
        guard isTrusted else { return [] }
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, 0.2)
        guard let windows = copyAttribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            _ = AXUIElementSetMessagingTimeout(window, 0.2)
            guard boolAttribute(window, kAXMinimizedAttribute) == true else { return nil }
            return titleOf(window)
        }
    }

    // MARK: - Space tespiti ve geçişi

    /// Pencere şu anda **aktif Space'te** mi?
    ///
    /// `.optionOnScreenOnly` yalnızca aktif Space'teki, simge durumunda olmayan
    /// pencereleri döndürür. Ölçümle doğrulandı: aynı anda 131 pencereden 10'u
    /// listelendi ve tam ekran pencereler kendi Space'lerinde kaldıkları için
    /// listede yer almadı. Hiçbir izin gerektirmez.
    ///
    /// `windowID == 0` (örnek veri) "bilinmiyor" demektir; engellememek için
    /// `true` döner.
    static func isOnActiveSpace(_ windowID: CGWindowID) -> Bool {
        guard windowID != 0 else { return true }
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return true }
        return raw.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }
    }

    /// Geçişi doğrular, olmadıysa Dock yoluna yükseltir.
    ///
    /// Doğrulama neden gecikmeli: Space geçişi animasyonludur ve hemen bakmak
    /// yanlış negatif verir. Ölçümde geçiş ~1 sn içinde tamamlandı.
    private static func verifySpaceSwitch(windowID: CGWindowID, pid: pid_t, title: String, frame: CGRect, order: Int, app: NSRunningApplication) {
        Task { @MainActor in
            // Kayma sürerken pencere henüz bu alanda görünmez; erken karar geri atıyordu.
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if SkyLight.isWindowOnCurrentSpace(windowID) ?? isOnActiveSpace(windowID) { return }
            }
            Activator.log.debug("Pencere menüsü Space geçişi yapmadı.")
            if !slideToWindow(windowID: windowID, pid: pid, title: title, frame: frame, order: order) {
                pressDockItem(for: app)
            }
        }
    }

    /// Pencerenin alanına kayar, varınca pencereyi öne alır.
    /// - Returns: Alan bilinip geçiş başlatıldıysa `true`.
    private static func slideToWindow(windowID: CGWindowID, pid: pid_t, title: String, frame: CGRect, order: Int) -> Bool {
        guard let offset = SkyLight.spaceOffset(toWindow: windowID) else { return false }
        SpaceSwitcher.move(by: offset)
        let steps = abs(offset)
        Task { @MainActor in
            // Her adım yaklaşık 0,7 sn; süre adım sayısıyla büyür.
            for _ in 0..<(12 + steps * 8) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if SkyLight.isWindowOnCurrentSpace(windowID) == true { break }
            }
            // Kayma bitmeden yükseltmek etkisiz kalıyor.
            try? await Task.sleep(nanoseconds: 350_000_000)
            scheduleDeferredRaise(pid: pid, title: title, frame: frame, order: order)
        }
        return true
    }

    /// Uygulamanın "Pencere" menüsünde hedef pencerenin öğesine basar.
    ///
    /// Neden bu yol: tam ekran pencereler `kAXWindows` listesinde görünmeyebilir,
    /// ama menü çubuğundaki pencere listesinde **her zaman** görünürler ve öğeye
    /// basmak macOS'ta Space geçişinin kendisidir. Menü ağacı menü AÇILMADAN
    /// okunabilir (ölçüldü), bu yüzden ekranda hiçbir menü açılıp kapanmaz.
    ///
    /// Ön koşul: uygulama öne alınmış olmalı.
    ///
    /// - Returns: Öğe bulunup basılabildiyse `true`.
    private static func pressWindowMenuItem(pid: pid_t, title: String) -> Bool {
        guard let item = windowMenuItem(pid: pid, title: title) else { return false }
        return performAction(item, kAXPressAction) == .success
    }

    /// Pencere menüsünde hedef pencerenin öğesi; tek eşleşme yoksa nil. Okumak için
    /// uygulamanın öne alınması gerekmez.
    private static func windowMenuItem(pid: pid_t, title: String) -> AXUIElement? {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        guard let bar = elementAttribute(applicationElement(pid: pid), kAXMenuBarAttribute) else { return nil }

        let menus = children(of: bar)
        guard !menus.isEmpty else { return nil }

        // Sırayla: yerelleştirilmiş ada göre → Cocoa yerleşimine göre (Pencere
        // menüsü Yardım'dan hemen öncedir) → tüm menüleri tara. Elma menüsü
        // (indeks 0) hiçbir zaman aday değildir.
        var candidates: [AXUIElement] = []
        if let named = menus.first(where: { windowMenuTitles.contains(titleOf($0) ?? "") }) {
            candidates.append(named)
        }
        if menus.count >= 3 { candidates.append(menus[menus.count - 2]) }
        candidates.append(contentsOf: menus.dropFirst())

        for menu in candidates {
            guard let submenu = children(of: menu).first else { continue }
            // Tek eşleşme şartı: iki pencere aynı başlığı taşıyorsa hangisine
            // basılacağı belirsizdir ve yanlış pencereye gitmek sessiz bir hatadır.
            let matches = children(of: submenu).filter {
                truncatedTitlesMatch(titleOf($0) ?? "", wanted)
            }
            guard matches.count == 1 else { continue }
            return matches[0]
        }
        return nil
    }

    /// Cocoa'nın "Pencere" menüsünün bilinen yerelleştirmeleri.
    private static let windowMenuTitles: Set<String> = [
        "Window", "Pencere", "Fenster", "Fenêtre", "Ventana", "Finestra", "Janela",
        "Venster", "Vindu", "Fönster", "Vindue", "Ikkuna", "Okno", "Ablak", "Okno",
        "ウインドウ", "ウィンドウ", "窗口", "視窗", "창", "Окно", "Παράθυρο", "نافذة"
    ]

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Uygulamanın Dock simgesine AX ile basar — kullanıcının elle tıklamasının
    /// karşılığı. Tam ekran bir uygulamada macOS bunu Space geçişi olarak yorumlar.
    ///
    /// Başarısızlık sessizdir ve zararsızdır: bu adım olmadan da uygulama zaten
    /// öne alınmıştır, yalnızca Space geçişi gerçekleşmez.
    private static func pressDockItem(for app: NSRunningApplication) {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }

        let dockElement = applicationElement(pid: dock.processIdentifier)
        guard let name = app.localizedName,
              let item = findDockItem(named: name, in: dockElement, depth: 0)
        else {
            Activator.log.debug("Dock öğesi bulunamadı; tam ekran Space geçişi atlandı.")
            return
        }
        _ = performAction(item, kAXPressAction)
    }

    /// Dock'un AX ağacında verilen başlıklı öğeyi arar.
    /// Ağaç sığdır (uygulama → liste → öğeler); derinlik yine de sınırlanır.
    private static func findDockItem(named name: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 4 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return nil }

        for child in children {
            if titleOf(child) == name, subrole(child) == "AXApplicationDockItem" {
                return child
            }
            if let found = findDockItem(named: name, in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func subrole(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Uygulama öne alındıktan sonra hedef pencereyi yeniden bulup yükseltir.
    ///
    /// İlk denemede AX ağacı boş dönen uygulamalar için ikinci şans: uygulama
    /// artık aktif ve Space geçişi tamamlanmış olduğu için ağaç dolu gelir.
    private static func scheduleDeferredRaise(pid: pid_t, title: String, frame: CGRect, order: Int) {
        for delay in [0.25, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard isTrusted else { return }
                    guard let windows = try? windowList(of: applicationElement(pid: pid)),
                          !windows.isEmpty,
                          let window = matchWindow(in: windows, title: title, frame: frame, order: order)
                    else { return }
                    let appElement = applicationElement(pid: pid)
                    _ = setAttribute(window, kAXMainAttribute, true as CFTypeRef)
                    _ = setAttribute(window, kAXFocusedAttribute, true as CFTypeRef)
                    _ = setAttribute(appElement, kAXFrontmostAttribute, true as CFTypeRef)
                    _ = performAction(window, kAXRaiseAction)
                }
            }
        }
    }

    /// Aktivasyondan sonra hedef pencereyi yeniden en öne alır.
    ///
    /// Neden gerekli: aktivasyon eşzamansızdır ve birçok uygulama öne gelirken
    /// KENDİ eski ana penceresini yükseltir. Tahmini bir gecikmeyle beklemek
    /// güvenilir değil — Space geçişi varsa süre çok değişiyor. Bunun yerine
    /// uygulamanın gerçekten öne geldiğini `NSWorkspace` bildiriminden öğrenip
    /// o an tekrar ediyoruz; bildirim gelmezse kısa bir zaman aşımıyla
    /// gözlemciyi bırakıyoruz.
    private static func reassertAfterActivation(window: AXUIElement, pid: pid_t) {
        let center = NSWorkspace.shared.notificationCenter
        var token: NSObjectProtocol?
        var finished = false

        let appElement = applicationElement(pid: pid)
        let apply = {
            // Sıra: önce hedef pencere "ana" olsun, SONRA uygulama öne alınsın.
            // `kAXFrontmost` uygulamayı ANA penceresi bağlamında öne getirir —
            // tam ekran pencereler kendi Space'lerinde yaşadığı için Space
            // geçişini tetikleyebilecek tek public yol budur; `activate()` ve
            // `NSWorkspace.openApplication` ölçümde Space değiştirmedi.
            _ = setAttribute(window, kAXMainAttribute, true as CFTypeRef)
            _ = setAttribute(window, kAXFocusedAttribute, true as CFTypeRef)
            _ = setAttribute(appElement, kAXFrontmostAttribute, true as CFTypeRef)
            _ = performAction(window, kAXRaiseAction)
        }

        let finish = {
            guard !finished else { return }
            finished = true
            if let token { center.removeObserver(token) }
            apply()
            // Uygulama aktivasyonu işlerken bir kez daha yükseltebilir; son söz
            // bizde kalsın diye kısa bir gecikmeyle tekrar ediyoruz.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                MainActor.assumeIsolated { apply() }
            }
        }

        token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard activated?.processIdentifier == pid else { return }
                finish()
            }
        }

        // Uygulama zaten öndeyse bildirim hiç gelmez; ayrıca Space geçişi
        // uzarsa bekleyip kalmayalım.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { finish() }
        }
    }

    /// Uygulamanın en öndeki penceresini öne getirir.
    ///
    /// Erişilebilirlik izni burada **şart değildir**: `activate()` tek başına
    /// uygulamayı öne getirir ve hiçbir izin istemez. İzin varsa ek olarak ana
    /// (yoksa odaklı) pencere AX ile yükseltilir — böylece uygulamanın arkada
    /// kalmış ya da simge durumundaki penceresi de geri gelir.
    ///
    /// Bu bilinçli bir istisnadır: izin yokken hata fırlatmak, izinsiz de
    /// çalışan bir eylemi gereksiz yere engellerdi.
    static func activateApp(pid: pid_t) throws {
        let app = try runningApplication(pid: pid)

        if app.isHidden { app.unhide() }

        if isTrusted {
            let appElement = applicationElement(pid: pid)
            let front = elementAttribute(appElement, kAXMainWindowAttribute)
                ?? elementAttribute(appElement, kAXFocusedWindowAttribute)
            if let front {
                if boolAttribute(front, kAXMinimizedAttribute) == true {
                    setAttribute(front, kAXMinimizedAttribute, false as CFTypeRef)
                }
                // Yükseltme burada yardımcıdır, zorunlu değil: başarısız olsa
                // bile `activate()` uygulamayı öne getirir.
                let raiseError = performAction(front, kAXRaiseAction)
                if raiseError != .success {
                    Activator.log.debug("Ön pencere yükseltilemedi (kod \(raiseError.rawValue, privacy: .public)).")
                }
            }
        }

        try activate(app)
    }

    // MARK: - Uygulama yardımcıları

    /// Süreç hâlâ yaşıyorsa `NSRunningApplication` döndürür.
    private static func runningApplication(pid: pid_t) throws -> NSRunningApplication {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw WindowActionError.applicationGone
        }
        return app
    }

    /// Uygulamayı öne getirir.
    ///
    /// macOS 14'ten itibaren parametresiz `activate()` kullanılır;
    /// `NSApplicationActivateIgnoringOtherApps` seçeneği macOS 14'te
    /// kullanımdan kaldırılmış ve etkisiz hâle gelmiştir.
    private static func activate(_ app: NSRunningApplication) throws {
        let activated: Bool
        if #available(macOS 14.0, *) {
            activated = app.activate()
        } else {
            activated = app.activate(options: [.activateIgnoringOtherApps])
        }
        guard activated else {
            if app.isTerminated { throw WindowActionError.applicationGone }
            throw WindowActionError.unsupported("\(displayName(app)) öne getirilemedi.")
        }
    }

    /// Hata metinlerinde kullanılacak, kullanıcının tanıyacağı ad.
    private static func displayName(_ app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "Uygulama"
    }

    // MARK: - AX kurulumu

    /// Süreç geneli mesajlaşma zaman aşımı yalnızca bir kez ayarlanır.
    private static var didConfigureTimeout = false

    /// Uygulamanın AX kök öğesini üretir ve zaman aşımını garanti eder.
    ///
    /// Belgeye göre bir öğeye verilen zaman aşımı **yalnızca o öğeyi** bağlar;
    /// ondan türeyen pencere/düğme öğeleri devralmaz. Bu yüzden asıl ayarı
    /// sistem geneli öğe üzerinden yapıyoruz — bu, sürecin varsayılanını
    /// değiştirir ve tüm alt öğeleri kapsar. Uygulama öğesine de ayrıca
    /// veriyoruz ki varsayılan bir şekilde sıfırlansa bile kök çağrılar korunsun.
    private static func applicationElement(pid: pid_t) -> AXUIElement {
        if !didConfigureTimeout {
            didConfigureTimeout = true
            let error = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Activator.messagingTimeout)
            if error != .success {
                Activator.log.warning("AX zaman aşımı ayarlanamadı (kod \(error.rawValue, privacy: .public)); varsayılan 6 sn geçerli.")
            }
        }
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, Activator.messagingTimeout)
        return element
    }

    /// `kAXWindowsAttribute` dizisini okur.
    ///
    /// Dizi çoğu uygulamada ön-arka (z) sırasındadır; `order` parametresi bu
    /// sıraya karşılık gelir.
    private static func windowList(of appElement: AXUIElement) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)

        switch error {
        case .success:
            return value as? [AXUIElement] ?? []
        case .apiDisabled:
            // İzin çağrı sırasında geri alınmış olabilir.
            throw WindowActionError.accessibilityDenied
        case .invalidUIElement, .cannotComplete:
            // Süreç kapandı ya da yanıt vermiyor.
            throw WindowActionError.applicationGone
        case .noValue, .attributeUnsupported:
            // Penceresiz süreç (menü çubuğu ajanı gibi) — hata değil.
            return []
        default:
            throw WindowActionError.axFailed(error.rawValue)
        }
    }

    /// Hedef pencereyi üç aşamalı olarak eşleştirir.
    ///
    /// 1. **Başlık.** Tek eşleşme varsa doğrudan kabul edilir. Birden fazla
    ///    aynı başlıklı pencere varsa (çok belgeli uygulamalarda olur) karesi
    ///    tutan seçilir, o da yoksa ilki alınır.
    /// 2. **Konum + boyut.** Başlıksız ya da başlığı değişmiş pencereler için.
    ///    Karşılaştırma CGWindowList uzayında yapılır (sol üst orijin);
    ///    `kAXPositionAttribute` de aynı uzaydadır, çevrim gerekmez.
    /// 3. **Sıra indeksi.** Son çare; liste değişmediyse doğru pencereyi verir.
    private static func matchWindow(in windows: [AXUIElement], title: String, frame: CGRect, order: Int) -> AXUIElement? {
        guard !windows.isEmpty else { return nil }

        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titles = windows.map { titleOf($0)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

        if !wanted.isEmpty {
            // 1. Tam başlık.
            let exact = windows.indices.filter { titles[$0] == wanted }
            if exact.count == 1 { return windows[exact[0]] }

            // 2. Normalleştirilmiş başlık — kısaltma ve uygulama adı eki.
            let fuzzy = windows.indices.filter { titleMatches(titles[$0], wanted: wanted) }
            if fuzzy.count == 1 { return windows[fuzzy[0]] }
            if fuzzy.count > 1, let byFrame = fuzzy.first(where: { frameMatches(windows[$0], frame) }) {
                return windows[byFrame]
            }
        }

        // 3. Konum + boyut — YALNIZCA tek aday varsa. Tam ekran pencerelerde
        //    bütün pencereler aynı kareye sahip olur; "ilk eşleşeni al" demek
        //    orada her zaman yanlış pencereyi seçmek demektir.
        let byFrame = windows.indices.filter { frameMatches(windows[$0], frame) }
        if byFrame.count == 1 { return windows[byFrame[0]] }

        // 4. Sıra indeksi — AMA yalnızca gerçekten bilgi kalmadıysa.
        //
        //    Başlık biliniyorken ve AX pencerelerinin HEPSİNİN başlığı okunabilirken
        //    hiçbirinin eşleşmemesi, hedefin bu listede olmadığı anlamına gelir.
        //    ÖLÇÜLDÜ: Chrome'un `kAXWindows` listesi tam ekran pencereyi hiç
        //    döndürmüyor; orada sıraya düşmek her seferinde masaüstündeki YANLIŞ
        //    pencereyi seçiyordu — kullanıcının bildirdiği hata tam olarak buydu.
        if !wanted.isEmpty && titles.allSatisfy({ !$0.isEmpty }) { return nil }

        if windows.indices.contains(order) { return windows[order] }
        return nil
    }

    /// CGWindowList başlığı ile AX başlığını uyuşturur.
    ///
    /// İki sistematik fark vardır ve ikisi de gerçek veride ölçüldü:
    /// - `kCGWindowName` uzun başlıkları **ortadan** kısaltır:
    ///   `"… Olmaz Öyle Saç…ah Safa Gürkan …"`.
    /// - AX başlığı çoğu uygulamada `" - Uygulama Adı"` ekiyle gelir.
    static func titleMatches(_ rawAXTitle: String, wanted rawWanted: String) -> Bool {
        let axTitle = stripStatusDecorations(rawAXTitle)
        let wanted = stripStatusDecorations(rawWanted)
        guard !axTitle.isEmpty, !wanted.isEmpty else { return false }
        if axTitle == wanted { return true }

        if let ellipsis = wanted.range(of: "\u{2026}") {
            let head = String(wanted[wanted.startIndex..<ellipsis.lowerBound])
            let tail = String(wanted[ellipsis.upperBound...])
            let headOK = head.isEmpty || axTitle.hasPrefix(head)
            let tailOK = tail.isEmpty || axTitle.contains(tail)
            if headOK && tailOK { return true }
        }

        // Kısaltma yoksa AX başlığı yalnızca ek taşıyordur.
        return axTitle.hasPrefix(wanted)
    }

    /// Başlık sonundaki **durum süslerini** atar.
    ///
    /// Ölçüm: Chrome bir sekmede ses çalarken `kCGWindowName` başlığın sonuna
    /// `🔊` ekliyor, AX başlığı eklemiyor:
    ///
    /// ```
    /// CGList: "16. Dönem İleri MSSQL | Bilgi Akademisi 🔊"
    /// AX    : "16. Dönem İleri MSSQL | Bilgi Akademisi - Google Chrome"
    /// ```
    ///
    /// Bu tek karakter `hasPrefix` eşleşmesini bozuyor ve pencere "bulunamadı"
    /// sayılıyordu. Yalnızca **sondaki** emoji ve boşluklar atılır; metnin
    /// içindeki emoji başlığın parçasıdır ve korunur.
    static func stripStatusDecorations(_ title: String) -> String {
        var result = Substring(title)
        while let last = result.last {
            let isEmoji = last.unicodeScalars.contains {
                $0.properties.isEmojiPresentation || $0.properties.isEmojiModifier
            }
            guard last.isWhitespace || isEmoji else { break }
            result = result.dropLast()
        }
        return String(result)
    }

    /// İki başlığı, **ikisi de ortadan kısaltılmış olabileceğini** varsayarak eşler.
    ///
    /// Hem `kCGWindowName` hem de menü öğesi başlıkları uzun metinleri ortadan
    /// kısaltır (`"Kölelik - Olmaz Öyle Saç…ah Safa Gürkan"`) ve kesme noktaları
    /// aynı olmak zorunda değildir. Bu yüzden karşılaştırma baş ve son parçaların
    /// birbiriyle **uyumlu** olması üzerinden yapılır, eşitlik üzerinden değil.
    static func truncatedTitlesMatch(_ a: String, _ b: String) -> Bool {
        let x = stripStatusDecorations(a)
        let y = stripStatusDecorations(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }

        let ellipsis = "\u{2026}"
        let xCut = x.range(of: ellipsis)
        let yCut = y.range(of: ellipsis)

        func split(_ s: String, _ r: Range<String.Index>) -> (String, String) {
            (String(s[s.startIndex..<r.lowerBound]), String(s[r.upperBound...]))
        }

        switch (xCut, yCut) {
        case (nil, nil):
            return false
        case (let cut?, nil):
            let (head, tail) = split(x, cut)
            return y.hasPrefix(head) && (tail.isEmpty || y.hasSuffix(tail))
        case (nil, let cut?):
            let (head, tail) = split(y, cut)
            return x.hasPrefix(head) && (tail.isEmpty || x.hasSuffix(tail))
        case (let xc?, let yc?):
            let (xh, xt) = split(x, xc)
            let (yh, yt) = split(y, yc)
            // Baş parçalar: biri diğerinin ön eki olmalı. Son parçalar: biri
            // diğerinin son eki olmalı. Kesme noktaları farklıysa da tutar.
            let headOK = xh.hasPrefix(yh) || yh.hasPrefix(xh)
            let tailOK = xt.hasSuffix(yt) || yt.hasSuffix(xt)
            return headOK && tailOK
        }
    }

    /// Başlığı kırpılmış olarak okur; okunamıyorsa `nil`.
    static func titleOf(_ window: AXUIElement) -> String? {
        stringAttribute(window, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pencerenin AX karesi verilen kareye toleransı içinde uyuyor mu.
    ///
    /// Sıfır alanlı kare "bilgi yok" demektir; yanlış eşleşme üretmemek için
    /// doğrudan reddedilir.
    private static func frameMatches(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        guard let origin = pointAttribute(window, kAXPositionAttribute),
              let size = sizeAttribute(window, kAXSizeAttribute) else { return false }

        let tolerance = Activator.frameTolerance
        return abs(origin.x - frame.origin.x) <= tolerance
            && abs(origin.y - frame.origin.y) <= tolerance
            && abs(size.width - frame.width) <= tolerance
            && abs(size.height - frame.height) <= tolerance
    }

    // MARK: - AX öznitelik köprüsü

    /// Ham öznitelik değeri. Başarısızlık burada `nil`'dir; çağıran taraf
    /// eksik özniteliği kendi bağlamında yorumlar.
    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyAttribute(element, attribute) as? Bool
    }

    /// Başka bir AX öğesine işaret eden öznitelik (pencere, düğme...).
    /// Tür kimliği doğrulanır — yanlış türde bir değer gelirse `nil`.
    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// `AXValue` sarmalayıcısını türüyle birlikte doğrular.
    private static func axValue(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> AXValue? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let boxed = value as! AXValue
        guard AXValueGetType(boxed) == type else { return nil }
        return boxed
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let boxed = axValue(element, attribute, .cgPoint) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(boxed, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let boxed = axValue(element, attribute, .cgSize) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(boxed, .cgSize, &size) else { return nil }
        return size
    }

    @discardableResult
    private static func setAttribute(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    private static func performAction(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }
}
