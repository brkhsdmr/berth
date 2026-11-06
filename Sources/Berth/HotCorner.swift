import AppKit
import BerthCore

/// İmleç seçilen ekran köşesine gelince sahneyi açar ya da kapatır (macOS'un Sıcak Köşeleri gibi).
///
/// Fare hareketi izlenir; izin gerekmez. Köşeden çıkmadan ikinci kez tetiklenmez, fare düğmesi
/// basılıyken (pencere sürüklerken) tetiklenmez.
@MainActor
final class HotCornerMonitor {
    var onTrigger: (() -> Void)?

    private var corner = ScreenCorner.none
    private var delay: TimeInterval = 0
    private var monitors: [Any] = []
    private var inside = false
    private var pending: DispatchWorkItem?

    func configure(corner: ScreenCorner, delay: TimeInterval) {
        self.corner = corner
        self.delay = delay
        if corner == .none { stop() } else { start() }
    }

    private func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.check() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pending?.cancel()
        pending = nil
        inside = false
    }

    private func check() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame.insetBy(dx: -1, dy: -1), false) }
        let now = screen.map { ScreenCorner.corner(of: point, in: $0.frame) } == corner

        guard now != inside else { return }
        inside = now
        pending?.cancel()
        pending = nil
        guard now, NSEvent.pressedMouseButtons == 0 else { return }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.inside, NSEvent.pressedMouseButtons == 0 else { return }
                self.onTrigger?()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// macOS'un aynı köşeye atadığı eylem; yoksa nil. Değiştirici tuşla atanmışsa da bildirilir.
    static func systemAction(at corner: ScreenCorner) -> String? {
        guard let key = corner.dockKey,
              let value = CFPreferencesCopyAppValue("wvous-\(key)-corner" as CFString, "com.apple.dock" as CFString) as? Int,
              value > 1
        else { return nil }
        let names: [Int: String] = [
            2: "Mission Control", 3: tx("Uygulama Pencereleri", "Application Windows"), 4: tx("Masaüstü", "Desktop"), 5: tx("Ekran Koruyucuyu Başlat", "Start Screen Saver"),
            6: tx("Ekran Koruyucuyu Kapat", "Disable Screen Saver"), 10: tx("Ekranı Uyut", "Put Display to Sleep"), 11: "Launchpad", 12: tx("Bildirim Merkezi", "Notification Center"),
            13: tx("Ekranı Kilitle", "Lock Screen"), 14: tx("Hızlı Not", "Quick Note"),
        ]
        let name = names[value] ?? tx("bir eylem", "an action")
        let modifier = CFPreferencesCopyAppValue("wvous-\(key)-modifier" as CFString, "com.apple.dock" as CFString) as? Int ?? 0
        return modifier == 0 ? name : tx("\(name) (tuşla)", "\(name) (with a key)")
    }
}
