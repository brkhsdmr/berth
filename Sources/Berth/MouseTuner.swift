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
        case off, system, notConnected, applied, appliedFlat, failed

        var text: String {
            switch self {
            case .off: return tx("Kapalı", "Off")
            case .system: return tx("macOS'un kendi ayarı", "macOS's own setting")
            case .notConnected: return tx("Bağlı değil", "Not connected")
            case .applied: return tx("Berth ayarı uygulanıyor", "Berth's setting is active")
            case .appliedFlat:
                return tx("Berth ayarı uygulanıyor. Bu fare macOS'un ivme eğrisini değiştirmeye izin vermiyor; ivmeyi Berth hesaplıyor.",
                          "Berth's setting is active. This mouse doesn't let macOS's acceleration curve be changed; Berth computes the acceleration.")
            case .failed: return tx("Uygulanamadı", "Couldn't apply")
            }
        }
    }

    /// Bağlı fareler ve kayıtlı her farenin durumu değişince.
    var onChange: (([String], [String: Status]) -> Void)?
    private(set) var connected: [String] = []
    private(set) var statuses: [String: Status] = [:]

    private var config = Config()
    private let dynamic = DynamicPointer()
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
        dynamic.set([:])
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

    /// Çözünürlüğü yok sayan fareler (DriverKit sürücüsü, ör. Bluetooth LE): hız düz ölçekle verilir
    /// (bkz. `MouseTune`).
    static func flatMice() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, mouseMatching(className: "AppleUserHIDEventService"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let name = IORegistryEntryCreateCFProperty(service, kIOHIDProductKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                names.insert(name)
            }
        }
        return names
    }

    private static func mouseMatching(className: String = "IOHIDDevice") -> NSMutableDictionary {
        let matching = IOServiceMatching(className) as NSMutableDictionary
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Mouse
        return matching
    }

    /// `force`: macOS değerleri ezmiş olabilir (bağlanma, uyanış, Sistem Ayarları), yeniden yaz.
    private func apply(force: Bool) {
        connected = Self.connectedMice()
        let flat = Self.flatMice()
        var next: [String: Status] = [:]
        var accelerated: [String: PointerAccelerator] = [:]
        for name in Set(connected).union(config.profiles.keys) {
            let profile = config.profiles[name]
            let wanted = config.enabled && profile?.enabled == true
            guard connected.contains(name) else {
                tuned[name] = nil // Yeniden bağlanınca macOS değerleriyle gelir.
                next[name] = .notConnected
                continue
            }
            if wanted, let profile {
                let isFlat = flat.contains(name)
                let applied: Status = isFlat ? .appliedFlat : .applied
                if isFlat { accelerated[name] = PointerAccelerator(speed: profile.speed, acceleration: profile.acceleration) }
                if !force, tuned[name] == profile {
                    next[name] = applied
                    continue
                }
                let properties = isFlat ? MouseTune.flatPropertiesJSON(speed: profile.speed)
                    : MouseTune.propertiesJSON(speed: profile.speed, acceleration: profile.acceleration)
                let ok = Self.write(properties, mouseName: name)
                tuned[name] = ok ? profile : nil
                next[name] = ok ? applied : .failed
            } else {
                if tuned.removeValue(forKey: name) != nil { Self.restoreSystemValues(mouseName: name) }
                next[name] = config.enabled ? .system : .off
            }
        }
        dynamic.set(accelerated, force: force)
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

/// Eğrisi değiştirilemeyen farelerde ivme (bkz. `PointerAccelerator`): imleç hareketleri dinlenir
/// (yalnızca dinleyen olay musluğu), farenin düz çarpanı olay sistemi istemcisiyle anlık yazılır
/// (her değişiklikte `hidutil` çalıştırmak çok yavaş).
///
/// Hangi aygıtın hareket ettiği olaydan bilinmiyor; trackpad aynı anda kullanılırsa hız tahmini
/// karışabilir, çarpan yine yalnız bu farelere yazılır. Birden çok böyle fare varsa hız, ilkinin
/// çarpanıyla tahmin edilir.
@MainActor
private final class DynamicPointer {
    private var accelerators: [String: PointerAccelerator] = [:]
    private var services: [String: [IOHIDServiceClient]] = [:]
    private var client: IOHIDEventSystemClient?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var restTimer: Timer?
    private var lastMove = CFAbsoluteTimeGetCurrent()

    /// `force`: fare yeniden bağlanmış olabilir, servisler yeniden aranır.
    func set(_ next: [String: PointerAccelerator], force: Bool = false) {
        let active = next.filter { $0.value.acceleration > 0 }
        if active.keys.sorted() != accelerators.keys.sorted() || force { services = [:] }
        accelerators = active
        guard !active.isEmpty else {
            stop()
            return
        }
        if services.isEmpty { findServices() }
        start()
    }

    private func findServices() {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
        if client == nil, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventSystemClientCreateSimpleClient") {
            client = unsafeBitCast(symbol, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
        }
        guard let client, let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return }
        for service in all where IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0 {
            guard let name = IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String,
                  accelerators[name] != nil else { continue }
            services[name, default: []].append(service)
        }
    }

    private func start() {
        guard tap == nil else { return }
        let mask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let pointer = Unmanaged<DynamicPointer>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let tap = pointer.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            MainActor.assumeIsolated { pointer.moved((dx * dx + dy * dy).squareRoot()) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            DockTrace.log("fare ivmesi: olay musluğu kurulamadı")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Hareket durunca çarpan hıza döner.
        restTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restIfIdle() }
        }
    }

    private func stop() {
        restTimer?.invalidate()
        restTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        services = [:]
    }

    private func moved(_ distance: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let interval = now - lastMove
        lastMove = now
        // Hız ilk farenin çarpanıyla tahmin edilir; aynı ham hız her fareye kendi eğrisiyle uygulanır.
        guard let lead = accelerators.keys.sorted().first, var first = accelerators[lead] else { return }
        let before = first.factor
        _ = first.move(distance: distance, interval: interval)
        let raw = distance / before
        for name in accelerators.keys {
            if name == lead {
                accelerators[name] = first
                write(first.factor, to: name, previous: before)
            } else if var other = accelerators[name] {
                let previous = other.factor
                _ = other.move(distance: raw * previous, interval: interval)
                accelerators[name] = other
                write(other.factor, to: name, previous: previous)
            }
        }
    }

    private func restIfIdle() {
        guard CFAbsoluteTimeGetCurrent() - lastMove > 0.08 else { return }
        for name in accelerators.keys {
            if let factor = accelerators[name]?.rest() { write(factor, to: name, previous: nil) }
        }
    }

    private func write(_ factor: Double, to name: String, previous: Double?) {
        guard factor != previous else { return }
        for service in services[name] ?? [] {
            IOHIDServiceClientSetProperty(service, "HIDUseLinearScalingMouseAcceleration" as CFString, 1 as CFNumber)
            IOHIDServiceClientSetProperty(service, kIOHIDMouseAccelerationTypeKey as CFString, MouseTune.fixed(factor) as CFNumber)
        }
    }
}
