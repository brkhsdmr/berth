import Foundation

/// Arayüz dili: Türkçe ya da İngilizce. Metinler kullanıldıkları yerde iki dilde yazılır, `tx`.
///
/// Dil açılışta bir kez seçilir (`Settings` > Genel > Dil, yeniden başlatınca geçerli): ayarlanmamışsa
/// macOS'un ilk tercih edilen dili Türkçe ise Türkçe, değilse İngilizce. `BERTH_LANGUAGE` ortam
/// değişkeni ("tr" / "en") sınamalar için seçimi zorlar.
public enum L10n {
    public enum Language: Int, Sendable { case automatic = 0, turkish = 1, english = 2 }

    nonisolated(unsafe) public static var english: Bool = resolve(.automatic)

    public static func resolve(_ choice: Language) -> Bool {
        switch ProcessInfo.processInfo.environment["BERTH_LANGUAGE"] {
        case "tr": return false
        case "en": return true
        default: break
        }
        switch choice {
        case .turkish: return false
        case .english: return true
        case .automatic: return !(Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("tr")
        }
    }
}

/// Türkçe ya da İngilizce karşılığı.
@inline(__always)
public func tx(_ turkish: String, _ english: String) -> String {
    L10n.english ? english : turkish
}
