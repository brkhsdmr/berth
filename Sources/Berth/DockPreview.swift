import AppKit
import BerthCore
import QuartzCore

/// Dock'un üstüne gelinen simgesini izler.
///
/// Yoklama yok: Dock seçili simge değişince Erişilebilirlik bildirimi gönderiyor (ölçüldü).
/// Boşta maliyet sıfır. Dock yeniden başlarsa gözlem yeniden kurulur.
@MainActor
final class DockWatcher {
    struct Item: Equatable {
        var title: String
        var bundleID: String?
        /// CGWindowList uzayında simgenin karesi.
        var frame: CGRect
        /// Tam ekran şeridinden geldi: kare kesin, Dock'tan yeniden okunmaz.
        var isFixedFrame = false
    }

    /// Dock'taki bir uygulama; tam ekran şeridi için.
    struct Entry {
        var title: String
        var bundleID: String?
        var url: URL?
        var icon: NSImage
        var isRunning: Bool
        var separatorBefore: Bool
    }

    var onChange: ((Item?) -> Void)?

    private var selected: AXUIElement?
    private var observer: AXObserver?
    private var list: AXUIElement?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var retryTask: Task<Void, Never>?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.dock" else { return }
                MainActor.assumeIsolated {
                    self?.detach()
                    self?.attachWithRetry()
                }
            })
        }
        attachWithRetry()
    }

    func stop() {
        isRunning = false
        retryTask?.cancel()
        retryTask = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers = []
        detach()
    }

    /// Erişilebilirlik izni sonradan verilmiş ya da Dock yeni başlamış olabilir: bağlanana kadar dener.
    private func attachWithRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, self.observer == nil, !Task.isCancelled {
                if !self.attach() {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    @discardableResult
    private func attach() -> Bool {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return false }

        let application = AXUIElementCreateApplication(dock.processIdentifier)
        guard let children = Self.attribute(application, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first(where: { Self.attribute($0, kAXRoleAttribute) as? String == kAXListRole })
        else { return false }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let watcher = Unmanaged<DockWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.selectionChanged() }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &created) == .success, let created else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, list, kAXSelectedChildrenChangedNotification as CFString, context) == .success
        else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        self.list = list
        return true
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        list = nil
        onChange?(nil)
    }

    /// Dock'un uygulamaları, Dock sırasıyla. Dock gizliyken de okunabiliyor (ölçüldü).
    /// Klasör, çöp ve küçültülmüş pencere öğeleri alınmaz: önizlemeleri yok.
    func applicationEntries() -> [Entry] {
        guard let list, let items = Self.attribute(list, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        var entries: [Entry] = []
        var pendingSeparator = false
        for item in items {
            let subrole = Self.attribute(item, kAXSubroleAttribute) as? String
            if subrole == "AXSeparatorDockItem" {
                pendingSeparator = !entries.isEmpty
                continue
            }
            guard subrole == "AXApplicationDockItem",
                  let title = Self.attribute(item, kAXTitleAttribute) as? String,
                  !title.isEmpty
            else { continue }
            let url = Self.attribute(item, kAXURLAttribute) as? URL
            entries.append(Entry(
                title: title,
                bundleID: url.flatMap { Bundle(url: $0)?.bundleIdentifier },
                url: url,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application),
                isRunning: (Self.attribute(item, "AXIsApplicationRunning") as? NSNumber)?.boolValue ?? false,
                separatorBefore: pendingSeparator
            ))
            pendingSeparator = false
        }
        return entries
    }

    /// Seçili simgenin şu anki karesi. Tam ekranda Dock kayarak açıldığı için bildirim
    /// anındaki kare ekranın dışında kalmış olabilir.
    func liveItemFrame() -> CGRect? {
        selected.flatMap(Self.frame)
    }

    /// Dock'un şu anki karesi; gizliyken ekranın dışındadır.
    func liveDockFrame() -> CGRect? {
        list.flatMap(Self.frame)
    }

    private func selectionChanged() {
        selected = nil
        guard let list,
              let selected = (Self.attribute(list, kAXSelectedChildrenAttribute) as? [AXUIElement])?.first,
              Self.attribute(selected, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              let frame = Self.frame(selected)
        else {
            onChange?(nil)
            return
        }
        self.selected = selected
        let title = Self.attribute(selected, kAXTitleAttribute) as? String ?? ""
        let url = Self.attribute(selected, kAXURLAttribute) as? URL
        onChange?(Item(title: title, bundleID: url.flatMap { Bundle(url: $0)?.bundleIdentifier }, frame: frame))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

/// Debug derlemede Dock önizlemesinin olay kaydı; gerçek fareyle oluşan sorunları görmek için.
/// Dosya: ~/Library/Logs/Berth/dock.log
enum DockTrace {
    static func log(_ line: @autoclosure () -> String) {
        #if DEBUG
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Berth")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("dock.log")
        let text = "\(Date().formatted(date: .omitted, time: .standard)) \(line())\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }
}

/// Önizleme başlığındaki uygulama düğmeleri: Dock'un sağ tık menüsünün karşılığı.
enum DockAppAction: Equatable {
    case hide, show, quit

    var label: String {
        switch self {
        case .hide: return tx("Gizle", "Hide")
        case .show: return tx("Göster", "Show")
        case .quit: return tx("Çık", "Quit")
        }
    }

    var symbolName: String {
        switch self {
        case .hide: return "eye.slash"
        case .show: return "eye"
        case .quit: return "power"
        }
    }

    var hoverColor: NSColor {
        self == .quit ? .systemRed : NSColor(calibratedWhite: 1, alpha: 0.2)
    }
}

/// Dock simgesinin yanında açılan, uygulamanın tüm masaüstlerindeki pencerelerini gösteren panel.
@MainActor
final class DockPreviewController {
    var onChoose: ((SceneWindow) -> Void)?
    var onClose: ((SceneWindow) -> Void)?
    var onAppAction: ((DockAppAction, SceneApp) -> Void)?

    private let thumbnails: ThumbnailStore
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let view: DockPreviewView

    private var currentItem: DockWatcher.Item?
    private var shownAppID: String?
    private var showTask: Task<Void, Never>?
    private var leaveTimer: Timer?
    private var outsideSince: Date?
    /// Sağ tıkla Dock menüsü açılan simge: menü panelin altında kalmasın diye önizleme bu simgede
    /// gösterilmez. Başka simgeye geçilince ya da sonraki tıklamada (menü seçimi, kapatma) biter.
    private var menuItem: DockWatcher.Item?
    private var clickMonitor: Any?

    /// Dock'un o anki yerini veren kaynak; kapanma kararı ve konum buna bakar.
    var liveItemFrame: (() -> CGRect?)?
    var liveDockFrame: (() -> CGRect?)?
    /// Dock otomatik gizliyken önizleme açık kaldıkça Dock açık tutulsun mu?
    var keepDockOpen: (() -> Bool)?
    /// Tam ekran şeridi; imleç üstündeyken önizleme kapanmaz.
    var stripFrame: (() -> CGRect?)?

    var isVisible: Bool { panel.isVisible }

    var isMouseInPanel: Bool {
        panel.isVisible && panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }

    private static let dwell: UInt64 = 180_000_000
    private static let leaveGrace: TimeInterval = 0.3

    init(thumbnails: ThumbnailStore) {
        self.thumbnails = thumbnails
        view = DockPreviewView(frame: .zero)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        // Önizleme yazıları beyaz: açık temada HUD malzemesi açık renk olup yazıyı siliyor.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        // .auxiliary olmadan başka uygulamanın tam ekran alanına girilemiyor (V1'de ölçüldü).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .auxiliary, .canJoinAllApplications]

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.addSubview(view)
        panel.contentView = background

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.dockClicked(event) }
        }

        view.thumbnailProvider = { [weak thumbnails] in thumbnails?.image(for: $0) }
        view.onChoose = { [weak self] window in
            self?.hide()
            self?.onChoose?(window)
        }
        view.onClose = { [weak self] window in self?.onClose?(window) }
        view.onAppAction = { [weak self] action, app in
            self?.hide()
            self?.onAppAction?(action, app)
        }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// Başka uygulamalara giden tıklamalar (Dock dahil). Sağ tık ya da Control-tık Dock'un
    /// kendi menüsünü açar; önizleme açık kalırsa menü altında kalıyordu.
    private func dockClicked(_ event: NSEvent) {
        let opensMenu = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        guard opensMenu else {
            menuItem = nil // Menüden seçim ya da menüyü kapatan tıklama.
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        let cursor = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        guard let dock = liveDockFrame?() ?? currentItem?.frame, dock.insetBy(dx: -14, dy: -14).contains(cursor),
              let item = currentItem ?? (panel.isVisible ? lastItem : nil)
        else { return }
        DockTrace.log("sag tik: \(item.title) menusu, onizleme gizlendi")
        menuItem = item
        hide()
    }

    /// Simgenin karesi büyütme ve Dock'un kayması sırasında değişir; aynı simge kimliğiyle tanınır.
    private static func sameIcon(_ a: DockWatcher.Item, _ b: DockWatcher.Item) -> Bool {
        a.title == b.title && a.bundleID == b.bundleID
    }

    func dockItemChanged(_ item: DockWatcher.Item?) {
        DockTrace.log("secim \(item?.title ?? "yok") kare=\(item.map { "\($0.frame)" } ?? "-") on=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") imlec=\(NSEvent.mouseLocation)")
        currentItem = item
        showTask?.cancel()
        guard let item else { return } // Kapanma kararını izleyici verir: imleç panele gidiyor olabilir.
        if let menuItem {
            if Self.sameIcon(menuItem, item) { return }
            self.menuItem = nil
        }

        if panel.isVisible {
            present(item)
            return
        }
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.dwell)
            guard let self, !Task.isCancelled, self.currentItem == item,
                  !(self.menuItem.map { Self.sameIcon($0, item) } ?? false) else { return }
            if !item.isFixedFrame { await self.waitForDockToSettle() }
            guard !Task.isCancelled, self.currentItem == item else { return }
            self.present(item)
        }
    }

    /// Tam ekranda Dock kayarak gelir: panelin yeri kayma bitince hesaplanmalı.
    private func waitForDockToSettle() async {
        var last = liveItemFrame?()
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let next = liveItemFrame?()
            if next == last { return }
            last = next
        }
    }

    func updateThumbnail(_ id: CGWindowID, _ image: CGImage) {
        guard panel.isVisible else { return }
        view.updateThumbnail(id, image)
    }

    func hide() {
        showTask?.cancel()
        leaveTimer?.invalidate()
        leaveTimer = nil
        outsideSince = nil
        shownAppID = nil
        panel.orderOut(nil)
        view.clear()
        // Pencereye geçmeden önce: Dock'un yeri boş kalmasın.
        DockAutoHide.release()
    }

    func refreshAfterClose() {
        guard panel.isVisible, let item = currentItem ?? lastItem else { return }
        present(item)
    }

    private var lastItem: DockWatcher.Item?

    private func present(_ original: DockWatcher.Item) {
        var item = original
        if !original.isFixedFrame, let live = liveItemFrame?() { item.frame = live }
        lastItem = item
        guard let screen = NSScreen.screens.first(where: { CGDisplayBounds($0.displayID).intersects(item.frame) }) ?? NSScreen.main
        else { return }

        let id = item.bundleID
        let snapshot = SceneSource.snapshot(for: screen, pinned: [])
        let app = id.flatMap { snapshot.app($0) } ?? snapshot.apps.values.first { $0.name == item.title }
        // Kapalı uygulamanın paneli yok; penceresiz ama çalışan uygulamada çıkılabilsin diye açılır.
        // Eylemi de penceresi de olmayan (penceresiz Finder) panelin gösterecek bir şeyi yok.
        guard let app, app.isRunning, !(app.windows.isEmpty && app.id == "com.apple.finder") else {
            DockTrace.log("gosterilmedi: \(item.title) calismiyor ya da bulunamadi (kimlik \(id ?? "-"))")
            hide()
            return
        }

        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        let size = view.show(app, scale: screen.backingScaleFactor, orientation: orientation, limit: screen.visibleFrame.size)
        background.frame = CGRect(origin: .zero, size: size)
        view.frame = background.bounds

        panel.setFrame(frameBeside(item.frame, size: size, orientation: orientation, on: screen), display: true)
        panel.orderFrontOnActiveSpace()
        if keepDockOpen?() == true { DockAutoHide.hold() }
        DockTrace.log("gosterildi \(app.name) \(app.windows.count) pencere panel=\(panel.frame) simge=\(item.frame) gorunur=\(panel.isVisible) aktifAlanda=\(panel.isOnActiveSpace)")

        if shownAppID != app.id {
            shownAppID = app.id
            thumbnails.refresh(windowIDs: app.windows.map(\.id), keepingOthers: true)
        }
        startLeaveTimer()
    }

    /// Simgenin Dock'un iç tarafına düşen yanı. NSScreen uzayında döner.
    private func frameBeside(_ icon: CGRect, size: CGSize, orientation: String, on screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let iconRect = CGRect(x: icon.minX, y: primaryHeight - icon.maxY, width: icon.width, height: icon.height)
        let visible = screen.visibleFrame
        // Konum simgenin gerçek yerinden gelir: tam ekranda visibleFrame Dock'u dışarıda bırakmaz,
        // ona göre yerleşen panel açılan Dock'un üstüne binerdi.
        let gap: CGFloat = 14
        var origin: CGPoint
        switch orientation {
        case "right":
            origin = CGPoint(x: iconRect.minX - size.width - gap, y: iconRect.midY - size.height / 2)
        case "left":
            origin = CGPoint(x: iconRect.maxX + gap, y: iconRect.midY - size.height / 2)
        default:
            origin = CGPoint(x: iconRect.midX - size.width / 2, y: iconRect.maxY + gap)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }

    /// Yalnızca panel açıkken çalışır: imleç ne Dock simgesinde ne panelde kaldıysa kapatır.
    /// Aradaki boşluk için kısa bir süre tanınır.
    private func startLeaveTimer() {
        guard leaveTimer == nil else { return }
        leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLeave() }
        }
    }

    private func checkLeave() {
        let mouse = NSEvent.mouseLocation
        let inPanel = panel.frame.insetBy(dx: -6, dy: -6).contains(mouse)
        // Dock seçimi imleç panele geçince temizlenmeyebiliyor; asıl ölçü imlecin yeri.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cursor = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        // Dock'un üstündeyken panel kapanmaz: simgeler arasında gezinirken ve kayma sürerken
        // bildirim anındaki kare geçersizdir.
        let dockFrame = liveDockFrame?() ?? currentItem?.frame
        // Dock ile ekran kenarı arasında birkaç noktalık boşluk var: imleç en kenardayken de Dock'ta sayılır.
        let onDock = dockFrame?.insetBy(dx: -14, dy: -14).contains(cursor) ?? false
        let onStrip = stripFrame?()?.insetBy(dx: -6, dy: -6).contains(mouse) ?? false
        if inPanel || onDock || onStrip {
            outsideSince = nil
            return
        }
        guard let since = outsideSince else {
            outsideSince = Date()
            return
        }
        if Date().timeIntervalSince(since) >= Self.leaveGrace {
            DockTrace.log("kapandi: imlec=\(cursor) dock=\(dockFrame.map { "\($0)" } ?? "-")")
            hide()
        }
    }
}

