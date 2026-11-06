import AppKit
import BerthCore
import QuartzCore

/// Tam ekranda Dock'un yerine açılan şerit.
///
/// macOS tam ekranda Dock'u her zaman açmıyor (ölçüldü: imleç kenardayken saniyelerce
/// açılmadı) ve Dock'u programla açmanın bilinen bir yolu yok. Şerit, Dock'un listesini
/// Erişilebilirlik'ten okur (Dock gizliyken de okunuyor), aynı sırayla gösterir. Üstüne
/// gelince aynı pencere önizlemesi açılır. Asıl Dock yine açılırsa şerit devreye girmez.
@MainActor
final class FullScreenDockController {
    var entries: (() -> [DockWatcher.Entry])?
    var liveDockFrame: (() -> CGRect?)?
    /// Kaplama açıkken ya da alan yerleştirilirken şerit açılmaz.
    var isBlocked: (() -> Bool)?
    var onHover: ((DockWatcher.Item?) -> Void)?
    var onChoose: ((DockWatcher.Entry) -> Void)?
    /// İmleç önizleme panelindeyse şerit açık kalır.
    var isMouseInPreview: (() -> Bool)?

    private let panel: NSPanel
    private let view = DockStripView(frame: .zero)
    private var monitor: Any?
    private var pendingShow: Task<Void, Never>?
    private var leaveTimer: Timer?
    private var outsideSince: Date?

    private static let touchDelay: UInt64 = 120_000_000
    private static let leaveGrace: TimeInterval = 0.35

    var frame: CGRect? { panel.isVisible ? panel.frame : nil }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Önizleme paneliyle aynı seviye, sonra açılan önizleme üstte kalır.
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .auxiliary, .canJoinAllApplications]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        panel.contentView = background

        view.onHover = { [weak self] item in self?.onHover?(item) }
        view.onChoose = { [weak self] entry in
            self?.hide()
            self?.onChoose?(entry)
        }
    }

    // MARK: Kenar izleme

    /// Boşta iş yapmaz: yalnızca fare hareket edince tek bir karşılaştırma.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingShow?.cancel()
        hide()
    }

    private func mouseMoved() {
        guard !panel.isVisible, pendingShow == nil else { return }
        guard touchedScreen() != nil else { return }

        // İmleç kenara dayanınca olay gelmeyebilir; kısa bekleyip konuma yeniden bakılır.
        pendingShow = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.touchDelay)
            guard let self else { return }
            self.pendingShow = nil
            guard !Task.isCancelled, let screen = self.touchedScreen() else { return }
            self.showIfNeeded(on: screen)
        }
    }

    #if DEBUG
    /// Yalnızca sınama için: tam ekran koşulu olmadan açar.
    func showForTesting() {
        guard let screen = NSScreen.screens.first, let list = entries?(), !list.isEmpty else { return }
        show(list, on: screen)
    }
    #endif

    private func edge() -> DockEdge {
        DockEdge(orientation: UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation"))
    }

    private func touchedScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              edge().isTouched(by: mouse, screen: screen.frame)
        else { return nil }
        return screen
    }

    private func showIfNeeded(on screen: NSScreen) {
        guard isBlocked?() != true, SceneSource.currentSpaceIsFullScreen(on: screen) else { return }

        // Asıl Dock açıldıysa ona karışma.
        let bounds = CGDisplayBounds(screen.displayID)
        if let dock = liveDockFrame?(), bounds.intersection(dock).width > 10, bounds.intersection(dock).height > 10,
           bounds.contains(CGPoint(x: dock.midX, y: dock.midY)) {
            DockTrace.log("serit: asil Dock acik \(dock)")
            return
        }
        guard let list = entries?(), !list.isEmpty else {
            DockTrace.log("serit: Dock listesi okunamadi")
            return
        }
        show(list, on: screen)
    }

    // MARK: Gösterme

    private func show(_ list: [DockWatcher.Entry], on screen: NSScreen) {
        let edge = edge()
        let saved = UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "tilesize") as? CGFloat ?? 48
        let available = (edge.isVertical ? screen.frame.height : screen.frame.width) - 40
        let separators = CGFloat(list.filter(\.separatorBefore).count)
        let padding: CGFloat = 8
        let spacing: CGFloat = 5
        let needed = CGFloat(list.count) * (saved + spacing) + separators * 13 + 2 * padding
        let iconSize = needed > available ? max(24, saved * available / needed) : saved

        let length = CGFloat(list.count) * (iconSize + spacing) + separators * 13 + 2 * padding
        let thickness = iconSize + 2 * padding
        let target = edge.stripFrame(length: length, thickness: thickness, screen: screen.frame)

        // Boş kareyle başlayan görünüm kendiliğinden büyümüyor; boyutu burada verilmezse fare olayları ulaşmaz.
        panel.contentView?.frame = CGRect(origin: .zero, size: target.size)
        view.frame = CGRect(origin: .zero, size: target.size)
        view.configure(list, iconSize: iconSize, spacing: spacing, padding: padding, vertical: edge.isVertical,
                       scale: screen.backingScaleFactor, primaryHeight: NSScreen.screens.first?.frame.height ?? screen.frame.height)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(reduceMotion ? target : edge.hiddenFrame(from: target, screen: screen.frame), display: false)
        panel.alphaValue = reduceMotion ? 0 : 1
        panel.orderFrontOnActiveSpace()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.28, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        DockTrace.log("serit acildi \(list.count) uygulama \(target)")

        outsideSince = nil
        leaveTimer?.invalidate()
        leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLeave() }
        }
    }

    func hide() {
        leaveTimer?.invalidate()
        leaveTimer = nil
        outsideSince = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        view.clear()
        onHover?(nil)
    }

    private func checkLeave() {
        let inside = panel.frame.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation)
        if inside || isMouseInPreview?() == true {
            outsideSince = nil
            return
        }
        guard let since = outsideSince else {
            outsideSince = Date()
            return
        }
        if Date().timeIntervalSince(since) >= Self.leaveGrace { hide() }
    }
}

