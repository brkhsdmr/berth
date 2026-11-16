import AppKit
import BerthCore
import IOKit
import IOKit.hid

/// Harici farelere hız ve ivmeyi `hidutil` ile yazar (bkz. `MouseTune`). Her fare kendi ayarıyla
/// (`MouseProfile`, ürün adıyla); ayarı açık olan bağlı farelerin hepsine uygulanır. Yalnız o
/// farelerin servisine yazar, izin istemez, kalıcı değildir.
///
/// macOS bu değerleri fare yeniden bağlanınca, uyanışta ve Sistem Ayarları'nda fare kaydırıcısı
/// oynatılınca kendi değerleriyle ezer; bu durumlarda yeniden uygulanır. Bir farenin ayarı
/// kapatılınca ya da Berth kapanınca o fareye macOS'un kendi değerleri geri yazılır. Berth çökerse
/// değerler fare yeniden bağlanana ya da Mac uyuyup uyanana kadar kalır.
@MainActor
final class MouseTuner {
    struct Config: Equatable {
        /// Hepsini birden kapatır.
        var enabled = false
        var profiles: [String: MouseProfile] = [:]
    }

    enum Status: Equatable {
        case off, system, notConnected, applied, failed

        var text: String {
            switch self {
            case .off: return tx("Kapalı", "Off")
            case .system: return tx("macOS'un kendi ayarı", "macOS's own setting")
            case .notConnected: return tx("Bağlı değil", "Not connected")
            case .applied: return tx("Berth ayarı uygulanıyor", "Berth's setting is active")
            case .failed: return tx("Uygulanamadı", "Couldn't apply")
            }
        }
    }

    /// Bağlı fareler ve kayıtlı her farenin durumu değişince.
    var onChange: (([String], [String: Status]) -> Void)?
    private(set) var connected: [String] = []
    private(set) var statuses: [String: Status] = [:]

    private var config = Config()
    /// Değerlerimizi yazdığımız fareler ve yazılan değer: kapatılınca geri yüklenir, değer aynıysa
    /// yeniden yazılmaz (bağlanma ve uyanış dışında).
    private var tuned: [String: MouseProfile] = [:]
    private var observers: [NSObjectProtocol] = []
    private var notificationPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var removeIterator: io_iterator_t = 0

    init() {
        installObservers()
        refresh()
    }

    func configure(_ next: Config) {
        config = next
        apply(force: false)
    }

    /// Berth kapanırken: fareleri macOS'un kendi değerlerine bırakır.
    func shutdown() {
        removeObservers()
        for name in tuned.keys { Self.restoreSystemValues(mouseName: name) }
        tuned.removeAll()
    }

    /// macOS'un izleme hızı (Sistem Ayarları > Fare).
    static var systemScaling: Double {
        (CFPreferencesCopyAppValue("com.apple.mouse.scaling" as CFString, kCFPreferencesAnyApplication) as? NSNumber)?.doubleValue ?? 1
    }

    /// Bağlı harici fareler (yerleşik trackpad hariç), ürün adıyla.
    static func connectedMice() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, mouseMatching(), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property(kIOHIDBuiltInKey) as? Bool) != true,
                  let name = property(kIOHIDProductKey) as? String, !name.isEmpty
            else { continue }
            names.insert(name)
        }
        return names.sorted()
    }

    private static func mouseMatching() -> NSMutableDictionary {
        let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Mouse
        return matching
    }

    /// `force`: macOS değerleri ezmiş olabilir (bağlanma, uyanış, Sistem Ayarları), yeniden yaz.
    private func apply(force: Bool) {
        connected = Self.connectedMice()
        var next: [String: Status] = [:]
        for name in Set(connected).union(config.profiles.keys) {
            let profile = config.profiles[name]
            let wanted = config.enabled && profile?.enabled == true
            guard connected.contains(name) else {
                tuned[name] = nil // Yeniden bağlanınca macOS değerleriyle gelir.
                next[name] = .notConnected
                continue
            }
            if wanted, let profile {
                if !force, tuned[name] == profile {
                    next[name] = .applied
                    continue
                }
                let ok = Self.write(MouseTune.propertiesJSON(speed: profile.speed, acceleration: profile.acceleration), mouseName: name)
                tuned[name] = ok ? profile : nil
                next[name] = ok ? .applied : .failed
            } else {
                if tuned.removeValue(forKey: name) != nil { Self.restoreSystemValues(mouseName: name) }
                next[name] = config.enabled ? .system : .off
            }
        }
        statuses = next
        onChange?(connected, statuses)
    }

    private func refresh() { apply(force: false) }

    private static func restoreSystemValues(mouseName: String) {
        _ = write(MouseTune.systemPropertiesJSON(scaling: systemScaling), mouseName: mouseName)
    }

    private static func write(_ properties: String, mouseName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--matching", MouseTune.matchingJSON(mouseName: mouseName), "--set", properties]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    // MARK: Bildirimler

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplySoon() }
        })
        // Sistem Ayarları'nda fare kaydırıcısı oynatılırsa macOS değerlerimizi ezer.
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.systempreferences" else { return }
            MainActor.assumeIsolated { self?.apply(force: true) }
        })

        // Fare (yeniden) bağlanınca yeni servis macOS'un değerleriyle gelir.
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let callback: IOServiceMatchingCallback = { context, iterator in
            var any = false
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service); any = true }
            guard any, let context else { return }
            let tuner = Unmanaged<MouseTuner>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { tuner.reapplySoon() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.mouseMatching(), callback, context, &matchIterator)
        while case let service = IOIteratorNext(matchIterator), service != 0 { IOObjectRelease(service) }
        // Çıkarılan fare listeden düşsün.
        let removed: IOServiceMatchingCallback = { context, iterator in
            var any = false
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service); any = true }
            guard any, let context else { return }
            let tuner = Unmanaged<MouseTuner>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { tuner.refresh() }
        }
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.mouseMatching(), removed, context, &removeIterator)
        while case let service = IOIteratorNext(removeIterator), service != 0 { IOObjectRelease(service) }
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        if matchIterator != 0 { IOObjectRelease(matchIterator); matchIterator = 0 }
        if removeIterator != 0 { IOObjectRelease(removeIterator); removeIterator = 0 }
        if let port = notificationPort { IONotificationPortDestroy(port); notificationPort = nil }
    }

    /// Olay servisi cihazdan biraz sonra hazır oluyor ve macOS kendi değerlerini bizden sonra
    /// yazabiliyor; iki kez denenir.
    private func reapplySoon() {
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.apply(force: true) }
            }
        }
    }
}