/// Panelin içi: başlık ve pencere kartları.
final class DockPreviewView: NSView {
    var onChoose: ((SceneWindow) -> Void)?
    var onClose: ((SceneWindow) -> Void)?
    var onAppAction: ((DockAppAction, SceneApp) -> Void)?
    var thumbnailProvider: ((CGWindowID) -> CGImage?)?

    private struct Card {
        var window: SceneWindow
        var frame: CGRect
        var closeRect: CGRect
        var highlight: CALayer
        var image: CALayer
        var closeButton: CALayer
        var placeholder: CALayer?
    }

    private struct HeaderButton {
        var action: DockAppAction
        var rect: CGRect
        var layer: CALayer
    }

    private var cards: [Card] = []
    private var headerButtons: [HeaderButton] = []
    private var hoveredHeader: DockAppAction?
    private var pressedHeader: DockAppAction?
    private var actionHint: CATextLayer?
    private var shownApp: SceneApp?
    private var hoveredIndex: Int?
    private var scale: CGFloat = 2
    private var trackingArea: NSTrackingArea?
    private var pressedIndex: Int?

    private static let cardWidth: CGFloat = 200
    private static let imageHeight: CGFloat = 124
    private static let captionHeight: CGFloat = 36
    private static let gap: CGFloat = 8
    private static let padding: CGFloat = 10
    private static let header: CGFloat = 34

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
        cards = []
        hoveredIndex = nil
        pressedIndex = nil
        headerButtons = []
        hoveredHeader = nil
        pressedHeader = nil
        actionHint = nil
        shownApp = nil
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    /// Kartları kurar, panelin gereken boyutunu döner.
    func show(_ app: SceneApp, scale: CGFloat, orientation: String, limit: CGSize) -> CGSize {
        clear()
        self.scale = scale
        shownApp = app

        if app.windows.isEmpty {
            return showWithoutWindows(app)
        }

        let maxColumns = orientation == "bottom" ? 5 : 3
        let fitWidth = Int((limit.width - 2 * Self.padding - 20 + Self.gap) / (Self.cardWidth + Self.gap))
        let columns = max(1, min(app.windows.count, maxColumns, fitWidth))
        let cellHeight = Self.imageHeight + Self.captionHeight
        let fitRows = Int((limit.height - Self.header - 2 * Self.padding - 20 + Self.gap) / (cellHeight + Self.gap))
        let capacity = columns * max(1, fitRows)
        let windows = Array(app.windows.prefix(capacity))
        let rows = (windows.count + columns - 1) / columns

        let width = CGFloat(columns) * Self.cardWidth + CGFloat(columns - 1) * Self.gap + 2 * Self.padding
        let height = Self.header + CGFloat(rows) * cellHeight + CGFloat(rows - 1) * Self.gap + Self.padding

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buildHeader(app, width: width, hidden: app.windows.count - windows.count)
        for (index, window) in windows.enumerated() {
            let column = index % columns
            let row = index / columns
            let frame = CGRect(
                x: Self.padding + CGFloat(column) * (Self.cardWidth + Self.gap),
                y: Self.header + CGFloat(row) * (cellHeight + Self.gap),
                width: Self.cardWidth,
                height: cellHeight
            )
            cards.append(makeCard(window, frame: frame, app: app))
        }
        CATransaction.commit()
        return CGSize(width: width, height: height)
    }

