import AppKit
import Carbon.HIToolbox
import BerthCore
import OSLog

/// Kaplama paneli.
///
/// `.nonactivatingPanel`: uygulama öne geçmeden klavyeyi alır. Böylece açılış tam ekran
/// bir alandan masaüstüne atmaz, menü çubuğunda önceki uygulama kalır, kapanışta odak
/// iadesi gerekmez. Seviye Dock'un hemen altında: Mission Control'de olduğu gibi Dock
/// yerinde ve kullanılabilir kalır.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        acceptsMouseMovedEvents = true
        isExcludedFromWindowsMenu = true
        // .auxiliary olmadan başka uygulamanın tam ekran alanına girilemiyor (V1'de ölçüldü).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .auxiliary, .canJoinAllApplications]
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, SceneViewDelegate {
    private let log = Logger(subsystem: "io.github.brkhsdmr.berth", category: "App")

    private let store = ArrangementStore()
    private let settings = AppSettings()
    private lazy var settingsWindow = SettingsWindowController(
        store: store, settings: settings, layouts: layoutStore,
        layoutActions: LayoutActions(
            restore: { [weak self] layout in
                Task { @MainActor [weak self] in await self?.restoreLayout(layout) }
            },
            saveCurrent: { [weak self] in
                guard let self else { return }
                self.saveCurrentLayout(store: self.layoutStore)
            },
            isHotKeyFree: { [weak self] hotKey in self?.isHotKeyFree(hotKey) ?? false }
        )
    )
    private var layoutHotKeys: [GlobalHotKey] = []
    private let dockWatcher = DockWatcher()
    private lazy var dockPreview = DockPreviewController(thumbnails: thumbnails)
    private let fullScreenDock = FullScreenDockController()
    /// Bu tarihe kadar başka uygulamanın öne gelmesi kaplamayı kapatmaz: pencere kapatırken
    /// uygulama bir an öne alınabiliyor, kullanıcı buradan ayrılmak istemedi.
    private var ignoreActivationUntil = Date.distantPast
    private let thumbnails = ThumbnailStore()
    private let wallpapers = WallpaperStore()
    private let panel = OverlayPanel()
    private let scene = SceneView()

    private var hotKey: GlobalHotKey?
    private var registeredShortcut: Shortcut?
    private var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []

    private var isOpen = false {
        didSet { trackpadGesture.setOverlayOpen(isOpen) }
    }
    private let trackpadGesture = TrackpadGestureTap()
    private let hotCorner = HotCornerMonitor()
    private let layoutStore = WorkspaceLayoutStore()
    private var isClosing = false
    /// Tam ekrana alma ve sıralama sürerken imleç bizde: yeni açılış işi bozar.
    private var isPlacingSpace = false
    private var activeScreen: NSScreen?
    private var snapshot: SceneSnapshot?
    /// Normal masaüstündeki kullanılabilir alan. Tam ekran alanında Dock ve menü çubuğu
    /// yokken de aynısı kullanılır; yoksa açıldığı alana göre yığınların yeri değişirdi.
    private var desktopVisibleFrames: [CGDirectDisplayID: CGRect] = [:]

    // MARK: - Başlangıç

    func applicationWillTerminate(_ notification: Notification) {
        DockAutoHide.release()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockAutoHide.restoreAfterCrash()
        panel.contentView = scene
        scene.delegate = self
        scene.thumbnailProvider = { [weak self] in self?.thumbnails.image(for: $0) }

        thumbnails.isEnabled = { [weak self] in self?.previewsAvailable ?? false }
        settings.onWindowPreviewsChange = { [weak self] enabled in
            if enabled {
                Permissions.requestScreenRecording()
            } else {
                self?.thumbnails.clear()
            }
        }
        thumbnails.onImage = { [weak self] id, image in
            guard let self else { return }
            if self.isOpen { self.scene.updateThumbnail(id, image) }
            self.dockPreview.updateThumbnail(id, image)
        }
        dockWatcher.onChange = { [weak self] item in
            guard let self else { return }
            guard !self.isOpen, !self.isPlacingSpace else {
                DockTrace.log("yok sayildi: sahne acik=\(self.isOpen) yerlestirme=\(self.isPlacingSpace)")
                return
            }
            self.dockPreview.dockItemChanged(item)
        }
        dockPreview.liveItemFrame = { [weak self] in self?.dockWatcher.liveItemFrame() }
        dockPreview.liveDockFrame = { [weak self] in self?.dockWatcher.liveDockFrame() }
        dockPreview.onChoose = { [weak self] window in self?.activate(window) }
        dockPreview.onClose = { [weak self] window in
            guard let self else { return }
            Task { @MainActor in
                await self.closeWindow(window)
                self.dockPreview.refreshAfterClose()
            }
        }
        dockPreview.onAppAction = { [weak self] action, app in
            self?.perform(action, on: app)
        }
        settings.onDockPreviewsChange = { [weak self] enabled in
            guard let self else { return }
            if enabled { self.dockWatcher.start() } else { self.dockWatcher.stop(); self.dockPreview.hide() }
        }
        dockPreview.stripFrame = { [weak self] in self?.fullScreenDock.frame }
        dockPreview.keepDockOpen = { [weak self] in self?.settings.keepDockOpenDuringPreview ?? false }
        fullScreenDock.entries = { [weak self] in self?.dockWatcher.applicationEntries() ?? [] }
        fullScreenDock.liveDockFrame = { [weak self] in self?.dockWatcher.liveDockFrame() }
        fullScreenDock.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.isOpen || self.isPlacingSpace || !self.settings.dockPreviewsEnabled
        }
        fullScreenDock.isMouseInPreview = { [weak self] in self?.dockPreview.isMouseInPanel ?? false }
        fullScreenDock.onHover = { [weak self] item in self?.dockPreview.dockItemChanged(item) }
        fullScreenDock.onChoose = { [weak self] entry in self?.launchOrActivate(entry) }
        settings.onFullScreenDockChange = { [weak self] enabled in
            if enabled { self?.fullScreenDock.start() } else { self?.fullScreenDock.stop() }
        }
        if settings.fullScreenDockEnabled { fullScreenDock.start() }
        trackpadGesture.onOpen = { [weak self] in
            guard let self, !self.isOpen else { return }
            if self.forwardToRemoteSession() { return }
            self.open()
        }
        trackpadGesture.onClose = { [weak self] in self?.close() }
        settings.onTrackpadFingersChange = { [weak self] count in self?.trackpadGesture.setFingers(count) }
        trackpadGesture.setFingers(settings.trackpadFingers)
        hotCorner.onTrigger = { [weak self] in self?.toggle() }
        settings.onHotCornerChange = { [weak self] corner, delay in self?.hotCorner.configure(corner: corner, delay: delay) }
        hotCorner.configure(corner: settings.hotCorner, delay: settings.hotCornerDelay)
        settings.onShortcutChange = { [weak self] shortcut in
            guard let self else { return false }
            // Kısayol kapalıyken yalnızca kaydedilir; açılınca alınır.
            return self.settings.shortcutEnabled ? self.register(shortcut) : true
        }
        settings.onShortcutEnabledChange = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                _ = self.register(self.settings.shortcut)
            } else {
                self.hotKey = nil
                self.registeredShortcut = nil
            }
        }
        if settings.dockPreviewsEnabled { dockWatcher.start() }
        wallpapers.onUpdate = { [weak self] id in
            guard let self, self.isOpen, let screen = self.activeScreen, screen.displayID == id else { return }
            self.scene.updateWallpaper(self.wallpapers.entry(for: screen))
        }

        if settings.shortcutEnabled, !register(settings.shortcut) {
            log.error("\(self.settings.shortcut.display, privacy: .public) kaydedilemedi; başka bir uygulama kullanıyor olabilir.")
        }
        installStatusItem()
        installObservers()
        layoutStore.onChange = { [weak self] in self?.registerLayoutHotKeys() }
        Compatibility.reportIfBroken()
        remoteBridge.onClientsChange = { [weak self] names in self?.settings.connectedRemotes = names }
        settings.onRemoteBridgeChange = { [weak self] enabled in
            guard let self else { return }
            if enabled { self.remoteBridge.start(token: self.settings.remoteToken, blocked: self.settings.blockedRemotes) } else { self.remoteBridge.stop() }
        }
        settings.onRemoteTokenChange = { [weak self] token in self?.remoteBridge.updateToken(token) }
        settings.onBlockedRemotesChange = { [weak self] names in self?.remoteBridge.updateBlocked(names) }
        if settings.remoteBridgeEnabled { remoteBridge.start(token: settings.remoteToken, blocked: settings.blockedRemotes) }
        registerLayoutHotKeys()
        Permissions.requestAccessibilityIfNeeded()
        refreshWallpaper()

        #if DEBUG
        installSnapTestHook()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.brkhsdmr.berth.settings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        // Dock önizlemesini açar (ekran görüntüsü için); nesne uygulama kimliği, boşsa kapatır.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.brkhsdmr.berth.dockPreview"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let id = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                if id.isEmpty { self.dockPreview.holdOpen = false; self.dockPreview.hide(); return }
                guard let item = self.dockWatcher.item(bundleID: id) else { DockTrace.log("dock testi: \(id) yok"); return }
                self.dockPreview.holdOpen = true
                self.dockPreview.dockItemChanged(item)
            }
        }
        // Sahneyi açıp aramaya yazar (ekran görüntüsü için); nesne aranan söz, boşsa kapatır.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.brkhsdmr.berth.searchPreview"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let query = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                if query.isEmpty { self.close(); return }
                if !self.panel.isVisible { self.toggle() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.scene.debugSetQuery(query) }
            }
        }
        // Ayarlarda bir bölümü açar (ekran görüntüsü için); nesne bölümün adı.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.brkhsdmr.berth.settingsPage"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let page = note.object as? String
            MainActor.assumeIsolated {
                self?.showSettings()
                NotificationCenter.default.post(name: .showSettingsPage, object: page)
            }
        }
        // Uzak masaüstü köprüsünü sınamak için: bağlı Windows'a aç/kapat gönderir.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.brkhsdmr.berth.remoteToggle"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { DockTrace.log("uzak aç/kapat gönderildi: \(self?.remoteBridge.sendToggle() ?? false)") }
        }
        // Yalnızca okur: düzeni yakalayıp kayda yazar, hiçbir pencereyi taşımaz.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.brkhsdmr.berth.layoutCapture"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let layout = self?.captureLayout(named: "sinama") else { return }
                let apps = Set(layout.windows.map(\.appID)).count
                let small = layout.windows.filter { $0.frame.width < 100 }.count
                DockTrace.log("duzen yakalandi: \(layout.windows.count) pencere, \(apps) uygulama, kucultulmus \(layout.windows.filter(\.minimized).count), dar \(small)")
            }
        }
        #endif

        // Geliştirme ve doğrulama yolu: betiklerden aç/kapat.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.brkhsdmr.berth.toggle"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    /// Eski kısayol önce bırakılır; yenisi alınamazsa eskisi geri alınır.
    private func register(_ shortcut: Shortcut) -> Bool {
        let previous = registeredShortcut
        hotKey = nil
        let make: (Shortcut) -> GlobalHotKey? = { [weak self] value in
            GlobalHotKey(keyCode: value.keyCode, modifiers: value.carbonModifiers) {
                MainActor.assumeIsolated { self?.toggle() }
            }
        }
        if let created = make(shortcut) {
            hotKey = created
            registeredShortcut = shortcut
            return true
        }
        if let previous { hotKey = make(previous) }
        return false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Berth")
        // Sol tık sahneyi açar, sağ tık menüyü: menü kalıcı atanırsa sol tık da menü açar.
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu, let statusItem else {
            toggle()
            return
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        // Dock'tan ya da ⌘Tab ile başka uygulamaya geçildiyse iş bitmiştir.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // Öne gelen biz isek (uzak masaüstünden klavyeyi almak için) sahne açık kalır.
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if activated?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dockPreview.hide()
                self.fullScreenDock.hide()
                if self.isOpen, Date() >= self.ignoreActivationUntil { self.close() }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isOpen { self.close(animated: false) }
                self.fullScreenDock.hide()
                // Masaüstleri farklı duvar kağıdı kullanabilir; yakalama değil, dosya okuma.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated { self?.refreshWallpaper() }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isOpen { self.close(animated: false) }
                self.wallpapers.invalidate()
                self.desktopVisibleFrames.removeAll()
            }
        })
    }

    // MARK: - Aç / kapat

    func toggle() {
        if isOpen { close() } else { open() }
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Sahnede kullanılan düzen. Demo modunda (debug) demo uygulamaları sırayla sabitlenir, kayıt değişmez.
    private var sceneArrangement: Arrangement {
        #if DEBUG
        if let demo = DemoMode.apps {
            return Arrangement(pinned: demo, sizes: store.arrangement.sizes.filter { demo.contains($0.key) })
        }
        #endif
        return store.arrangement
    }

    private func open() {
        guard !isClosing, !isPlacingSpace else { return }
        dockPreview.hide()
        fullScreenDock.hide()
        let screen = currentScreen()
        activeScreen = screen

        store.update { arrangement in
            // Sabit uygulamalar kurulmamışsa, açık olanlardan başla.
            if arrangement.pinned.isEmpty {
                let current = SceneSource.snapshot(for: screen, pinned: [])
                arrangement.pinned = current.otherApps(pinned: []).map(\.id)
            }
        }
        let snapshot = SceneSource.snapshot(for: screen, pinned: store.arrangement.pinned)
        store.update { arrangement in
            for id in arrangement.pinned {
                arrangement.assignInitialSizeIfNeeded(id: id, windowCount: snapshot.app(id)?.windows.count ?? 0)
            }
        }
        self.snapshot = snapshot

        let usable = usableFrame(for: screen, snapshot: snapshot)
        panel.setFrame(screen.frame, display: false)
        scene.frame = CGRect(origin: .zero, size: screen.frame.size)
        scene.present(SceneContent(
            snapshot: snapshot,
            arrangement: sceneArrangement,
            usable: usable,
            screenOrigin: CGDisplayBounds(screen.displayID).origin,
            backingScale: screen.backingScaleFactor,
            wallpaper: wallpapers.entry(for: screen),
            previewsAvailable: previewsAvailable,
            showsOtherAppWindows: settings.otherAppsScrollEnabled,
            screenRecordingGranted: !settings.windowPreviewsEnabled || Permissions.screenRecording,
            accessibilityGranted: Permissions.accessibility
        ))

        panel.orderFrontOnActiveSpace()
        takeKeyboardIfGrabbed()
        panel.makeKey()
        panel.makeFirstResponder(scene)
        isOpen = true

        thumbnails.refresh(windowIDs: snapshot.apps.values.flatMap { $0.windows.map(\.id) })
        if wallpapers.entry(for: screen) == nil {
            wallpapers.prepare(for: screen, canCapture: previewsAvailable && !snapshot.currentSpaceIsFullScreen)
        }
    }

    func close(animated: Bool = true, flyingBack windowID: CGWindowID? = nil, destination: CGRect? = nil) {
        giveKeyboardBack()
        scheduleMemoryRelease()
        guard isOpen, !isClosing else { return }
        isClosing = true
        scene.dismiss(animated: animated, focus: windowID, destination: destination) { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.scene.teardown()
            self.isOpen = false
            self.isClosing = false
        }
    }

    /// Kullanılabilir alan, görünüm uzayında: sol üst orijin.
    private func usableFrame(for screen: NSScreen, snapshot: SceneSnapshot) -> CGRect {
        let id = screen.displayID
        if !snapshot.currentSpaceIsFullScreen {
            desktopVisibleFrames[id] = screen.visibleFrame
        }
        let visible = desktopVisibleFrames[id] ?? screen.visibleFrame
        let frame = screen.frame
        return CGRect(
            x: visible.minX - frame.minX,
            y: frame.maxY - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    private var previewsAvailable: Bool {
        settings.windowPreviewsEnabled && Permissions.screenRecording
    }

    /// Duvar kağıdını hazırlar. Pencere görüntüsü burada alınmaz: ekran yakalama yalnızca kullanıcı
    /// sahneyi ya da Dock önizlemesini açınca yapılır, macOS'un kayıt göstergesi boşta tetiklenmez.
    private func refreshWallpaper() {
        let screen = currentScreen()
        let onFullScreen = SceneSource.currentSpaceIsFullScreen(on: screen)
        wallpapers.prepare(for: screen, canCapture: previewsAvailable && !onFullScreen)
    }

    // MARK: - SceneViewDelegate

    func sceneDidRequestDismiss() { close() }

    func scene(didChoose window: SceneWindow) {
        activate(window)
        // Başka masaüstüne gidiliyorsa önizleme eski yerine dönmemeli.
        close(animated: true, flyingBack: window.state == .visible ? window.id : nil)
    }

    private func activate(_ window: SceneWindow) {
        do {
            try WindowActivator.activateWindow(
                pid: window.pid,
                windowID: window.id,
                title: window.title,
                frame: window.frame,
                order: window.appIndex
            )
        } catch {
            log.error("Pencere etkinleştirilemedi: \(String(describing: error), privacy: .public)")
            // Erişilebilirlik izni yoksa en azından uygulama öne gelsin.
            try? WindowActivator.activateApp(pid: window.pid)
        }
    }

    func scene(didSnap window: SceneWindow, to position: SnapPosition) {
        guard let screen = activeScreen, let snapshot else { return }
        let usable = usableFrame(for: screen, snapshot: snapshot)
        let origin = CGDisplayBounds(screen.displayID).origin
        let target = position.frame(in: usable.offsetBy(dx: origin.x, dy: origin.y))

        // Önizleme, pencerenin gideceği yere uçar.
        close(animated: true, flyingBack: window.id, destination: target.offsetBy(dx: -origin.x, dy: -origin.y))
        Task { @MainActor [weak self] in
            await self?.snap(window, to: target, label: position.label)
        }
    }

    private func snap(_ window: SceneWindow, to target: CGRect, label: String) async {
        do {
            try await bringWithinReach(window)
            try await WindowActivator.placeWindow(
                pid: window.pid, title: window.title, frame: window.frame,
                order: window.appIndex, to: target
            )
            try await WindowActivator.raiseWindow(
                pid: window.pid, title: window.title, frame: target, order: window.appIndex
            )
        } catch {
            let reason = (error as? WindowActionError)?.description ?? String(describing: error)
            log.error("\(label, privacy: .public) başarısız: \(reason, privacy: .public)")
            Toast.show(reason)
            #if DEBUG
            try? reason.write(toFile: NSTemporaryDirectory() + "berth-last-snap-error.txt", atomically: true, encoding: .utf8)
            #endif
        }
    }

    /// Pencere sıradaki ekrana, o ekrandaki göreli yeri ve boyutuyla taşınır.
    func scene(didMoveToNextDisplay window: SceneWindow) {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let sourceIndex = screens.firstIndex { CGDisplayBounds($0.displayID).contains(center) } ?? 0
        let source = screens[sourceIndex], destination = screens[(sourceIndex + 1) % screens.count]
        let from = Self.cgVisibleFrame(source), to = Self.cgVisibleFrame(destination)
        let width = min(window.frame.width, to.width), height = min(window.frame.height, to.height)
        let rx = from.width > window.frame.width ? (window.frame.minX - from.minX) / (from.width - window.frame.width) : 0
        let ry = from.height > window.frame.height ? (window.frame.minY - from.minY) / (from.height - window.frame.height) : 0
        let target = CGRect(
            x: to.minX + max(0, min(1, rx)) * (to.width - width),
            y: to.minY + max(0, min(1, ry)) * (to.height - height),
            width: width, height: height
        ).integral
        close()
        Task { @MainActor [weak self] in
            await self?.snap(window, to: target, label: tx("Diğer ekrana taşı", "Move to next display"))
        }
    }

    /// Ekranın Dock ve menü çubuğu dışındaki alanı, pencere koordinatlarında (sol üst orijin).
    private static func cgVisibleFrame(_ screen: NSScreen) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: mainHeight - visible.maxY, width: visible.width, height: visible.height)
    }

    func scene(didToggleFullScreen window: SceneWindow, entering: Bool) {
        close()
        Task { @MainActor [weak self] in
            await self?.toggleFullScreen(window, entering: entering)
        }
    }

    private func toggleFullScreen(_ window: SceneWindow, entering: Bool) async {
        do {
            try await bringWithinReach(window)
            if entering {
                try await WindowActivator.enterFullScreen(
                    pid: window.pid, title: window.title, frame: window.frame, order: window.appIndex
                )
            } else {
                try await WindowActivator.leaveFullScreen(
                    pid: window.pid, title: window.title, frame: window.frame, order: window.appIndex
                )
            }
        } catch {
            report(error)
        }
    }

    func scene(didClose window: SceneWindow) {
        Task { @MainActor [weak self] in
            await self?.closeWindow(window)
        }
    }

    /// Kaplama açık kalır; pencere küçültülmüş olarak yerinde görünür.
    func scene(didMinimize window: SceneWindow) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ignoreActivationUntil = Date().addingTimeInterval(1.5)
            do {
                try await WindowActivator.minimizeWindow(
                    pid: window.pid, title: window.title, frame: window.frame, order: window.appIndex
                )
            } catch {
                self.report(error)
                return
            }
            // Küçültme canlandırması bitince yenile; yoksa pencere hâlâ görünür sayılır.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard self.isOpen, !self.isClosing, let screen = self.activeScreen else { return }
            let fresh = SceneSource.snapshot(for: screen, pinned: self.store.arrangement.pinned)
            self.snapshot = fresh
            self.scene.applySnapshot(fresh)
        }
    }

    /// Kaplama açık kalır: kullanıcı buradan ayrılmak istemedi. İki istisna var, ikisinde de
    /// kullanıcı pencereye götürülür: kapanmadıysa (kaydet sorusu kaplamanın altında kalırdı)
    /// ya da tam ekran pencere erişilebilirlik listesinde yoksa.
    private func closeWindow(_ window: SceneWindow) async {
        ignoreActivationUntil = Date().addingTimeInterval(1.5)
        do {
            try await WindowActivator.closeWindow(
                pid: window.pid, title: window.title, frame: window.frame, order: window.appIndex
            )
        } catch WindowActionError.windowNotFound where window.state != .visible {
            close(animated: false)
            do {
                try await bringWithinReach(window)
                try await WindowActivator.closeWindow(
                    pid: window.pid, title: window.title, frame: window.frame, order: window.appIndex
                )
            } catch {
                report(error)
            }
            return
        } catch {
            report(error)
            return
        }

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !Self.windowExists(window.id) { break }
        }
        if Self.windowExists(window.id) {
            close(animated: false)
            activate(window)
            return
        }
        guard isOpen, !isClosing, let screen = activeScreen else { return }
        let fresh = SceneSource.snapshot(for: screen, pinned: store.arrangement.pinned)
        snapshot = fresh
        scene.applySnapshot(fresh)
    }

    /// Şeritteki simgeye tıklama: Dock'taki gibi öne getirir, kapalıysa açar.
    private func launchOrActivate(_ entry: DockWatcher.Entry) {
        guard let url = entry.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            let message = tx("\(entry.title) açılamadı: \(error.localizedDescription)", "Couldn't open \(entry.title): \(error.localizedDescription)")
            DispatchQueue.main.async { MainActor.assumeIsolated { Toast.show(message) } }
        }
    }

    /// Öndeki pencere listedeki bir RDP oturumuysa hareketi oradaki Windows sahnesine iletir.
    ///
    /// Windows App klavyeyi uzak bilgisayara geçirir; oradaki uygulama Ctrl+Alt+Shift+Space'i dinliyor.
    /// Oturum adı pencere başlığından okunur (Erişilebilirlik): Ekran Kaydı izni gerekmez.
    /// Uzak masaüstü uygulamaları öndeyken klavyeyi kendileri yakalayıp uzak bilgisayara gönderir
    /// (Windows App'te ölçüldü: ok tuşları sahneye ulaşmadı). Sahne açıkken uygulamamız öne alınır,
    /// kapanınca önceki uygulama geri gelir.
    private static let keyboardGrabbers: Set<String> = [
        "com.microsoft.rdc.macos", "com.microsoft.rdc.osx.beta", "com.vmware.horizon",
        "com.parallels.desktop.console", "com.citrix.receiver.icaviewer.mac", "com.teamviewer.TeamViewer",
    ]
    private var keyboardOwner: NSRunningApplication?
    private var memoryRelease: DispatchWorkItem?
    let remoteBridge = RemoteBridge()

    private func takeKeyboardIfGrabbed() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let id = front.bundleIdentifier, Self.keyboardGrabbers.contains(id)
        else { return }
        keyboardOwner = front
        NSApp.activate(ignoringOtherApps: true)
    }

    private func giveKeyboardBack() {
        guard let owner = keyboardOwner else { return }
        keyboardOwner = nil
        // Seçilen pencere öne gelecekse ona dokunulmaz; yalnızca hâlâ biz öndeysek geri verilir.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
            owner.activate()
        }
    }

    /// Sahne kapandıktan bir süre sonra pencere görüntüleri bırakılır: yeniden açılışta zaten
    /// tazeleniyorlar, beklerken 20–50 MB tutuyorlardı. Kısa aralıkla yeniden açılırsa önbellek kalır.
    private func scheduleMemoryRelease() {
        memoryRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen, !self.dockPreview.isVisible else { return }
                self.thumbnails.clear()
            }
        }
        memoryRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Windows App'te ayarlardaki adı taşıyan oturum öndeyse hareket oradaki uygulamaya gider.
    /// Tuşla iletmek çalışmadı (Windows App yapay değiştirici tuşları geçirmiyor); Windows'taki
    /// uygulama bu Mac'e bağlanır ve komut o bağlantıdan gider (`RemoteBridge`).
    private func forwardToRemoteSession() -> Bool {
        guard settings.remoteBridgeEnabled,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.microsoft.rdc.macos",
              let title = WindowActivator.focusedWindowTitle(pid: app.processIdentifier)
        else { return false }
        let names = settings.remoteSessionList
        if names.isEmpty {
            // Adlar verilmemişse: yalnızca bu Mac'e bağlı bir Windows'un oturumu. Uygulamanın
            // olmadığı oturumlarda (başka bir bilgisayar) hareket Mac'in sahnesini açar.
            guard remoteBridge.sendToggle(matchingTitle: title, aliases: settings.remoteSessionAliases) else { return false }
        } else {
            guard names.contains(where: { title.localizedCaseInsensitiveContains($0) }) else { return false }
            guard remoteBridge.sendToggle() else {
                Toast.show(tx("Windows'taki Berth bu Mac'e bağlı değil.", "Berth on Windows isn't connected to this Mac."))
                return true
            }
        }
        DockTrace.log("hareket RDP oturumuna iletildi: \(title)")
        return true
    }

    private func perform(_ action: DockAppAction, on app: SceneApp) {
        guard let pid = app.pid else { return }
        do {
            switch action {
            case .hide: try WindowActivator.hideApp(pid: pid)
            case .show: NSRunningApplication(processIdentifier: pid)?.unhide()
            case .quit: try WindowActivator.quitApp(pid: pid)
            }
        } catch {
            report(error)
        }
    }

    private static func windowExists(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        return !list.isEmpty
    }

    private func report(_ error: Error) {
        let reason = (error as? WindowActionError)?.description ?? String(describing: error)
        log.error("Pencere eylemi başarısız: \(reason, privacy: .public)")
        Toast.show(reason)
    }

    func scene(didDrop window: SceneWindow, before: UInt64?) {
        guard let screen = activeScreen else { return }
        isPlacingSpace = true
        close()
        Task { @MainActor [weak self] in
            await self?.placeInSpaces(window, before: before, on: screen)
            self?.isPlacingSpace = false
        }
    }

    private func isFullScreenSpace(_ id: UInt64?, on screen: NSScreen) -> Bool {
        guard let id else { return false }
        return SceneSource.managedDisplay(for: screen)?.spaces.first { $0.id == id }?.isFullScreen ?? false
    }

    private func placeInSpaces(_ window: SceneWindow, before: UInt64?, on screen: NSScreen) async {
        do {
            var spaceID = window.spaceID
            if !isFullScreenSpace(spaceID, on: screen) {
                try await bringWithinReach(window)
                try await WindowActivator.enterFullScreen(
                    pid: window.pid, title: window.title, frame: window.frame, order: window.appIndex
                )
                spaceID = nil
                for _ in 0..<50 {
                    let current = SkyLight.spaces(forWindow: window.id).first
                    if isFullScreenSpace(current, on: screen) {
                        spaceID = current
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard spaceID != nil else {
                    throw WindowActionError.unsupported(tx("Pencere tam ekrana geçmedi; bu uygulama desteklemiyor olabilir.", "The window didn't enter full screen; this app may not support it."))
                }
                // Tam ekran geçiş animasyonu sürerken Mission Control açılmıyor.
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            guard let spaceID else { return }
            try await MissionControlDriver.moveSpace(spaceID, before: before, on: screen)
        } catch let error as WindowActionError {
            log.error("Tam ekrana alınamadı: \(error.description, privacy: .public)")
            Toast.show(error.description)
        } catch {
            log.error("Alan sırası değiştirilemedi: \(String(describing: error), privacy: .public)")
            Toast.show(tx("Pencere tam ekran oldu ama istediğin yere taşınamadı. Mission Control'den elle taşıyabilirsin.", "The window went full screen but couldn't be moved where you wanted. You can move it in Mission Control."))
        }
    }

    /// Başka alandaki pencere Erişilebilirlik listesinde olmayabilir (V1'de ölçüldü):
    /// önce oraya gidilir, kayma bitince iş yapılır.
    private func bringWithinReach(_ window: SceneWindow) async throws {
        switch window.state {
        case .visible, .minimized:
            return
        case .otherSpace, .fullScreen, .hidden:
            try WindowActivator.activateWindow(
                pid: window.pid, windowID: window.id, title: window.title,
                frame: window.frame, order: window.appIndex
            )
            for _ in 0..<25 where !WindowActivator.isOnActiveSpace(window.id) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Pencere listede görününce kayma henüz bitmiş olmuyor; bu sırada yazılan
            // tam ekrandan çıkma ve konum sessizce kayboluyor.
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    func scene(didChooseApp app: SceneApp) {
        if let pid = app.pid {
            // Penceresiz çalışan uygulama: "reopen" isteği kendi penceresini getirir.
            if let url = app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            } else {
                try? WindowActivator.activateApp(pid: pid)
            }
        } else if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    Logger(subsystem: "io.github.brkhsdmr.berth", category: "App")
                        .error("Uygulama açılamadı: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        close()
    }

    func scene(didLaunchApp url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Logger(subsystem: "io.github.brkhsdmr.berth", category: "App")
                    .error("Uygulama açılamadı: \(error.localizedDescription, privacy: .public)")
            }
        }
        close()
    }

    func scene(didChooseSpace space: SceneSpace) {
        guard let current = snapshot?.spaces.first(where: { $0.isCurrent }) else { return }
        if space.id == current.id {
            close()
            return
        }
        let offset = space.index - current.index
        close(animated: false)
        SpaceSwitcher.move(by: offset)
    }

    func sceneDidRequestScreenRecordingSettings() {
        Permissions.openScreenRecordingSettings()
        close()
    }

    func sceneDidRequestAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
        close()
    }

    func scene(changeArrangement change: (inout Arrangement) -> Void) {
        store.update(change)
        if let snapshot, let screen = activeScreen {
            scene.applyArrangement(store.arrangement, usable: usableFrame(for: screen, snapshot: snapshot))
        }
    }
}

#if DEBUG
extension AppController {
    /// Yalnızca debug derlemede: yaslamayı betikten sınar. Girdi "komut|başlık parçası";
    /// komut bir `SnapPosition` ya da pencereyi tam ekrana alan "enterFullScreen".
    fileprivate func installSnapTestHook() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.brkhsdmr.berth.snapTest"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let input = note.object as? String else { return }
            MainActor.assumeIsolated { self?.runSnapTest(input) }
        }
    }

    private func runSnapTest(_ input: String) {
        let parts = input.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if parts[0] == "space", let offset = Int(parts[1]) {
            SpaceSwitcher.move(by: offset)
            return
        }
        if parts[0] == "strip" {
            fullScreenDock.showForTesting()
            return
        }
        if parts[0] == "settings" {
            showSettings()
            return
        }
        let screen = NSScreen.screens[0]
        let snapshot = SceneSource.snapshot(for: screen, pinned: [])
        guard let window = snapshot.apps.values.flatMap(\.windows).first(where: { $0.title.contains(parts[1]) }) else {
            NSLog("snapTest: pencere yok: \(parts[1])")
            return
        }
        if parts[0] == "fsOn" || parts[0] == "fsOff" {
            Task { @MainActor in await self.toggleFullScreen(window, entering: parts[0] == "fsOn") }
            return
        }
        if parts[0] == "activate" {
            activate(window)
            return
        }
        if parts[0] == "close" {
            Task { @MainActor in await self.closeWindow(window) }
            return
        }
        if parts[0] == "enterFullScreen" {
            Task { @MainActor in
                try? await WindowActivator.enterFullScreen(pid: window.pid, title: window.title, frame: window.frame, order: window.appIndex)
            }
            return
        }
        // "place:2": verilen sıradaki alanın soluna, "place:end": en sağa.
        if parts[0].hasPrefix("place:") {
            // Yalnızca tam ekran pencerenin kendi alanı hedef dışıdır; masaüstü hedef olabilir.
            let spaces = snapshot.spaces.filter { !($0.isFullScreen && $0.id == window.spaceID) }
            let before = Int(parts[0].dropFirst(6)).flatMap { $0 < spaces.count ? spaces[$0].id : nil }
            Task { @MainActor in
                let started = Date()
                self.isPlacingSpace = true
                await self.placeInSpaces(window, before: before, on: screen)
                self.isPlacingSpace = false
                try? String(Date().timeIntervalSince(started)).write(
                    toFile: NSTemporaryDirectory() + "berth-last-place-time.txt", atomically: true, encoding: .utf8
                )
            }
            return
        }
        guard let position = SnapPosition(rawValue: parts[0]) else { return }
        let visible = screen.visibleFrame
        let usable = CGRect(x: visible.minX, y: screen.frame.maxY - visible.maxY, width: visible.width, height: visible.height)
        Task { @MainActor in
            await self.snap(window, to: position.frame(in: usable), label: position.label)
        }
    }
}
#endif

