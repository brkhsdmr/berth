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
    private static let duration: TimeInterval = 0.15
    private static let steps = 8
    /// Kayma animasyonu bitmeden gönderilen ikinci hareket yutulur.
    private static let settleDelay: useconds_t = 520_000

    /// - Parameter offset: Pozitif sağa, negatif sola kaç masaüstü gidileceği.
    static func move(by offset: Int) {
        guard offset != 0 else { return }
        let sign: Double = offset > 0 ? 1 : -1
        queue.async {
            for index in 0..<abs(offset) {
                if index > 0 { usleep(settleDelay) }
                post(phase: 1, progress: 0, velocity: 0)
                for step in 1...steps {
                    usleep(useconds_t(duration / Double(steps) * 1_000_000))
                    post(phase: 2, progress: sign * Double(step) / Double(steps), velocity: sign)
                }
                post(phase: 4, progress: sign, velocity: sign)
            }
        }
    }

    private static func post(phase: Int64, progress: Double, velocity: Double) {
        func field(_ raw: UInt32) -> CGEventField { unsafeBitCast(raw, to: CGEventField.self) }
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(field(55), value: 30)    // olay tipi: DockControl
        event.setIntegerValueField(field(110), value: 23)   // hareket tipi: DockSwipe
        event.setIntegerValueField(field(132), value: phase)
        event.setDoubleValueField(field(124), value: progress)
        event.setIntegerValueField(field(123), value: 1)    // yatay
        event.setDoubleValueField(field(129), value: velocity)
        event.setDoubleValueField(field(130), value: velocity)
        event.post(tap: .cgSessionEventTap)
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
