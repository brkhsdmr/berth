import AppKit
import BerthCore

/// İmleç ekranın sol ya da sağ dış kenarına (dikeyde ortadaki bantta) değince bir masaüstü sola ya
/// da sağa geçer (`EdgeSwitch`). Varsayılan kapalı.
///
/// - Anlık dokunma yeter. Tetikledikten sonra imleç kenardan ayrılmadan yeniden tetiklenmez.
/// - Fare düğmesi basılıyken tetiklenmez: pencere sürükleme, kenara yaslama ve boyutlandırma kenarı
///   kullanır. Sürükleme kenarda bitse bile imleç kenardan ayrılıp yeniden gelene kadar beklenir.
/// - İmleç ekranın kenarına dayanınca konumu değişmez ve fare hareketi olayı güvenilir gelmez;
///   bu yüzden imleç saniyede 30 kez yoklanır (yalnızca açıkken).
///
/// Geçiş, Dock'a yapay bir dört parmak yatay kaydırma olayı gönderilerek yapılır: yapay ^← / ^→
/// kısayolunu Dock masaüstü değiştirme olarak kabul etmiyor, uzak masaüstü öndeyken klavye de
/// oraya gider. macOS 27'den beri olaya ham IOHID verisi de eklenmeli. Olay alanları belgesizdir
/// (yöntem InstantSpaceSwitcher'dan, MIT); bir macOS güncellemesi bozabilir. Olay göndermek
/// Erişilebilirlik izni ister.
@MainActor
final class EdgeSwitchMonitor {
    /// `true` döndükçe tetiklenmez (sahne açıkken).
    var isBlocked: () -> Bool = { false }

    private var enabled = false
    private var band = EdgeSwitch.defaultBand
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Başlangıçta kapalı: imleç zaten kenardaysa açılır açılmaz tetiklemesin.
    private var isArmed = false
    private var lastSwitch = Date.distantPast

    private static let pollInterval: TimeInterval = 1.0 / 30.0
    /// Kayma animasyonu sürerken ikinci geçiş gönderilmesin.
    private static let minimumInterval: TimeInterval = 0.6
    /// Kenara bu kadar nokta yaklaşınca dokunmuş sayılır.
    private static let touchMargin: CGFloat = 1
    /// Yeniden kurulmak için kenardan bu kadar uzaklaşmalı.
    private static let rearmMargin: CGFloat = 6

    func configure(enabled: Bool, band: Double) {
        self.enabled = enabled
        self.band = band
        isArmed = false
        if enabled { installObservers() } else { removeObservers() }
        syncTimer()
    }

    private func syncTimer() {
        if enabled {
            guard timer == nil else { return }
            let created = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            created.tolerance = Self.pollInterval * 0.5
            RunLoop.main.add(created, forMode: .common)
            timer = created
        } else {
            timer?.invalidate()
            timer = nil
            isArmed = false
        }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let screens = NSScreen.screens.map(\.frame)
        guard let side = EdgeSwitch.side(at: point, screens: screens, band: band, margin: Self.touchMargin) else {
            if !isArmed, EdgeSwitch.side(at: point, screens: screens, band: band, margin: Self.rearmMargin) == nil {
                isArmed = true
            }
            return
        }
        guard isArmed else { return }
        // Tetiklesin ya da tetiklemesin: yeni geçiş için kenardan ayrılmak gerekir.
        isArmed = false
        guard NSEvent.pressedMouseButtons == 0, !isBlocked(),
              Date().timeIntervalSince(lastSwitch) >= Self.minimumInterval,
              WindowActivator.isTrusted
        else { return }
        lastSwitch = Date()
        Self.switchSpace(side)
    }

    // MARK: Geçiş

    private static let swipeQueue = DispatchQueue(label: "berth.edge-swipe")
    /// İlerleme gerçek bir parmak gibi 0'dan 1'e adım adım artar: macOS'un kendi kayma animasyonu.
    /// 0,15 sn ^→ kadar doğal bulundu (2026-11-02).
    private static let swipeDuration: TimeInterval = 0.15
    private static let swipeSteps = 8
    /// macOS 27'den beri Dock yapay olayı ham IOHID verisi ve eşlik eden bir hareket olayı olmadan
    /// yok sayıyor (ölçüldü, 27.2).
    private static let needsHIDPayload = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    static func switchSpace(_ side: EdgeSwitch.Side) {
        // Adımlar arasında beklemek gerekiyor; ana iş parçacığı tutulmasın.
        swipeQueue.async {
            if needsHIDPayload {
                let sign = modernSign(side)
                postModernSwipe(phase: 1, progress: 0, velocity: 0)
                for step in 1...swipeSteps {
                    usleep(useconds_t(swipeDuration / Double(swipeSteps) * 1_000_000))
                    postModernSwipe(phase: 2, progress: sign * Double(step) / Double(swipeSteps), velocity: sign)
                }
                // Hız eski yoldaki gibi 1: InstantSpaceSwitcher'ın 9999'u kaymayı fırlatıyor, hızlı geliyor.
                postModernSwipe(phase: 4, progress: sign, velocity: sign)
            } else {
                let sign = side == .right ? 1.0 : -1.0
                postLegacySwipe(phase: 1, progress: 0, velocity: 0)
                for step in 1...swipeSteps {
                    usleep(useconds_t(swipeDuration / Double(swipeSteps) * 1_000_000))
                    postLegacySwipe(phase: 2, progress: sign * Double(step) / Double(swipeSteps), velocity: sign)
                }
                postLegacySwipe(phase: 4, progress: sign, velocity: sign)
            }
        }
    }

