import CoreGraphics
import Foundation

/// macOS'un masaüstü (Space) bilgisini veren özel SkyLight işlevleri.
///
/// **Yalnızca okuma.** Belgelenmemiş API'nin tamamı bu dosyadadır. Semboller çalışma
/// anında aranır: bir macOS güncellemesi bunları kaldırırsa uygulama derlenmiş hâliyle
/// çalışmayı sürdürür, yalnızca masaüstü şeridi ve pencere etiketleri kaybolur.
enum SkyLight {
    struct ManagedSpace {
        var id: UInt64
        var isFullScreen: Bool
        var name: String
    }

    struct ManagedDisplay {
        var identifier: String
        var currentSpaceID: UInt64
        var spaces: [ManagedSpace]
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias AddWindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
    private typealias IsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias CaptureWindowList = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let connection: Int32? = symbol("SLSMainConnectionID", as: MainConnection.self)?()
    private static let copyDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: CopyDisplaySpaces.self)
    private static let copySpacesForWindows = symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)
    private static let captureWindowList = symbol("SLSHWCaptureWindowList", as: CaptureWindowList.self)
    private static let isOrderedIn = symbol("SLSWindowIsOrderedIn", as: IsOrderedIn.self)
    private static let addWindowsToSpaces = symbol("SLSAddWindowsToSpaces", as: AddWindowsToSpaces.self)

    static var isAvailable: Bool {
        connection != nil && copyDisplaySpaces != nil && copySpacesForWindows != nil
    }

    static func displays() -> [ManagedDisplay] {
        guard let connection, let copyDisplaySpaces,
              let raw = copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        return raw.map { display in
            let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID) ?? 0
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).map { space -> ManagedSpace in
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                let tiles = (space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]]
                let tileNames = (tiles ?? []).compactMap { $0["name"] as? String }
                return ManagedSpace(
                    id: spaceID(space) ?? 0,
                    isFullScreen: type != 0,
                    name: tileNames.isEmpty ? (space["name"] as? String ?? "") : tileNames.joined(separator: " | ")
                )
            }
            return ManagedDisplay(
                identifier: display["Display Identifier"] as? String ?? "",
                currentSpaceID: current,
                spaces: spaces
            )
        }
    }

    /// Pencerenin bağlı olduğu masaüstleri. Küçültülmüş ve hayalet pencerelerde boştur.
    static func spaces(forWindow id: CGWindowID) -> [UInt64] {
        guard let connection, let copySpacesForWindows else { return [] }
        let list = [NSNumber(value: id)] as CFArray
        // 7: geçerli, diğer ve kullanıcıya ait tüm masaüstleri.
        guard let raw = copySpacesForWindows(connection, 7, list)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return raw.map(\.uint64Value)
    }

    /// Kendi penceremizi şu an gösterilen alanlara ekler. Tüm alanlara katılan panel bazı tam ekran
    /// alanlara (Windows App) öne alınarak giremiyor (ölçüldü); bu doğrudan ekler. İşlevin dönüş
    /// değeri güvenilir değil (eklediği halde hata döndü): sonucu `spaces(forWindow:)` söyler.
    static func addToCurrentSpaces(_ id: CGWindowID) {
        guard let connection, let addWindowsToSpaces else { return }
        let current = displays().map { NSNumber(value: $0.currentSpaceID) }
        guard !current.isEmpty else { return }
        _ = addWindowsToSpaces(connection, [NSNumber(value: id)] as CFArray, current as CFArray)
    }

    /// Pencere ekrana dizili mi? Başka alandaki pencere de dizilidir; uygulamanın kapatıp
    /// sakladığı ve küçültülmüş pencere dizili değildir (macOS 26.2'de ölçüldü). Bilgi yoksa nil.
    static func isOrderedIn(_ id: CGWindowID) -> Bool? {
        guard let connection, let isOrderedIn else { return nil }
        var value: UInt8 = 0
        guard isOrderedIn(connection, id, &value) == 0 else { return nil }
        return value != 0
    }

    /// Pencereye ulaşmak için kaç alan kayılması gerektiği; artı sağa, eksi sola.
    /// Pencere şu anki ekranın alanlarında değilse nil.
    static func spaceOffset(toWindow id: CGWindowID) -> Int? {
        guard let target = spaces(forWindow: id).first else { return nil }
        for display in displays() {
            let order = display.spaces.map(\.id)
            guard let to = order.firstIndex(of: target),
                  let from = order.firstIndex(of: display.currentSpaceID)
            else { continue }
            return to - from
        }
        return nil
    }

    /// Pencere şu an gösterilen alanda mı? Masaüstü bilgisi yoksa nil.
    static func isWindowOnCurrentSpace(_ id: CGWindowID) -> Bool? {
        guard let target = spaces(forWindow: id).first else { return nil }
        return displays().contains { $0.currentSpaceID == target }
    }

    /// Pencere şu an gösterilen alanlardan birine bağlı mı? Tüm alanlara katılan pencere birden çok
    /// alana bağlı görünür. Bilgi yoksa nil.
    static func isWindowInAnyCurrentSpace(_ id: CGWindowID) -> Bool? {
        let joined = spaces(forWindow: id)
        guard !joined.isEmpty else { return nil }
        let current = Set(displays().map(\.currentSpaceID))
        return joined.contains { current.contains($0) }
    }

    /// Pencere görüntüsü, nokta çözünürlüğünde.
    ///
    /// macOS 26.2'de ölçüldü: ScreenCaptureKit başka alandaki tam ekran pencerede hata
    /// veriyor, bu işlev görüntüyü alıyor. Donanım video yüzeyleri (YouTube) beyaz çıkıyor;
    /// bu yüzden yalnızca yedek olarak kullanılır.
    static func captureWindow(_ id: CGWindowID) -> CGImage? {
        guard let connection, let captureWindowList else { return nil }
        var window = id
        // 1 << 11: pencere şekliyle kırpma; 1 << 9: nokta çözünürlüğü.
        let images = captureWindowList(connection, &window, 1, (1 << 11) | (1 << 9))?.takeRetainedValue() as? [CGImage]
        return images?.first
    }

    private static func spaceID(_ dictionary: [String: Any]) -> UInt64? {
        (dictionary["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }
}
