import AppKit
import BerthCore

/// Uygulamanın eski adı "Workspace Navigator 2" idi. Berth ilk açıldığında ayarlar, sabit
/// uygulamalar ve çalışma düzenleri eski tercihlerden kopyalanır; eskiler silinmez.
private func migrateFromWorkspaceNavigator() {
    let defaults = UserDefaults.standard
    let marker = "migratedFromWorkspaceNavigator"
    guard !defaults.bool(forKey: marker) else { return }
    defaults.set(true, forKey: marker)
    guard defaults.object(forKey: "arrangement") == nil,
          let old = defaults.persistentDomain(forName: "com.bh.workspacenavigator.v2"), !old.isEmpty
    else { return }
    for (key, value) in old { defaults.set(value, forKey: key) }
    // Eski sürüm yalnızca Türkçeydi: onu kullananların dili değişmesin.
    if defaults.object(forKey: "language") == nil { defaults.set(L10n.Language.turkish.rawValue, forKey: "language") }
}

migrateFromWorkspaceNavigator()
L10n.english = L10n.resolve(L10n.Language(rawValue: UserDefaults.standard.integer(forKey: "language")) ?? .automatic)

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { application.run() }
}