    private nonisolated static func field(_ raw: UInt32) -> CGEventField { unsafeBitCast(raw, to: CGEventField.self) }

    /// macOS 26 ve öncesi.
    private nonisolated static func postLegacySwipe(phase: Int64, progress: Double, velocity: Double) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(field(55), value: 30)     // olay tipi: DockControl
        event.setIntegerValueField(field(110), value: 23)    // IOHID hareket tipi: DockSwipe
        event.setIntegerValueField(field(132), value: phase) // 1 başladı, 2 sürüyor, 4 bitti
        event.setDoubleValueField(field(124), value: progress)
        event.setIntegerValueField(field(123), value: 1)     // yatay
        event.setDoubleValueField(field(129), value: velocity)
        event.setDoubleValueField(field(130), value: velocity)
        event.post(tap: .cgSessionEventTap)
    }

    /// macOS 27'de yön doğal kaydırma ayarına bağlı (sağa geçiş doğal kaydırmada eksi).
    private nonisolated static func modernSign(_ side: EdgeSwitch.Side) -> Double {
        let natural = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
        let sign = side == .right ? -1.0 : 1.0
        return natural ? sign : -sign
    }

    /// macOS 27: gerçek trackpad olayının taşıdığı alanlar, olay verisine eklenen ham IOHID verisi
    /// (alan 4205) ve ardından boş bir hareket olayı. Yöntem InstantSpaceSwitcher'dan (MIT).
    private nonisolated static func postModernSwipe(phase: Int64, progress: Double, velocity: Double) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(field(55), value: 30)
        event.setIntegerValueField(field(110), value: 23)
        event.setIntegerValueField(field(132), value: phase)
        event.setIntegerValueField(field(123), value: 1)
        event.setDoubleValueField(field(124), value: progress)
        event.setIntegerValueField(field(134), value: phase)                       // evre (ikinci alan)
        event.setDoubleValueField(field(138), value: 3)
        event.setDoubleValueField(field(169), value: Double(mach_absolute_time()))
        event.setDoubleValueField(field(125), value: 0.1)                          // konum X
        if velocity != 0 { event.setDoubleValueField(field(129), value: velocity) }
        guard let augmented = withHIDPayload(event, phase: phase, progress: progress, velocity: velocity),
              let companion = CGEvent(source: nil)
        else { return }
        companion.setIntegerValueField(field(55), value: 29)                       // olay tipi: Gesture
        augmented.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
    }

    private nonisolated static func withHIDPayload(_ event: CGEvent, phase: Int64, progress: Double, velocity: Double) -> CGEvent? {
        guard let original = event.data as Data?, original.count >= 4, original.prefix(4) == Data([0, 0, 0, 2]) else { return nil }
        func fixed(_ value: Double) -> Int32 {
            let raw = Int32(value * 65536)
            return raw == 0 && value != 0 ? (value > 0 ? 1 : -1) : raw
        }
        var payload = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) } }
        let includeVelocity = velocity != 0 || phase == 4
        // Kuyruk başlığı: zaman, gönderen, seçenekler, öznitelik uzunluğu, olay sayısı (28 bayt).
        append(UInt64(mach_absolute_time())); append(UInt64(0)); append(UInt32(0)); append(UInt32(0))
        append(UInt32(includeVelocity ? 2 : 1))
        // Akışkan dokunma hareketi (40 bayt): taban (boyut, tip 23, evre << 24 seçenek, derinlik).
        append(UInt32(40)); append(UInt32(23)); append(UInt32(UInt32(phase & 0xFF) << 24)); append(UInt32(0))
        append(fixed(0.1)); append(Int32(0)); append(Int32(0))   // konum x, y, z
        append(UInt32(0))                                          // kaydırma maskesi
        append(UInt16(1)); append(UInt16(3))                       // yatay, Dock birincil
        append(fixed(progress))
        if includeVelocity {
            // Hız (28 bayt): tip 9, derinlik 1.
            append(UInt32(28)); append(UInt32(9)); append(UInt32(0)); append(UInt32(1))
            append(fixed(velocity)); append(Int32(0)); append(Int32(0))
        }
        var data = original
        data.append(contentsOf: [UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF), UInt8((4205 >> 8) & 0xFF), UInt8(4205 & 0xFF)])
        data.append(payload)
        return CGEvent(withDataAllocator: nil, data: data as CFData)
    }

    // MARK: Uyku

    /// Uykuda yoklama durur; uyanınca imleç kenardaysa hemen tetiklemesin.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer?.invalidate()
                self?.timer = nil
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isArmed = false
                self?.syncTimer()
            }
        })
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}
