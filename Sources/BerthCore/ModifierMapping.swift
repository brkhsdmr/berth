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

    /// Harici klavyeler için: eşleme `UserKeyMapping` olarak yazılır, macOS'un çifti boşaltılır.
    /// Bluetooth LE klavyeler (DriverKit sürücüsü) `HIDKeyboardModifierMappingPairs`'i yok sayıyor,
    /// `UserKeyMapping`'i uyguluyor (Designer Compact Keyboard ile denendi, macOS 27.2). İkisi
    /// birden doluysa üst üste binebilir; biri hep boş.
    public static func externalPropertyJSON(_ pairs: Set<ModifierPair>) -> String {
        let items = pairs.sorted { $0.source < $1.source }.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        return "{\"HIDKeyboardModifierMappingPairs\":[],\"UserKeyMapping\":[\(items.joined(separator: ","))]}"
    }

    public static func matchingJSON(vendor: Int, product: Int) -> String {
        "{\"VendorID\":\(vendor),\"ProductID\":\(product),\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}"
    }
}
