import AppKit

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
            Item(name: "Masaüstü bilgisi (SkyLight)",
                 feature: "Masaüstü şeridi, pencere etiketleri, alanlar arası geçiş", works: spaces),
            Item(name: "Ham trackpad dokunmaları (MultitouchSupport)",
                 feature: "3 / 4 parmak ayrımı; çalışmazsa hareket her parmak sayısında yakalanır", works: touches),
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
        Toast.show("Bu macOS sürümünde çalışmayan özellik var: \(broken.map(\.name).joined(separator: ", ")). Ayrıntı: Ayarlar > İzinler.")
    }
}
