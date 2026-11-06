import AppKit
import BerthCore

/// Kaydedilmiş çalışma düzenleri. UserDefaults'ta JSON olarak durur.
@MainActor
final class WorkspaceLayoutStore: ObservableObject {
    private static let key = "workspaceLayouts"
    @Published private(set) var layouts: [WorkspaceLayout]
    /// Kısayollar değişti: yeniden kaydedilmeli.
    var onChange: (() -> Void)?

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        layouts = data.flatMap { try? JSONDecoder().decode([WorkspaceLayout].self, from: $0) } ?? []
    }

    func save(_ layout: WorkspaceLayout) {
        // Aynı adla kayıt, eskisinin yerini alır; kısayolu korunur.
        if let index = layouts.firstIndex(where: { $0.name == layout.name }) {
            var replaced = layout
            replaced.hotKey = layouts[index].hotKey
            layouts[index] = replaced
        } else {
            layouts.append(layout)
        }
        persist()
    }

    func remove(named name: String) {
        layouts.removeAll { $0.name == name }
        persist()
    }

    /// Ad boşsa ya da başka düzende varsa değişmez.
    @discardableResult
    func rename(_ name: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !layouts.contains(where: { $0.name == trimmed }),
              let index = layouts.firstIndex(where: { $0.name == name }) else { return false }
        layouts[index].name = trimmed
        persist()
        return true
    }

    func setHotKey(_ hotKey: WorkspaceLayout.HotKey?, for name: String) {
        guard let index = layouts.firstIndex(where: { $0.name == name }) else { return }
        layouts[index].hotKey = hotKey
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(layouts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        onChange?()
    }
}

extension AppController {
    /// Bu alanlardaki görünen ve küçültülmüş pencereler kaydedilir. Başka alandaki ve tam ekran
    /// pencereler alınmaz: macOS pencereyi alana taşımaya izin vermediği için geri de konamazlar.
    func captureLayout(named name: String) -> WorkspaceLayout {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let snapshot = SceneSource.snapshot(for: screen, pinned: [])
        let windows = snapshot.allWindows
            .filter { $0.state == .visible || $0.state == .minimized }
            .sorted { $0.zRank > $1.zRank } // Arkadan öne: geri yüklerken en öndeki en son öne gelir.
            .map { WorkspaceLayout.Window(appID: $0.appID, title: $0.title, frame: $0.frame, minimized: $0.state == .minimized, windowID: $0.id) }
        return WorkspaceLayout(name: name, savedAt: Date(), windows: windows)
    }

    /// Kapalı uygulamalar açılır, pencereleri gelene kadar (en çok ~8 sn) beklenir; sonra eşleşen
    /// pencereler kaydedildiği yere taşınır.
    func restoreLayout(_ layout: WorkspaceLayout) async {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let missing = layout.appIDs.filter { !running.contains($0) }
        var launched = 0
        for id in missing {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            if (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil { launched += 1 }
        }
        if launched > 0 {
            Toast.show(tx("\(layout.name): \(launched) uygulama açılıyor…", "\(layout.name): opening \(launched) apps…"))
            let wanted = Set(missing)
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let snapshot = SceneSource.snapshot(for: NSScreen.main ?? NSScreen.screens[0], pinned: [])
                let ready = Set(snapshot.allWindows.filter { $0.state == .visible }.map(\.appID))
                if wanted.isSubset(of: ready) { break }
            }
        }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let snapshot = SceneSource.snapshot(for: screen, pinned: [])
        let reachable = snapshot.allWindows.filter { $0.state == .visible || $0.state == .minimized }
        let pairs = LayoutMatcher.match(
            saved: layout.windows,
            current: reachable.map { .init(appID: $0.appID, title: $0.title, windowID: $0.id) }
        )
        var moved = 0
        for (savedIndex, currentIndex) in pairs {
            let target = layout.windows[savedIndex], window = reachable[currentIndex]
            do {
                try await WindowActivator.placeWindow(
                    pid: window.pid, title: window.title, frame: window.frame, order: window.appIndex, to: target.frame
                )
                if target.minimized {
                    try await WindowActivator.minimizeWindow(
                        pid: window.pid, title: window.title, frame: target.frame, order: window.appIndex
                    )
                }
                moved += 1
            } catch {
                DockTrace.log("duzen: \(window.title) yerlestirilemedi: \(error)")
            }
        }
        let missingWindows = layout.windows.count - moved
        Toast.show(missingWindows == 0
            ? tx("\(layout.name) yüklendi.", "\(layout.name) restored.")
            : tx("\(layout.name) yüklendi; \(missingWindows) pencere bulunamadı ya da taşınamadı.", "\(layout.name) restored; \(missingWindows) windows couldn't be found or moved."))
    }

    func saveCurrentLayout(store: WorkspaceLayoutStore, name: String? = nil) {
        let layout = captureLayout(named: name ?? LayoutMatcher.nextName(existing: store.layouts.map(\.name)))
        store.save(layout)
        Toast.show(tx("\(layout.name) kaydedildi: \(layout.windows.count) pencere.", "\(layout.name) saved: \(layout.windows.count) windows."))
    }

    func askAndSaveLayout(store: WorkspaceLayoutStore) {
        let alert = NSAlert()
        alert.messageText = tx("Çalışma düzenini kaydet", "Save Workspace Layout")
        alert.informativeText = tx("Bu alanlardaki pencerelerin yeri ve boyutu kaydedilir. Aynı adla kayıt eskisinin yerini alır.", "Saves the position and size of windows in these spaces. Saving with the same name replaces the old one.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = LayoutMatcher.nextName(existing: store.layouts.map(\.name))
        alert.accessoryView = field
        alert.addButton(withTitle: tx("Kaydet", "Save"))
        alert.addButton(withTitle: tx("Vazgeç", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        saveCurrentLayout(store: store, name: name)
    }
}