/// Şeridin içi: Dock sırasıyla simgeler, ayraçlar ve çalışma noktaları.
final class DockStripView: NSView {
    var onHover: ((DockWatcher.Item?) -> Void)?
    var onChoose: ((DockWatcher.Entry) -> Void)?

    private struct Icon {
        var entry: DockWatcher.Entry
        var frame: CGRect
        var layer: CALayer
    }

    private var icons: [Icon] = []
    private var hovered: Int?
    private var pressed: Int?
    private var primaryHeight: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func clear() {
        icons = []
        hovered = nil
        pressed = nil
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    func configure(_ list: [DockWatcher.Entry], iconSize: CGFloat, spacing: CGFloat, padding: CGFloat, vertical: Bool, scale: CGFloat, primaryHeight: CGFloat) {
        clear()
        self.primaryHeight = primaryHeight

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var cursor = padding
        for entry in list {
            if entry.separatorBefore {
                let line = CALayer()
                line.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.25).cgColor
                line.frame = vertical
                    ? CGRect(x: padding + 4, y: cursor + 5, width: iconSize - 8, height: 1)
                    : CGRect(x: cursor + 5, y: padding + 4, width: 1, height: iconSize - 8)
                layer?.addSublayer(line)
                cursor += 13
            }
            let rect = vertical
                ? CGRect(x: padding, y: cursor, width: iconSize, height: iconSize)
                : CGRect(x: cursor, y: padding, width: iconSize, height: iconSize)

            let icon = CALayer()
            icon.frame = rect
            icon.contentsGravity = .resizeAspect
            var imageRect = CGRect(x: 0, y: 0, width: iconSize * scale, height: iconSize * scale)
            icon.contents = entry.icon.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)
            layer?.addSublayer(icon)

            if entry.isRunning {
                let dot = CALayer()
                dot.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.85).cgColor
                dot.cornerRadius = 2
                dot.frame = vertical
                    ? CGRect(x: rect.maxX + 2, y: rect.midY - 2, width: 4, height: 4)
                    : CGRect(x: rect.midX - 2, y: rect.maxY + 2, width: 4, height: 4)
                layer?.addSublayer(dot)
            }
            icons.append(Icon(entry: entry, frame: rect, layer: icon))
            cursor += iconSize + spacing
        }
        CATransaction.commit()
    }

    private func index(at point: CGPoint) -> Int? {
        icons.firstIndex { $0.frame.insetBy(dx: -3, dy: -3).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ next: Int?) {
        guard next != hovered else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        if let hovered, icons.indices.contains(hovered) { icons[hovered].layer.transform = CATransform3DIdentity }
        if let next { icons[next].layer.transform = CATransform3DMakeScale(1.14, 1.14, 1) }
        CATransaction.commit()
        hovered = next

        guard let next, let window else {
            onHover?(nil)
            return
        }
        // Önizleme simgenin yanına oturur; kare CGWindowList uzayında verilir.
        let inWindow = convert(icons[next].frame, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let frame = CGRect(x: onScreen.minX, y: primaryHeight - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        let entry = icons[next].entry
        onHover?(DockWatcher.Item(title: entry.title, bundleID: entry.bundleID, frame: frame, isFixedFrame: true))
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let released = index(at: convert(event.locationInWindow, from: nil))
        defer { pressed = nil }
        guard let released, released == pressed else { return }
        onChoose?(icons[released].entry)
    }
}
