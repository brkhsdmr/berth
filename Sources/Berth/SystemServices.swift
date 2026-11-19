import AppKit
import Carbon.HIToolbox
import BerthCore
import OSLog

// MARK: - Genel kısayol

/// Carbon genel kısayolu: izin istemez, olayı tüketir.
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    private let identifier: UInt32

    /// `id` her kısayolda farklı olmalı: tüm kısayollar aynı olay işleyicisine düşer, işleyici
    /// yalnızca kendi kimliğini işler, gerisini sıradakine bırakır.
    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.identifier = id

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == hotKey.identifier else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &type, context, &handler)
        guard installed == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x574E5632), id: id) // "WNV2"
        let registered = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference
        )
        guard registered == noErr else { return nil }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: - Masaüstü geçişi

/// Masaüstleri arasında macOS'un kendi kayma animasyonuyla geçer.
///
/// V1'in kenar geçişinde ölçülen yöntem: Dock'a yapay bir yatay kaydırma hareketi
/// gönderir. Kısayol taklidi yerine bu kullanılıyor çünkü bu makinede masaüstü
/// kısayolları özelleştirilmiş ve hareket onlardan bağımsız.
/// Özel olay alanları kullanır, bir macOS güncellemesi bozabilir.
enum SpaceSwitcher {
    private static let queue = DispatchQueue(label: "berth.space-switch")
    /// İlerleme gerçek bir parmak gibi 0'dan 1'e adım adım artar: macOS'un kendi kayma animasyonu.
    /// 0,15 sn kenar geçişinde doğal bulundu (2026-11-02).
    private static let duration: TimeInterval = 0.15
    private static let steps = 8
    /// Kayma animasyonu bitmeden gönderilen ikinci hareket yutulur.
    private static let settleDelay: useconds_t = 520_000
    /// macOS 27'den beri Dock yapay olayı ham IOHID verisi ve eşlik eden bir hareket olayı olmadan
    /// yok sayıyor (ölçüldü, 27.2).
    private static let needsHIDPayload = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    /// - Parameter offset: Pozitif sağa, negatif sola kaç masaüstü gidileceği.
    static func move(by offset: Int) {
        guard offset != 0 else { return }
        // Adımlar arasında beklemek gerekiyor; ana iş parçacığı tutulmasın.
        queue.async {
            for index in 0..<abs(offset) {
                if index > 0 { usleep(settleDelay) }
                swipe(right: offset > 0)
            }
        }
    }

    private static func swipe(right: Bool) {
        let post = needsHIDPayload ? postModern : postLegacy
        let sign = needsHIDPayload ? modernSign(right: right) : (right ? 1.0 : -1.0)
        post(1, 0, 0)
        for step in 1...steps {
            usleep(useconds_t(duration / Double(steps) * 1_000_000))
            post(2, sign * Double(step) / Double(steps), sign)
        }
        // Hız 1: InstantSpaceSwitcher'ın 9999'u kaymayı fırlatıyor, hızlı geliyor.
        post(4, sign, sign)
    }

    private static func field(_ raw: UInt32) -> CGEventField { unsafeBitCast(raw, to: CGEventField.self) }

    /// macOS 26 ve öncesi.
    private static func postLegacy(phase: Int64, progress: Double, velocity: Double) {
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
    private static func modernSign(right: Bool) -> Double {
        let natural = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
        let sign = right ? -1.0 : 1.0
        return natural ? sign : -sign
    }

    /// macOS 27: gerçek trackpad olayının taşıdığı alanlar, olay verisine eklenen ham IOHID verisi
    /// (alan 4205) ve ardından boş bir hareket olayı. Yöntem InstantSpaceSwitcher'dan (MIT).
    private static func postModern(phase: Int64, progress: Double, velocity: Double) {
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

    private static func withHIDPayload(_ event: CGEvent, phase: Int64, progress: Double, velocity: Double) -> CGEvent? {
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
}

// MARK: - Düzen kaydı

/// Kullanıcının düzenini saklar. İlk çalıştırmada boş başlar; sahne açılınca açık uygulamalar sabitlenir.
@MainActor
final class ArrangementStore: ObservableObject {
    private static let key = "arrangement"
    private static let log = Logger(subsystem: "io.github.brkhsdmr.berth", category: "Arrangement")

    @Published private(set) var arrangement: Arrangement

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            do {
                arrangement = try JSONDecoder().decode(Arrangement.self, from: data)
                return
            } catch {
                Self.log.error("Kayıtlı düzen okunamadı, baştan kuruluyor: \(error.localizedDescription, privacy: .public)")
            }
        }
        arrangement = Arrangement(pinned: [])
    }

    func update(_ change: (inout Arrangement) -> Void) {
        var copy = arrangement
        change(&copy)
        guard copy != arrangement else { return }
        arrangement = copy
        if let data = try? JSONEncoder().encode(copy) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - İzinler

@MainActor
enum Permissions {
    static var screenRecording: Bool {
        #if DEBUG
        // Sınama: macOS iznini kapatmadan izinsiz davranışı görmek için.
        if UserDefaults.standard.bool(forKey: "simulateNoScreenRecording") { return false }
        #endif
        return CGPreflightScreenCaptureAccess()
    }
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Yalnızca Erişilebilirlik: Ekran Kaydı isteğe bağlıdır, kullanıcı önizlemeleri açarsa istenir.
    static func requestAccessibilityIfNeeded() {
        if !accessibility { WindowActivator.requestTrust() }
    }

    static func requestScreenRecording() {
        guard !screenRecording else { return }
        if !CGRequestScreenCaptureAccess() { openScreenRecordingSettings() }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
