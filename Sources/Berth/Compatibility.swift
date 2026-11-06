import AppKit
import BerthCore

/// Belgelenmemiş sistem işlevlerinin bu macOS sürümünde hâlâ çalışıp çalışmadığı.
///
/// Uygulama birkaç özelliği macOS'un belgelenmemiş işlevlerine dayandırıyor; bir güncelleme
/// bunları kaldırabilir ya da değiştirebilir. Açılışta yalnızca okuyarak sınanır (hiçbir şey
/// değiştirilmez); bozulan varsa kullanıcıya bir kez, ayarlarda her zaman söylenir.
enum Compatibility {
    struct Item: Identifiable {
        var id: String { name }
        let name: String
        let feature: String
        let works: Bool
    }

    @MainActor
    static func check() -> [Item] {
        let spaces = SkyLight.isAvailable && !SkyLight.displays().isEmpty
        let touches = TrackpadTouches.isAvailable
        return [
            Item(name: tx("Masaüstü bilgisi (SkyLight)", "Desktop information (SkyLight)"),
                 feature: tx("Masaüstü şeridi, pencere etiketleri, alanlar arası geçiş", "Desktop strip, window labels, switching between spaces"), works: spaces),
            Item(name: tx("Ham trackpad dokunmaları (MultitouchSupport)", "Raw trackpad touches (MultitouchSupport)"),
                 feature: tx("3 / 4 parmak ayrımı; çalışmazsa hareket her parmak sayısında yakalanır", "Telling 3 from 4 fingers; without it the swipe is caught with any finger count"), works: touches),
        ]
    }

    /// Bozulan özellik varsa bu macOS sürümünde bir kez bildirir.
    @MainActor
    static func reportIfBroken() {
        let broken = check().filter { !$0.works }
        guard !broken.isEmpty else { return }
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let key = "compatibilityReported"
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        UserDefaults.standard.set(version, forKey: key)
        let names = broken.map(\.name).joined(separator: ", ")
        Toast.show(tx("Bu macOS sürümünde çalışmayan özellik var: \(names). Ayrıntı: Ayarlar > İzinler.",
                      "Some features don't work on this macOS version: \(names). Details: Settings > Permissions."))
    }
}