// MARK: - Menü çubuğu menüsü

extension AppController: NSMenuDelegate {
    /// Menü her açılışta yeniden kurulur: izin durumu güncel olsun.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: tx("Aç (\(settings.shortcut.display))", "Open (\(settings.shortcut.display))"), action: #selector(toggleFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: tx("Ayarlar…", "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        // Çalışma düzenleri
        let saveItem = NSMenuItem(title: tx("Çalışma düzenini kaydet…", "Save Workspace Layout…"), action: #selector(saveLayoutFromMenu), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)
        if !layoutStore.layouts.isEmpty {
            let restoreMenu = NSMenu()
            let deleteMenu = NSMenu()
            for layout in layoutStore.layouts {
                let restore = NSMenuItem(title: layout.name, action: #selector(restoreLayoutFromMenu(_:)), keyEquivalent: "")
                restore.target = self
                restore.representedObject = layout.name
                restore.toolTip = tx("\(layout.windows.count) pencere, \(layout.savedAt.formatted(date: .abbreviated, time: .shortened))", "\(layout.windows.count) windows, \(layout.savedAt.formatted(date: .abbreviated, time: .shortened))")
                restoreMenu.addItem(restore)
                let delete = NSMenuItem(title: layout.name, action: #selector(deleteLayoutFromMenu(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = layout.name
                deleteMenu.addItem(delete)
            }
            let restoreItem = NSMenuItem(title: tx("Çalışma düzenini yükle", "Restore Workspace Layout"), action: nil, keyEquivalent: "")
            restoreItem.submenu = restoreMenu
            menu.addItem(restoreItem)
            let deleteItem = NSMenuItem(title: tx("Çalışma düzenini sil", "Delete Workspace Layout"), action: nil, keyEquivalent: "")
            deleteItem.submenu = deleteMenu
            menu.addItem(deleteItem)
        }
        menu.addItem(.separator())

        if settings.windowPreviewsEnabled, !Permissions.screenRecording {
            let item = NSMenuItem(title: tx("Ekran Kaydı iznini ver…", "Grant Screen Recording Access…"), action: #selector(openScreenRecording), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !Permissions.accessibility {
            let item = NSMenuItem(title: tx("Erişilebilirlik iznini ver…", "Grant Accessibility Access…"), action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if (settings.windowPreviewsEnabled && !Permissions.screenRecording) || !Permissions.accessibility {
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: tx("Berth'ten Çık", "Quit Berth"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleFromMenu() { toggle() }

    /// Her düzenin kısayolu ayrı kimlikle kaydedilir (100'den başlar).
    private func registerLayoutHotKeys() {
        layoutHotKeys = []
        for (index, layout) in layoutStore.layouts.enumerated() {
            guard let hotKey = layout.hotKey else { continue }
            let name = layout.name
            if let registered = GlobalHotKey(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers, id: UInt32(100 + index), action: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let current = self.layoutStore.layouts.first(where: { $0.name == name }) else { return }
                    if self.isOpen { self.close(animated: false) }
                    Task { @MainActor [weak self] in await self?.restoreLayout(current) }
                }
            }) {
                layoutHotKeys.append(registered)
            }
        }
    }

    /// Düzen kısayolları geçici olarak bırakılıp denenir; sahne kısayolu ve başka uygulamalar çakışırsa alınamaz.
    private func isHotKeyFree(_ hotKey: WorkspaceLayout.HotKey) -> Bool {
        layoutHotKeys = []
        let free = GlobalHotKey(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers, id: 99) {} != nil
        registerLayoutHotKeys()
        return free
    }

    @objc private func saveLayoutFromMenu() {
        if isOpen { close(animated: false) }
        askAndSaveLayout(store: layoutStore)
    }

    @objc private func restoreLayoutFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let layout = layoutStore.layouts.first(where: { $0.name == name }) else { return }
        if isOpen { close(animated: false) }
        Task { @MainActor [weak self] in await self?.restoreLayout(layout) }
    }

    @objc private func deleteLayoutFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        layoutStore.remove(named: name)
        Toast.show(tx("\(name) silindi.", "\(name) deleted."))
    }
    @objc fileprivate func showSettings() {
        close(animated: false)
        settingsWindow.show()
    }
    @objc private func openScreenRecording() { Permissions.openScreenRecordingSettings() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
