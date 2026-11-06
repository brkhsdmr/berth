import AppKit
import BerthCore

/// Bilgisayardaki uygulamalar: sahnede arama, açık olmayan uygulamaları da bulsun diye.
///
/// Klasörler sahne her açıldığında arka planda yeniden taranır (birkaç yüz paket, milisaniyeler);
/// arama o ana kadarki listeyi kullanır.
final class InstalledApps: @unchecked Sendable {
    struct App: Equatable {
        var name: String
        var url: URL
        var bundleID: String?
    }

    static let shared = InstalledApps()

    private let lock = NSLock()
    private var apps: [App] = []
    private var scanning = false

    func refresh() {
        lock.lock()
        guard !scanning else { lock.unlock(); return }
        scanning = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let found = Self.scan()
            lock.lock()
            apps = found
            scanning = false
            lock.unlock()
        }
    }

    /// Adı aramaya uyan uygulamalar, en iyi eşleşme önce. `excluding`: zaten sahnede olanlar.
    func matching(_ query: String, excluding: Set<String>, limit: Int) -> [App] {
        lock.lock()
        let all = apps
        lock.unlock()
        var ranked: [(app: App, rank: Int)] = []
        for app in all {
            if let id = app.bundleID, excluding.contains(id) { continue }
            if let rank = SearchMatcher.rank(query: query, name: app.name) { ranked.append((app, rank)) }
        }
        ranked.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.app.name.localizedCaseInsensitiveCompare(b.app.name) == .orderedAscending
        }
        return ranked.prefix(limit).map { $0.app }
    }

    /// Uygulamanın adı Berth'in dilinde: önce InfoPlist.loctable (macOS'un kendi uygulamaları),
    /// sonra dil klasöründeki InfoPlist.strings. Çeviri yoksa nil.
    private static func localizedName(_ bundle: Bundle) -> String? {
        let wanted = L10n.english ? "en" : "tr"
        guard let language = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [wanted]).first else { return nil }
        func pick(_ table: [String: Any]?) -> String? {
            (table?["CFBundleDisplayName"] as? String) ?? (table?["CFBundleName"] as? String)
        }
        if let path = bundle.path(forResource: "InfoPlist", ofType: "loctable"),
           let all = NSDictionary(contentsOfFile: path) as? [String: Any],
           let name = pick(all[language] as? [String: Any]) {
            return name
        }
        if let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: language),
           let name = pick(NSDictionary(contentsOfFile: path) as? [String: Any]) {
            return name
        }
        return nil
    }

    private static func scan() -> [App] {
        let manager = FileManager.default
        let roots = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        var seen = Set<String>()
        var result: [App] = []
        func add(_ url: URL) {
            let bundle = Bundle(url: url)
            let id = bundle?.bundleIdentifier
            guard seen.insert(id ?? url.path).inserted else { return }
            // Ad uygulamanın kendi çeviri tablosundan, Berth'in diliyle: Finder'ın adı sistem
            // dilinde kalıyor, Berth'in dili farklıysa ızgarada iki dil karışıyordu.
            let base = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String) ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            // İngilizce çoğu zaman tabloda değil, uygulamanın temel adıdır (Calculator).
            var name = bundle.flatMap(Self.localizedName)
                ?? (L10n.english ? base : nil)
                ?? manager.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            result.append(App(name: name, url: url, bundleID: id))
        }
        var folders = roots
        #if DEBUG
        // Demo modunda (ekran görüntüsü) yalnızca macOS'un kendi uygulamaları.
        if DemoMode.apps != nil { folders = ["/System/Applications", "/System/Applications/Utilities"] }
        #endif
        for root in folders {
            guard let items = try? manager.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let inner = try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    // Bir alt klasör: "Microsoft Office" gibi paket grupları.
                    for app in inner where app.pathExtension == "app" { add(app) }
                }
            }
        }
        return result
    }
}
