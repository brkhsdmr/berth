import AppKit
import BerthCore
import IOKit
import IOKit.hid

/// Seçili harici fareye hız ve ivmeyi `hidutil` ile yazar (bkz. `MouseTune`). Yalnız o farenin
/// servisine yazar, izin istemez, kalıcı değildir.
///
/// macOS bu değerleri fare yeniden bağlanınca, uyanışta ve Sistem Ayarları'nda fare kaydırıcısı
/// oynatılınca kendi değerleriyle ezer; bu durumlarda yeniden uygulanır. Kapatılınca ya da Berth
/// kapanınca macOS'un kendi değerleri geri yazılır. Berth çökerse değerler fare yeniden bağlanana
/// ya da Mac uyuyup uyanana kadar kalır.
@MainActor
final class MouseTuner {
    struct Config: Equatable {
        var enabled = false
        var mouseName = ""
        var speed = MouseTune.defaultSpeed
        var acceleration = MouseTune.defaultAcceleration
    }

    enum Status: Equatable {
        case off, noMouseChosen, notConnected, applied, failed

        var text: String {
            switch self {
            case .off: return tx("Kapalı", "Off")
            case .noMouseChosen: return tx("Fare seçilmedi", "No mouse selected")
            case .notConnected: return tx("Fare bağlı değil; bağlanınca uygulanır", "Mouse not connected; applied when it connects")
            case .applied: return tx("Uygulanıyor", "Active")
            case .failed: return tx("Uygulanamadı", "Couldn't apply")
            }
        }
    }

    var onStatus: ((Status) -> Void)?
    private(set) var status = Status.off {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    private var config = Config()
    /// Değerlerimizi yazdığımız fare: kapatılınca ya da fare değişince geri yüklenir.
    private var tunedMouse: String?
    private var observers: [NSObjectProtocol] = []
    private var notificationPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0

    func configure(_ next: Config) {
        config = next
        if let tunedMouse, !next.enabled || tunedMouse != next.mouseName {
            Self.restoreSystemValues(mouseName: tunedMouse)
            self.tunedMouse = nil
        }
        if next.enabled { installObservers() } else { removeObservers() }
        apply()
    }

    /// Berth kapanırken: fareyi macOS'un kendi değerlerine bırakır.
    func shutdown() {
        removeObservers()
        if let tunedMouse { Self.restoreSystemValues(mouseName: tunedMouse) }
        tunedMouse = nil
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

    private func apply() {
        guard config.enabled else { status = .off; return }
        guard !config.mouseName.isEmpty else { status = .noMouseChosen; return }
        guard Self.connectedMice().contains(config.mouseName) else { status = .notConnected; return }
        let ok = Self.write(MouseTune.propertiesJSON(speed: config.speed, acceleration: config.acceleration),
                            mouseName: config.mouseName)
        if ok { tunedMouse = config.mouseName }
        status = ok ? .applied : .failed
    }

    /// Sistem Ayarları'ndaki izleme hızı (`com.apple.mouse.scaling`) ve varsayılan çözünürlük.
    private static func restoreSystemValues(mouseName: String) {
        let scaling = (CFPreferencesCopyAppValue("com.apple.mouse.scaling" as CFString, kCFPreferencesAnyApplication) as? NSNumber)?.doubleValue ?? 1
        _ = write(MouseTune.systemPropertiesJSON(scaling: scaling), mouseName: mouseName)
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
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplySoon() }
        })
        // Sistem Ayarları'nda fare kaydırıcısı oynatılırsa macOS değerlerimizi ezer.
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.systempreferences" else { return }
            MainActor.assumeIsolated { self?.apply() }
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
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.mouseMatching(), callback,
                                         Unmanaged.passUnretained(self).toOpaque(), &matchIterator)
        while case let service = IOIteratorNext(matchIterator), service != 0 { IOObjectRelease(service) }
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        if matchIterator != 0 { IOObjectRelease(matchIterator); matchIterator = 0 }
        if let port = notificationPort { IONotificationPortDestroy(port); notificationPort = nil }
    }

    /// Olay servisi cihazdan biraz sonra hazır oluyor ve macOS kendi değerlerini bizden sonra
    /// yazabiliyor; iki kez denenir.
    private func reapplySoon() {
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.config.enabled else { return }
                    self.apply()
                }
            }
        }
    }
}
