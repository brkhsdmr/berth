/// macOS'un klavye başına niteleme tuşu eşlemesi (Sistem Ayarları > Klavye > Niteleme Tuşları).
///
/// macOS bunu bu bilgisayara özel genel alanda `com.apple.keyboard.modifiermapping.<üretici>-<ürün>-0`
/// anahtarında `HIDKeyboardModifierMappingSrc` / `…Dst` çiftleri olarak tutar; değerler HID kullanım
/// sayfası << 32 | kullanım. Dahili klavye 0-0'dır.
public struct ModifierPair: Hashable, Sendable {
    public var source: Int64
    public var destination: Int64
    public init(_ source: Int64, _ destination: Int64) {
        self.source = source
        self.destination = destination
    }
}

public enum ModifierKey {
    public static let leftControl: Int64 = 0x7_0000_00E0
    public static let leftShift: Int64 = 0x7_0000_00E1
    public static let leftOption: Int64 = 0x7_0000_00E2
    public static let leftCommand: Int64 = 0x7_0000_00E3
    public static let rightControl: Int64 = 0x7_0000_00E4
    public static let rightOption: Int64 = 0x7_0000_00E6
    public static let rightCommand: Int64 = 0x7_0000_00E7
    /// Eski fn ve Apple klavyelerindeki Dünya tuşu; macOS ikisini birlikte eşler.
    public static let function: Int64 = 0xFF_0000_0003
    public static let globe: Int64 = 0xFF01_0000_0003
}

public enum ModifierPreset {
    /// Mac klavyesinde Windows'a yakın: Kontrol → Dünya, Komut → Kontrol, Dünya → Komut. Boşluğun
    /// yanındaki tuş Ctrl olur (kopyala, yapıştır Windows'taki parmakla), en soldaki ⌘.
    /// Sistem Ayarları'nın bu seçimde yazdığı çiftler.
    public static let macWindowsLike: Set<ModifierPair> = [
        ModifierPair(ModifierKey.leftCommand, ModifierKey.leftControl),
        ModifierPair(ModifierKey.rightCommand, ModifierKey.rightControl),
        ModifierPair(ModifierKey.leftControl, ModifierKey.function),
        ModifierPair(ModifierKey.rightControl, ModifierKey.function),
        ModifierPair(ModifierKey.function, ModifierKey.rightCommand),
        ModifierPair(ModifierKey.globe, ModifierKey.leftCommand),
    ]

    /// Windows klavyesinde Mac dizilimi (alt sıra Windows'taki gibi çalışır): Ctrl → ⌘,
    /// Windows → ⌥, Alt → ⌃. Windows tuşu macOS'a ⌘, Alt ⌥ olarak gelir.
    public static let windowsKeyboard: Set<ModifierPair> = [
        ModifierPair(ModifierKey.leftControl, ModifierKey.leftCommand),
        ModifierPair(ModifierKey.rightControl, ModifierKey.rightCommand),
        ModifierPair(ModifierKey.leftCommand, ModifierKey.leftOption),
        ModifierPair(ModifierKey.rightCommand, ModifierKey.rightOption),
        ModifierPair(ModifierKey.leftOption, ModifierKey.leftControl),
        ModifierPair(ModifierKey.rightOption, ModifierKey.rightControl),
    ]

    /// Kendine eşlenen tuşlar (Sistem Ayarları bunları da yazar) eşleme sayılmaz.
    public static func effective(_ pairs: [ModifierPair]) -> Set<ModifierPair> {
        Set(pairs.filter { $0.source != $0.destination })
    }

    public static func preferenceKey(vendor: Int, product: Int) -> String {
        "com.apple.keyboard.modifiermapping.\(vendor)-\(product)-0"
    }

    /// `hidutil property --set` için.
    public static func propertyJSON(_ pairs: Set<ModifierPair>) -> String {
        let items = pairs.sorted { $0.source < $1.source }.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        return "{\"HIDKeyboardModifierMappingPairs\":[\(items.joined(separator: ","))]}"
    }

    /// Harici klavyeler için `hidutil property --set` değeri: yalnızca `UserKeyMapping`.
    /// Bluetooth LE klavyeler (DriverKit sürücüsü) `HIDKeyboardModifierMappingPairs` yazımını yok
    /// sayıyor; macOS kendi ayarını onlara yalnızca bağlanma anında uyguluyor. Bu yüzden çifte
    /// dokunulmaz, eksik kalan fark `userKeyMapping(desired:active:)` ile hesaplanır.
    public static func externalPropertyJSON(_ pairs: Set<ModifierPair>) -> String {
        let items = pairs.sorted { $0.source < $1.source }.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        return "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"
    }

    /// macOS'un klavyede zaten uyguladığı eşlemenin (`active`) üstüne yazılacak `UserKeyMapping`;
    /// ikisi birlikte `desired` sonucunu verir. macOS bağlanırken kendi ayarını uyguladıysa ve ayar
    /// değişmediyse boş; Windows App öndeyken (`desired` boş) macOS'un eşlemesinin tersi. İkisi üst
    /// üste binerse (Ctrl → ⌘ → ⌥) tuşlar karışıyordu (Designer Compact Keyboard, macOS 27.2).
    public static func userKeyMapping(desired: Set<ModifierPair>, active: Set<ModifierPair>) -> Set<ModifierPair> {
        let want = Dictionary(desired.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first })
        let have = Dictionary(active.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first })
        var result: [Int64: Int64] = [:]
        for key in Set(want.keys).union(have.keys).sorted() {
            let middle = have[key] ?? key
            let target = want[key] ?? key
            guard middle != target, result[middle] == nil else { continue }
            result[middle] = target
        }
        return Set(result.map { ModifierPair($0.key, $0.value) })
    }

    public static func matchingJSON(vendor: Int, product: Int) -> String {
        "{\"VendorID\":\(vendor),\"ProductID\":\(product),\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}"
    }
}