    /// Çalışıyor ama penceresi yok: Dock'un sağ tık menüsüne gitmeden çıkılabilsin.
    private func showWithoutWindows(_ app: SceneApp) -> CGSize {
        let width: CGFloat = 250
        let height = Self.header + 28
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buildHeader(app, width: width, hidden: 0)
        let note = label(tx("Açık pencere yok", "No open windows"), font: .systemFont(ofSize: 11.5), color: NSColor(calibratedWhite: 1, alpha: 0.62))
        note.frame = CGRect(x: Self.padding + 2, y: Self.header, width: width - 2 * Self.padding - 4, height: 16)
        layer?.addSublayer(note)
        CATransaction.commit()
        return CGSize(width: width, height: height)
    }

    func updateThumbnail(_ id: CGWindowID, _ image: CGImage) {
        guard let index = cards.firstIndex(where: { $0.window.id == id }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cards[index].image.contents = image
        cards[index].image.backgroundColor = nil
        cards[index].placeholder?.removeFromSuperlayer()
        cards[index].placeholder = nil
        CATransaction.commit()
    }

    private func buildHeader(_ app: SceneApp, width: CGFloat, hidden: Int) {
        let icon = CALayer()
        icon.frame = CGRect(x: Self.padding + 2, y: 8, width: 20, height: 20)
        var rect = CGRect(x: 0, y: 0, width: 20 * scale, height: 20 * scale)
        icon.contents = app.icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        icon.contentsGravity = .resizeAspect
        layer?.addSublayer(icon)

        let suffix = hidden > 0 ? "  +\(hidden)" : ""
        let title = label(app.name + suffix, font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
        let actions = Self.actions(for: app)
        let buttonSize: CGFloat = 26
        let buttonsWidth = CGFloat(actions.count) * buttonSize + CGFloat(max(actions.count - 1, 0)) * 2
        let hintWidth: CGFloat = 50
        title.frame = CGRect(
            x: Self.padding + 28,
            y: 9,
            width: max(40, width - 2 * Self.padding - 30 - buttonsWidth - hintWidth),
            height: 18
        )
        layer?.addSublayer(title)

        var x = width - Self.padding - buttonsWidth
        let hint = label("", font: .systemFont(ofSize: 11.5, weight: .medium), color: NSColor(calibratedWhite: 1, alpha: 0.7))
        hint.frame = CGRect(x: x - hintWidth - 4, y: 10, width: hintWidth, height: 16)
        hint.alignmentMode = .right
        layer?.addSublayer(hint)
        actionHint = hint

        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        for action in actions {
            let rect = CGRect(x: x, y: 5, width: buttonSize, height: buttonSize)
            let button = CALayer()
            button.frame = rect
            button.cornerRadius = buttonSize / 2
            if let symbol = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.label)?
                .withSymbolConfiguration(configuration) {
                let glyph = CALayer()
                glyph.frame = button.bounds.insetBy(dx: 5, dy: 5)
                var imageRect = CGRect(x: 0, y: 0, width: symbol.size.width * scale, height: symbol.size.height * scale)
                glyph.contents = symbol.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)
                glyph.contentsGravity = .resizeAspect
                button.addSublayer(glyph)
            }
            layer?.addSublayer(button)
            headerButtons.append(HeaderButton(action: action, rect: rect, layer: button))
            x += buttonSize + 2
        }
    }

