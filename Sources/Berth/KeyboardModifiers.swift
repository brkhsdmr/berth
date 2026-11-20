import AppKit
import BerthCore
import IOKit
import IOKit.hid

/// macOS'un klavye başına niteleme tuşu eşlemesi (Sistem Ayarları > Klavye > Niteleme Tuşları).
///
/// Berth ayrı bir eşleme tutmaz: hazır ayarlar macOS'un kendi ayarına yazılır, Sistem Ayarları'nda
/// da aynısı görünür ve Berth kapalıyken de geçerlidir. Yazılan eşleme hemen etkili olsun diye klavye
/// servisine de `hidutil` ile uygulanır (Sistem Ayarları'nın kullandığı özellik).
enum KeyboardModifiers {
    struct Keyboard: Hashable, Identifiable {
        var name: String
        var vendor: Int
        var product: Int
        var builtIn: Bool
        var id: String { "\(vendor)-\(product)" }
    }

    private static let host = (kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)

    /// Bağlı klavyeler, dahili önce.
    static func connected() -> [Keyboard] {
        let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Keyboard
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        // Bazı fareler tuş arayüzünü klavye olarak da bildiriyor.
        let mice = Set(MainActor.assumeIsolated { MouseTuner.connectedMice() })
        var result: [String: Keyboard] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let builtIn = property(kIOHIDBuiltInKey) as? Bool ?? false
            let vendor = property(kIOHIDVendorIDKey) as? Int ?? 0
            let product = property(kIOHIDProductIDKey) as? Int ?? 0
            let name = property(kIOHIDProductKey) as? String ?? ""
            // Klavye gibi görünen ama klavye olmayan servisler (ör. bazı farelerin tuş arayüzü) adsız gelir.
            guard builtIn || (!name.isEmpty && !mice.contains(name)) else { continue }
            let keyboard = Keyboard(name: builtIn ? tx("Dahili klavye", "Built-in keyboard") : name, vendor: builtIn ? 0 : vendor,
                                    product: builtIn ? 0 : product, builtIn: builtIn)
            result[keyboard.id] = keyboard
        }
        return result.values.sorted { ($0.builtIn ? 0 : 1, $0.name) < ($1.builtIn ? 0 : 1, $1.name) }
    }

    /// macOS'un bu klavye için kayıtlı eşlemesi (kendine eşlenenler hariç).
    static func mapping(for keyboard: Keyboard) -> Set<ModifierPair> {
        let key = ModifierPreset.preferenceKey(vendor: keyboard.vendor, product: keyboard.product) as CFString
        guard let items = CFPreferencesCopyValue(key, host.0, host.1, host.2) as? [[String: Any]] else { return [] }
        let pairs = items.compactMap { item -> ModifierPair? in
            guard let source = (item["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.int64Value,
                  let destination = (item["HIDKeyboardModifierMappingDst"] as? NSNumber)?.int64Value
            else { return nil }
            return ModifierPair(source, destination)
        }
        return ModifierPreset.effective(pairs)
    }

    /// macOS'un ayarına yazar ve hemen uygular. Boş küme macOS'un saptanmışına döner.
    static func setMapping(_ pairs: Set<ModifierPair>, for keyboard: Keyboard) {
        let key = ModifierPreset.preferenceKey(vendor: keyboard.vendor, product: keyboard.product) as CFString
        let value: CFPropertyList? = pairs.isEmpty ? nil : pairs.sorted { $0.source < $1.source }.map {
            ["HIDKeyboardModifierMappingSrc": NSNumber(value: $0.source), "HIDKeyboardModifierMappingDst": NSNumber(value: $0.destination)]
        } as CFArray
        CFPreferencesSetValue(key, value, host.0, host.1, host.2)
        CFPreferencesSynchronize(host.0, host.1, host.2)
        apply(pairs, to: keyboard)
    }

    /// Yalnızca klavye servisine uygular, macOS'un ayarına dokunmaz (Windows App öndeyken geçici).
    @discardableResult
    static func apply(_ pairs: Set<ModifierPair>, to keyboard: Keyboard) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        let matching = keyboard.builtIn
            ? "{\"Built-In\":true,\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}"
            : ModifierPreset.matchingJSON(vendor: keyboard.vendor, product: keyboard.product)
        let properties = keyboard.builtIn ? ModifierPreset.propertyJSON(pairs) : ModifierPreset.externalPropertyJSON(pairs)
        process.arguments = ["property", "--matching", matching, "--set", properties]
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
}

/// Harici klavyelerin eşlemesini tutar: Berth açılınca, klavye (yeniden) bağlanınca ve uyanışta
/// uygular (yeni servis eşlemesiz gelir). İsteğe bağlı olarak Windows App öndeyken eşlemeyi kaldırır:
/// Windows klavyesi karşıya kendi diziliminde gider (Ctrl yine Ctrl), Windows App arkaya geçince
/// eşleme geri gelir. Dahili klavyeye dokunulmaz. Niteleme tuşu basılıyken eşleme değiştirilmez
/// (tuş takılı kalmasın); bırakılınca yapılır.
@MainActor
final class RemoteKeyboardMapping {
    private static let windowsAppID = "com.microsoft.rdc.macos"

    private var enabled = false
    private var lifted: [KeyboardModifiers.Keyboard] = []
    private var observers: [NSObjectProtocol] = []
    private var retry: Timer?
    private var notificationPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0

    init() {
        installObservers()
        reapply()
    }

    func configure(enabled: Bool) {
        self.enabled = enabled
        update()
    }

    /// Berth kapanırken: kaldırılan eşlemeler geri gelir.
    func shutdown() {
        enabled = false
        retry?.invalidate()
        restore()
        removeObservers()
    }

    private func update() {
        retry?.invalidate()
        retry = nil
        if NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty == false {
            retry = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            return
        }
        let remoteInFront = enabled && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.windowsAppID
        if remoteInFront, lifted.isEmpty {
            lifted = KeyboardModifiers.connected().filter { !$0.builtIn && !KeyboardModifiers.mapping(for: $0).isEmpty }
            for keyboard in lifted { KeyboardModifiers.apply([], to: keyboard) }
            if !lifted.isEmpty { DockTrace.log("klavye eslemesi kaldirildi: \(lifted.map(\.name))") }
        } else if !remoteInFront {
            restore()
        }
    }

    private func restore() {
        for keyboard in lifted { KeyboardModifiers.apply(KeyboardModifiers.mapping(for: keyboard), to: keyboard) }
        if !lifted.isEmpty { DockTrace.log("klavye eslemesi geri geldi: \(lifted.map(\.name))") }
        lifted = []
    }

    /// Bağlı harici klavyelerin hepsine kayıtlı eşlemesi (ya da Windows App öndeyse boş eşleme).
    private func reapply() {
        lifted = []
        for keyboard in KeyboardModifiers.connected() where !keyboard.builtIn {
            let pairs = KeyboardModifiers.mapping(for: keyboard)
            if !pairs.isEmpty { KeyboardModifiers.apply(pairs, to: keyboard) }
        }
        update()
    }

    /// Olay servisi cihazdan biraz sonra hazır oluyor; iki kez denenir.
    private func reapplySoon() {
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.reapply() }
            }
        }
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplySoon() }
        })
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Keyboard
        let callback: IOServiceMatchingCallback = { context, iterator in
            var any = false
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service); any = true }
            guard any, let context else { return }
            let mapping = Unmanaged<RemoteKeyboardMapping>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { mapping.reapplySoon() }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, callback,
                                         Unmanaged.passUnretained(self).toOpaque(), &matchIterator)
        while case let service = IOIteratorNext(matchIterator), service != 0 { IOObjectRelease(service) }
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if matchIterator != 0 { IOObjectRelease(matchIterator); matchIterator = 0 }
        if let port = notificationPort { IONotificationPortDestroy(port); notificationPort = nil }
    }
}
