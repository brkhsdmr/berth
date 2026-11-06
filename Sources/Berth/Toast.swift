import AppKit

/// Kaplama kapandıktan sonra oluşan hatayı gösteren küçük bildirim.
/// Sessiz başarısızlık olmasın: kullanıcı yasladığı pencerenin neden gitmediğini bilmeli.
extension NSWindow {
    /// Pencereyi bulunulan alanda öne alır.
    ///
    /// Ölçüldü: tüm alanlara katılması gereken paneller zamanla yalnızca birkaç alana bağlı kalıyor
    /// ve sonradan açılan tam ekran alanlarında görünmüyor; öne alınsalar da masaüstünde beliriyorlar.
    /// Alan katılım ayarı yeniden uygulanınca pencere bulunulan alana katılıyor.
    @MainActor
    func orderFrontOnActiveSpace() {
        orderFrontRegardless()
        guard SkyLight.isWindowInAnyCurrentSpace(CGWindowID(windowNumber)) == false else { return }
        let behavior = collectionBehavior
        orderOut(nil)
        collectionBehavior = []
        collectionBehavior = behavior
        orderFrontRegardless()
        guard SkyLight.isWindowInAnyCurrentSpace(CGWindowID(windowNumber)) == false else { return }
        // Windows App'in tam ekran alanında öne almak yetmiyor (ölçüldü): alana doğrudan eklenir.
        SkyLight.addToCurrentSpaces(CGWindowID(windowNumber))
        orderFrontRegardless()
        if SkyLight.isWindowInAnyCurrentSpace(CGWindowID(windowNumber)) == false {
            DockTrace.log("pencere bu alana katilamadi: \(windowNumber) (dogrudan ekleme de olmadi)")
        } else {
            DockTrace.log("pencere alana dogrudan eklendi: \(windowNumber)")
        }
    }
}

@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 420
        let fitted = label.fittingSize
        let size = CGSize(width: fitted.width + 36, height: fitted.height + 24)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.minY + 60, width: size.width, height: size.height)

        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        label.frame = CGRect(x: 18, y: 12, width: fitted.width, height: fitted.height)
        background.addSubview(label)
        window.contentView = background
        window.orderFrontRegardless()
        panel = window

        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
            panel = nil
        }
    }
}