    /// Finder'ın Dock menüsünde de "Çık" yoktur: kapatılması beklenen bir uygulama değil.
    private static func actions(for app: SceneApp) -> [DockAppAction] {
        let isHidden = app.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.isHidden } ?? false
        // Penceresi yoksa gizleyecek bir şey de yoktur.
        var actions: [DockAppAction] = app.windows.isEmpty && !isHidden ? [] : [isHidden ? .show : .hide]
        if app.id != "com.apple.finder" { actions.append(.quit) }
        return actions
    }

    private func setHoveredHeader(_ next: DockAppAction?) {
        guard next != hoveredHeader else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for button in headerButtons {
            button.layer.backgroundColor = button.action == next ? button.action.hoverColor.cgColor : nil
        }
        if let string = next?.label {
            actionHint?.string = NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.7),
                .paragraphStyle: Self.rightAligned
            ])
        } else {
            actionHint?.string = nil
        }
        CATransaction.commit()
        hoveredHeader = next
    }

    private static let rightAligned: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()

    private func makeCard(_ window: SceneWindow, frame: CGRect, app: SceneApp) -> Card {
        let highlight = CALayer()
        highlight.frame = frame.insetBy(dx: -4, dy: -4)
        highlight.cornerRadius = 10
        highlight.cornerCurve = .continuous
        layer?.addSublayer(highlight)

        let area = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.imageHeight)
        let fitted = PileLayout.frames(in: area, aspects: [window.aspect])[0]
        let image = CALayer()
        image.frame = fitted
        image.cornerRadius = 7
        image.cornerCurve = .continuous
        image.masksToBounds = true
        image.contentsGravity = .resize
        image.borderWidth = 0.5
        image.borderColor = NSColor(calibratedWhite: 1, alpha: 0.2).cgColor

        var placeholder: CALayer?
        if let thumbnail = thumbnailProvider?(window.id) {
            image.contents = thumbnail
        } else {
            image.backgroundColor = NSColor(calibratedWhite: 0.28, alpha: 1).cgColor
            let icon = CALayer()
            let side = min(44, fitted.height * 0.42)
            icon.frame = CGRect(x: (fitted.width - side) / 2, y: (fitted.height - side) / 2, width: side, height: side)
            var rect = CGRect(x: 0, y: 0, width: side * scale, height: side * scale)
            icon.contents = app.icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            icon.contentsGravity = .resizeAspect
            image.addSublayer(icon)
            placeholder = icon
        }
        layer?.addSublayer(image)

        let title = label(window.displayName(appName: app.name, windowCount: app.windows.count), font: .systemFont(ofSize: 11.5, weight: .medium), color: .white)
        title.frame = CGRect(x: frame.minX + 2, y: area.maxY + 4, width: frame.width - 4, height: 15)
        layer?.addSublayer(title)

        let place = label(window.badge, font: .systemFont(ofSize: 10.5), color: NSColor(calibratedWhite: 1, alpha: 0.6))
        place.frame = CGRect(x: frame.minX + 2, y: area.maxY + 19, width: frame.width - 4, height: 14)
        layer?.addSublayer(place)

        let side: CGFloat = 22
        let closeRect = CGRect(x: fitted.maxX - side - 5, y: fitted.minY + 5, width: side, height: side)
        let close = CALayer()
        close.frame = closeRect
        close.cornerRadius = side / 2
        close.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.78).cgColor
        close.isHidden = true
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: tx("Pencereyi kapat", "Close window"))?.withSymbolConfiguration(configuration) {
            let glyph = CALayer()
            glyph.frame = close.bounds.insetBy(dx: 6, dy: 6)
            var rect = CGRect(x: 0, y: 0, width: symbol.size.width * scale, height: symbol.size.height * scale)
            glyph.contents = symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            glyph.contentsGravity = .resizeAspect
            close.addSublayer(glyph)
        }
        layer?.addSublayer(close)

        return Card(window: window, frame: frame, closeRect: closeRect, highlight: highlight, image: image, closeButton: close, placeholder: placeholder)
    }

    private func label(_ string: String, font: NSFont, color: NSColor) -> CATextLayer {
        let layer = LabelLayer()
        layer.needsDisplayOnBoundsChange = true
        layer.contentsScale = scale
        layer.string = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        return layer
    }

    private func index(at point: CGPoint) -> Int? {
        cards.firstIndex { $0.frame.insetBy(dx: -4, dy: -4).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(index(at: point), point: point)
        setHoveredHeader(headerButtons.first { $0.rect.contains(point) }?.action)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil, point: .zero)
        setHoveredHeader(nil)
    }

    private func setHovered(_ next: Int?, point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hoveredIndex != next {
            if let hoveredIndex, cards.indices.contains(hoveredIndex) {
                cards[hoveredIndex].highlight.backgroundColor = nil
                cards[hoveredIndex].closeButton.isHidden = true
            }
            if let next {
                cards[next].highlight.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.13).cgColor
                cards[next].closeButton.isHidden = false
            }
            hoveredIndex = next
        }
        if let next {
            let onClose = cards[next].closeRect.contains(point)
            cards[next].closeButton.backgroundColor = onClose
                ? NSColor.systemRed.cgColor
                : NSColor(calibratedWhite: 0.08, alpha: 0.78).cgColor
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedIndex = index(at: point)
        pressedHeader = headerButtons.first { $0.rect.contains(point) }?.action
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let released = index(at: point)
        let header = headerButtons.first { $0.rect.contains(point) }?.action
        let pressedAction = pressedHeader
        pressedHeader = nil
        if let header, header == pressedAction, let shownApp {
            onAppAction?(header, shownApp)
            return
        }
        defer { pressedIndex = nil }
        guard let released, released == pressedIndex else { return }
        let card = cards[released]
        if card.closeRect.contains(point) {
            onClose?(card.window)
        } else {
            onChoose?(card.window)
        }
    }
}
