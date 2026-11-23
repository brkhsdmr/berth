import AppKit
import Carbon.HIToolbox
import BerthCore
import ServiceManagement
import SwiftUI
import SystemConfiguration

// MARK: - Model

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    /// V1 ⌥Space'i kullandığı sürece çakışmasın diye varsayılan ⌥⇧Space.
    static let standard = Shortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧Space")
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let dockPreviews = "dockPreviewsEnabled"
        static let shortcut = "shortcut"
        static let fullScreenDock = "fullScreenDockEnabled"
        static let fullScreenDockInWindowsApp = "fullScreenDockInWindowsApp"
        static let fullScreenMenuBarInWindowsApp = "fullScreenMenuBarInWindowsApp"
        static let keepDockOpen = "keepDockOpenDuringPreview"
        static let windowPreviews = "windowPreviewsEnabled"
        static let otherAppsScroll = "otherAppsScrollEnabled"
        static let trackpadGesture = "trackpadGestureEnabled"
        // Tek seçenekli eski sürüm: sahneyi açan parmak sayısı. Açılışta `trackpadGestures`'a taşınır.
        static let trackpadFingers = "trackpadFingers"
        static let trackpadGestures = "trackpadGestures"
        static let hotCorner = "hotCorner"
        static let hotCornerDelay = "hotCornerDelay"
        static let shortcutEnabled = "shortcutEnabled"
        static let remoteBridge = "remoteBridgeEnabled"
        static let remoteToken = "remoteToken"
        static let remoteSessions = "remoteSessionNames"
        static let blockedRemotes = "remoteBlockedNames"
        static let sessionAliases = "remoteSessionAliases"
        static let mouseTune = "mouseTuneEnabled"
        static let mouseProfiles = "mouseProfiles"
        static let edgeSwitch = "edgeSwitchEnabled"
        static let remoteKeyboardLift = "remoteKeyboardLift"
        static let edgeSwitchBand = "edgeSwitchBand"
        static let edgeSwitchHold = "edgeSwitchHoldKeys"
        static let scrollWheel = "scrollWheelLinesEnabled"
        static let scrollLines = "scrollWheelLines"
        // Tek fareli ilk sürüm; açılışta `mouseProfiles`'a taşınır.
        static let mouseName = "mouseTuneName"
        static let mouseSpeed = "mouseTuneSpeed"
        static let mouseAcceleration = "mouseTuneAcceleration"
    }

    @Published var dockPreviewsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(dockPreviewsEnabled, forKey: Key.dockPreviews)
            onDockPreviewsChange?(dockPreviewsEnabled)
        }
    }

    /// Kapalıyken hiç ekran yakalaması yapılmaz ve Ekran Kaydı izni istenmez.
    @Published var windowPreviewsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(windowPreviewsEnabled, forKey: Key.windowPreviews)
            onWindowPreviewsChange?(windowPreviewsEnabled)
        }
    }

    /// Sahnede aşağı kaydırınca sabit olmayan uygulamaların pencereleri kendi hücrelerinde görünür.
    @Published var otherAppsScrollEnabled: Bool {
        didSet { UserDefaults.standard.set(otherAppsScrollEnabled, forKey: Key.otherAppsScroll) }
    }

    /// 3 ve 4 parmakla dikey kaydırmanın işleri (`TrackpadGestureTap`).
    @Published private(set) var trackpadGestures: TrackpadGestureMap
    /// macOS'un o anki trackpad hareketi ayarı (kaydedilmez).
    @Published private(set) var systemGestures = SystemTrackpad.gestures

    /// Bir hücreyi değiştirir ve macOS'un ayarını tabloya en yakın hâle getirir.
    func setGesture(_ action: GestureAction, fingers: Int, direction: SwipeDirection) {
        var next = trackpadGestures
        next[fingers, direction] = action
        trackpadGestures = next
        UserDefaults.standard.set(next.dictionary, forKey: Key.trackpadGestures)
        let equivalent = next.systemEquivalent
        if equivalent != systemGestures { SystemTrackpad.write(equivalent) }
        refreshSystemGestures()
    }

    /// Sistem Ayarları değişmiş olabilir.
    func refreshSystemGestures() {
        let current = SystemTrackpad.gestures
        if current != systemGestures { systemGestures = current }
        onTrackpadGesturesChange?()
    }

    @Published var hotCorner: ScreenCorner {
        didSet {
            UserDefaults.standard.set(hotCorner.rawValue, forKey: Key.hotCorner)
            onHotCornerChange?(hotCorner, hotCornerDelay)
        }
    }

    /// Köşede bu kadar beklenince tetiklenir; kazara değmeleri eler.
    @Published var hotCornerDelay: Double {
        didSet {
            UserDefaults.standard.set(hotCornerDelay, forKey: Key.hotCornerDelay)
            onHotCornerChange?(hotCorner, hotCornerDelay)
        }
    }

    @Published var shortcutEnabled: Bool {
        didSet {
            UserDefaults.standard.set(shortcutEnabled, forKey: Key.shortcutEnabled)
            onShortcutEnabledChange?(shortcutEnabled)
        }
    }

    /// Bu adları taşıyan Windows App oturumlarında hareket Windows'taki sahneye iletilir.
    @Published var remoteSessionNames: String {
        didSet { UserDefaults.standard.set(remoteSessionNames, forKey: Key.remoteSessions) }
    }

    /// Windows'taki uygulamanın bu Mac'e bağlanmasına izin verilir (`RemoteBridge`).
    @Published var remoteBridgeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(remoteBridgeEnabled, forKey: Key.remoteBridge)
            onRemoteBridgeChange?(remoteBridgeEnabled)
        }
    }

    /// Windows'ta girilen eşleştirme kodu.
    @Published private(set) var remoteToken: String
    /// Şu an bağlı Windows bilgisayarları (kaydedilmez).
    @Published var connectedRemotes: [String] = []

    /// Bilgisayar adı (küçük harf) → Windows App'teki oturum adı. Oturum başlığı bilgisayarın
    /// Windows adını taşımıyorsa hareketin hangi bilgisayara gideceği buradan bulunur.
    @Published var remoteSessionAliases: [String: String] {
        didSet { UserDefaults.standard.set(remoteSessionAliases, forKey: Key.sessionAliases) }
    }

    func sessionAlias(for computer: String) -> Binding<String> {
        Binding(
            get: { self.remoteSessionAliases[computer.lowercased()] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                self.remoteSessionAliases[computer.lowercased()] = trimmed.isEmpty ? nil : trimmed
            })
    }

    /// Bağlantısı ayarlardan kesilen Windows bilgisayarları; izin verilene kadar bağlanamaz.
    @Published private(set) var blockedRemotes: [String]

    func disconnectRemote(_ name: String) {
        guard !blockedRemotes.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        setBlockedRemotes(blockedRemotes + [name])
    }

    func allowRemote(_ name: String) {
        setBlockedRemotes(blockedRemotes.filter { $0.caseInsensitiveCompare(name) != .orderedSame })
    }

    private func setBlockedRemotes(_ names: [String]) {
        blockedRemotes = names
        UserDefaults.standard.set(names, forKey: Key.blockedRemotes)
        onBlockedRemotesChange?(names)
    }

    func renewRemoteToken() {
        remoteToken = Self.makeToken()
        UserDefaults.standard.set(remoteToken, forKey: Key.remoteToken)
        onRemoteTokenChange?(remoteToken)
    }

    private static func makeToken() -> String {
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // Karışan 0/O, 1/I yok.
        return String((0..<8).map { _ in letters.randomElement()! })
    }

    var remoteSessionList: [String] {
        remoteSessionNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @Published var fullScreenDockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fullScreenDockEnabled, forKey: Key.fullScreenDock)
            onFullScreenDockChange?(fullScreenDockEnabled)
        }
    }

    /// Windows App tam ekrandayken Dock (Berth'ün şeridi ve macOS'unki) açılsın mı. Kapalıyken
    /// (saptanmış) imleç Dock kenarından uzak tutulur (`FullScreenEdgeGuard`).
    @Published var fullScreenDockInWindowsApp: Bool {
        didSet {
            UserDefaults.standard.set(fullScreenDockInWindowsApp, forKey: Key.fullScreenDockInWindowsApp)
            onWindowsAppEdgesChange?()
        }
    }

    /// Windows App tam ekrandayken imleç üst kenara değince menü çubuğu ve pencere başlığı insin mi.
    @Published var fullScreenMenuBarInWindowsApp: Bool {
        didSet {
            UserDefaults.standard.set(fullScreenMenuBarInWindowsApp, forKey: Key.fullScreenMenuBarInWindowsApp)
            onWindowsAppEdgesChange?()
        }
    }
    var onWindowsAppEdgesChange: (() -> Void)?

    /// Dock otomatik gizliyken önizleme açık kaldıkça Dock gizlenmez.
    @Published var keepDockOpenDuringPreview: Bool {
        didSet { UserDefaults.standard.set(keepDockOpenDuringPreview, forKey: Key.keepDockOpen) }
    }

    /// Harici farede hız ve ivme ayrı (`MouseTuner`). Kapalıyken hiçbir fareye dokunulmaz.
    @Published var mouseTuneEnabled: Bool {
        didSet { UserDefaults.standard.set(mouseTuneEnabled, forKey: Key.mouseTune); onMouseTuneChange?() }
    }
    /// Farenin ürün adı → ayarı. Ayarı olmayan fare macOS'un kendi ayarıyla çalışır.
    @Published var mouseProfiles: [String: MouseProfile] {
        didSet {
            UserDefaults.standard.set(mouseProfiles.mapValues(\.dictionary), forKey: Key.mouseProfiles)
            onMouseTuneChange?()
        }
    }
    /// `MouseTuner`dan (kaydedilmez).
    @Published var connectedMice: [String] = []
    @Published var mouseStatuses: [String: MouseTuner.Status] = [:]

    /// Windows App öndeyken harici klavyelerin macOS niteleme tuşu eşlemesi kalkar (`RemoteKeyboardMapping`).
    @Published var remoteKeyboardLift: Bool {
        didSet { UserDefaults.standard.set(remoteKeyboardLift, forKey: Key.remoteKeyboardLift); onRemoteKeyboardLiftChange?(remoteKeyboardLift) }
    }

    /// İmleç ekranın sol/sağ kenarına değince masaüstü değişir (`EdgeSwitchMonitor`).
    @Published var edgeSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(edgeSwitchEnabled, forKey: Key.edgeSwitch); onEdgeSwitchChange?() }
    }
    /// Geçiş için basılı tutulacak niteleme tuşları; boşsa kenara değmek yeter.
    @Published var edgeSwitchHold: EdgeSwitch.HoldKeys {
        didSet { UserDefaults.standard.set(edgeSwitchHold.rawValue, forKey: Key.edgeSwitchHold); onEdgeSwitchChange?() }
    }
    /// Kenarın dikeyde ortadaki etkin oranı.
    @Published var edgeSwitchBand: Double {
        didSet { UserDefaults.standard.set(edgeSwitchBand, forKey: Key.edgeSwitchBand); onEdgeSwitchChange?() }
    }

    /// Fare tekerleği Windows gibi: her çentik sabit satır (`ScrollWheelTuner`).
    @Published var scrollWheelEnabled: Bool {
        didSet { UserDefaults.standard.set(scrollWheelEnabled, forKey: Key.scrollWheel); onScrollWheelChange?() }
    }
    @Published var scrollLines: Int {
        didSet { UserDefaults.standard.set(scrollLines, forKey: Key.scrollLines); onScrollWheelChange?() }
    }

    var mouseTuneConfig: MouseTuner.Config {
        MouseTuner.Config(enabled: mouseTuneEnabled, profiles: mouseProfiles)
    }

    @Published private(set) var shortcut: Shortcut
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginError: String?

    var onDockPreviewsChange: ((Bool) -> Void)?
    var onWindowPreviewsChange: ((Bool) -> Void)?
    var onTrackpadGesturesChange: (() -> Void)?
    var onHotCornerChange: ((ScreenCorner, Double) -> Void)?
    var onShortcutEnabledChange: ((Bool) -> Void)?
    var onRemoteBridgeChange: ((Bool) -> Void)?
    var onRemoteTokenChange: ((String) -> Void)?
    var onBlockedRemotesChange: (([String]) -> Void)?
    var onFullScreenDockChange: ((Bool) -> Void)?
    var onMouseTuneChange: (() -> Void)?
    var onEdgeSwitchChange: (() -> Void)?
    var onScrollWheelChange: (() -> Void)?
    var onRemoteKeyboardLiftChange: ((Bool) -> Void)?
    /// Kısayol alınabildiyse `true` döner.
    var onShortcutChange: ((Shortcut) -> Bool)?

    init() {
        let defaults = UserDefaults.standard
        dockPreviewsEnabled = defaults.object(forKey: Key.dockPreviews) as? Bool ?? true
        fullScreenDockEnabled = defaults.object(forKey: Key.fullScreenDock) as? Bool ?? true
        fullScreenDockInWindowsApp = defaults.object(forKey: Key.fullScreenDockInWindowsApp) as? Bool ?? false
        fullScreenMenuBarInWindowsApp = defaults.object(forKey: Key.fullScreenMenuBarInWindowsApp) as? Bool ?? false
        keepDockOpenDuringPreview = defaults.object(forKey: Key.keepDockOpen) as? Bool ?? true
        otherAppsScrollEnabled = defaults.object(forKey: Key.otherAppsScroll) as? Bool ?? false
        // Eski açık/kapalı ayarı: kapalıysa kapalı kalır.
        if let saved = defaults.dictionary(forKey: Key.trackpadGestures) as? [String: String] {
            trackpadGestures = TrackpadGestureMap(dictionary: saved)
        } else {
            // İlk açılış ya da eski sürüm: sahne seçilen parmak sayısında, kalanı macOS'un yaptığı.
            let fingers = defaults.object(forKey: Key.trackpadFingers) as? Int
                ?? ((defaults.object(forKey: Key.trackpadGesture) as? Bool ?? true) ? 3 : 0)
            let migrated = TrackpadGestureMap.migrated(sceneFingers: fingers, system: SystemTrackpad.gestures)
            trackpadGestures = migrated
            defaults.set(migrated.dictionary, forKey: Key.trackpadGestures)
        }
        hotCorner = defaults.string(forKey: Key.hotCorner).flatMap(ScreenCorner.init(rawValue:)) ?? .none
        hotCornerDelay = defaults.object(forKey: Key.hotCornerDelay) as? Double ?? 0
        shortcutEnabled = defaults.object(forKey: Key.shortcutEnabled) as? Bool ?? true
        remoteBridgeEnabled = defaults.object(forKey: Key.remoteBridge) as? Bool ?? false
        let token = defaults.string(forKey: Key.remoteToken).flatMap { $0.isEmpty ? nil : $0 } ?? Self.makeToken()
        defaults.set(token, forKey: Key.remoteToken)
        remoteToken = token
        // Varsayılan boş: Windows App yapay değiştirici tuşları iletmiyor (ölçüldü), tuşla yönlendirme
        // çalışmıyor. Ağ üzerinden yönlendirme gelene kadar hareket Mac'te kalır.
        remoteSessionNames = defaults.string(forKey: Key.remoteSessions) ?? ""
        blockedRemotes = defaults.stringArray(forKey: Key.blockedRemotes) ?? []
        remoteSessionAliases = defaults.dictionary(forKey: Key.sessionAliases) as? [String: String] ?? [:]
        mouseTuneEnabled = defaults.object(forKey: Key.mouseTune) as? Bool ?? false
        var profiles = (defaults.dictionary(forKey: Key.mouseProfiles) as? [String: [String: Any]] ?? [:]).mapValues(MouseProfile.init(dictionary:))
        if let name = defaults.string(forKey: Key.mouseName), !name.isEmpty, profiles[name] == nil {
            profiles[name] = MouseProfile(speed: defaults.object(forKey: Key.mouseSpeed) as? Double ?? MouseTune.defaultSpeed,
                                          acceleration: defaults.object(forKey: Key.mouseAcceleration) as? Double ?? MouseTune.defaultAcceleration)
            defaults.set(profiles.mapValues(\.dictionary), forKey: Key.mouseProfiles)
        }
        for key in [Key.mouseName, Key.mouseSpeed, Key.mouseAcceleration] { defaults.removeObject(forKey: key) }
        mouseProfiles = profiles
        edgeSwitchEnabled = defaults.object(forKey: Key.edgeSwitch) as? Bool ?? false
        remoteKeyboardLift = defaults.object(forKey: Key.remoteKeyboardLift) as? Bool ?? false
        edgeSwitchBand = defaults.object(forKey: Key.edgeSwitchBand) as? Double ?? EdgeSwitch.defaultBand
        edgeSwitchHold = EdgeSwitch.HoldKeys(rawValue: defaults.integer(forKey: Key.edgeSwitchHold))
        scrollWheelEnabled = defaults.object(forKey: Key.scrollWheel) as? Bool ?? false
        scrollLines = defaults.object(forKey: Key.scrollLines) as? Int ?? ScrollWheel.defaultLines
        // İlk açılışta izin istenmez: izni zaten verilmişse açık, yoksa kapalı başlar.
        windowPreviewsEnabled = defaults.object(forKey: Key.windowPreviews) as? Bool ?? Permissions.screenRecording
        if let data = defaults.data(forKey: Key.shortcut),
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .standard
        }
    }

    func setShortcut(_ next: Shortcut) -> Bool {
        guard onShortcutChange?(next) ?? false else { return false }
        shortcut = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Key.shortcut)
        }
        return true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Pencere

/// Ayarlar penceresinin düzenler sekmesinden uygulamaya giden istekler.
struct LayoutActions {
    var restore: (WorkspaceLayout) -> Void
    var saveCurrent: () -> Void
    /// Kısayol başka bir yerde (bu uygulama dahil) kullanılmıyorsa true.
    var isHotKeyFree: (WorkspaceLayout.HotKey) -> Bool
}

@MainActor
final class SettingsWindowController {
    private let store: ArrangementStore
    private let settings: AppSettings
    private let layouts: WorkspaceLayoutStore
    private let layoutActions: LayoutActions
    private var window: NSWindow?

    init(store: ArrangementStore, settings: AppSettings, layouts: WorkspaceLayoutStore, layoutActions: LayoutActions) {
        self.store = store
        self.settings = settings
        self.layouts = layouts
        self.layoutActions = layoutActions
    }

    private var closeObserver: NSObjectProtocol?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        // Berth normalde Dock'ta görünmez; ayarlar açıkken başka bir pencereye geçilince pencere
        // arkada kaybolmasın diye Dock'ta ve Cmd-Tab'de görünür, kapanınca eski haline döner.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = Self.makeMainMenu()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Ayarlar açıkken menü çubuğunda görünen kısa menü; düzen menüsü metin alanlarında
    /// kopyala/yapıştır kısayollarının çalışması için gerekli.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tx("Berth'ü Gizle", "Hide Berth"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tx("Berth'ten Çık", "Quit Berth"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tx("Düzen", "Edit"))
        editMenu.addItem(withTitle: tx("Geri Al", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: tx("Yinele", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: tx("Kes", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: tx("Kopyala", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tx("Yapıştır", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: tx("Tümünü Seç", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: tx("Pencere", "Window"))
        windowMenu.addItem(withTitle: tx("Kapat", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: tx("Küçült", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, store: store, layouts: layouts, layoutActions: layoutActions)))
        // Başlık bölümün adıdır (navigationTitle); o gelene kadar boş başlık "Adsız" görünmesin.
        window.title = "Berth"
        // Bölünmüş görünüm araç çubuğunu başlıkla birleştirir: Sistem Ayarları gibi.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.accessory)
                NSApp.mainMenu = nil
            }
        }
        return window
    }
}

// MARK: - Görünüm

/// Ayarların bölümleri: Sistem Ayarları'ndaki gibi solda renkli simgeleriyle.
enum SettingsPage: String, CaseIterable, Identifiable {
    case opening, pinned, layouts, windows, trackpad, mouse, general, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opening: return tx("Açılış", "Opening")
        case .pinned: return tx("Sabit uygulamalar", "Pinned apps")
        case .layouts: return tx("Çalışma düzenleri", "Workspace layouts")
        case .windows: return tx("Windows bağlantısı", "Windows connection")
        case .trackpad: return "Trackpad"
        case .mouse: return tx("Fare ve klavye", "Mouse & keyboard")
        case .general: return tx("Genel", "General")
        case .permissions: return tx("İzinler", "Permissions")
        }
    }

    var symbol: String {
        switch self {
        case .opening: return "rectangle.3.group.fill"
        case .pinned: return "pin.fill"
        case .layouts: return "square.grid.3x2.fill"
        case .windows: return "pc"
        case .trackpad: return "hand.point.up.left.fill"
        case .mouse: return "keyboard.fill"
        case .general: return "gearshape.fill"
        case .permissions: return "lock.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .opening: return .blue
        case .pinned: return .orange
        case .layouts: return .purple
        case .windows: return .teal
        case .trackpad: return .green
        case .mouse: return .pink
        case .general: return .gray
        case .permissions: return .indigo
        }
    }
}

extension Notification.Name {
    /// Ayarlarda bir bölümü açar; nesne `SettingsPage.rawValue`.
    static let showSettingsPage = Notification.Name("berth.showSettingsPage")
}

private struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ArrangementStore
    @ObservedObject var layouts: WorkspaceLayoutStore
    let layoutActions: LayoutActions
    @State private var page: SettingsPage = .opening

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { item in
                Label {
                    Text(item.title)
                } icon: {
                    SidebarIcon(symbol: item.symbol, tint: item.tint)
                }
                .tag(item)
            }
            .frame(minWidth: 230)
            .navigationSplitViewColumnWidth(min: 230, ideal: 240, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            content
                .navigationTitle(page.title)
        }
        .frame(width: 820, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsPage)) { note in
            if let raw = note.object as? String, let next = SettingsPage(rawValue: raw) { page = next }
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .opening: OpenTab(settings: settings)
        case .pinned: ArrangementTab(store: store)
        case .layouts: LayoutsTab(layouts: layouts, actions: layoutActions)
        case .windows: WindowsTab(settings: settings)
        case .trackpad: TrackpadTab(settings: settings)
        case .mouse: MouseTab(settings: settings)
        case .general: UsageTab(settings: settings)
        case .permissions: PermissionsTab(settings: settings)
        }
    }
}

/// Sistem Ayarları'ndaki gibi renkli kare içinde beyaz simge.
private struct SidebarIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 22, height: 22)
            .overlay(Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
    }
}

/// Ekran köşesi seçici: küçük bir ekran çizimi, köşesine tıklayınca seçilir; seçili köşeye
/// yeniden tıklamak kapatır.
private struct HotCornerPicker: View {
    @Binding var corner: ScreenCorner

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.secondary.opacity(0.6), lineWidth: 1.5))
                    .overlay(alignment: .top) {
                        Rectangle().fill(.secondary.opacity(0.18)).frame(height: 9).clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
                    }
                    .overlay(alignment: .bottom) {
                        Capsule().fill(.secondary.opacity(0.25)).frame(width: 70, height: 8).padding(.bottom, 6)
                    }
                    .frame(width: 168, height: 100)
                ForEach([ScreenCorner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { item in
                    dot(item)
                        .offset(x: item == .topLeft || item == .bottomLeft ? -84 : 84,
                                y: item == .topLeft || item == .topRight ? -50 : 50)
                }
            }
            .frame(width: 190, height: 122)
            Text(corner.label).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func dot(_ item: ScreenCorner) -> some View {
        let on = corner == item
        return Button {
            corner = on ? .none : item
        } label: {
            Circle()
                .fill(on ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                .overlay(Circle().strokeBorder(on ? Color.accentColor : .secondary, lineWidth: 1.5))
                .frame(width: 18, height: 18)
                .contentShape(Circle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .help(item.label)
    }
}

private struct OpenTab: View {
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var shortcutMessage: String?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                Toggle(tx("Klavye kısayoluyla aç", "Open with a keyboard shortcut"), isOn: $settings.shortcutEnabled)
                LabeledContent(tx("Kısayol", "Shortcut")) {
                    HStack(spacing: 8) {
                        Text(recording ? tx("Bir kısayola basın…", "Press a shortcut…") : settings.shortcut.display)
                            .monospacedDigit()
                            .foregroundStyle(recording ? .secondary : .primary)
                        Button(recording ? tx("Vazgeç", "Cancel") : tx("Değiştir", "Change")) { toggleRecording() }
                    }
                }
                .disabled(!settings.shortcutEnabled)
                if let shortcutMessage {
                    Text(shortcutMessage).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text(tx("Klavye", "Keyboard"))
            } footer: {
                Text(tx("Aynı kısayol sahne açıkken kapatır. Menü çubuğu simgesine tıklamak da açar ya da kapatır.", "The same shortcut closes the scene when it's open. Clicking the menu bar icon also opens or closes it."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(tx("Sahneyi açan hareket", "Gesture that opens the scene")) {
                    HStack(spacing: 8) {
                        Text(sceneGestureSummary).foregroundStyle(.secondary)
                        Button(tx("Değiştir", "Change")) {
                            NotificationCenter.default.post(name: .showSettingsPage, object: SettingsPage.trackpad.rawValue)
                        }
                    }
                }
            } header: {
                Text("Trackpad")
            }

            Section {
                HStack {
                    Spacer()
                    HotCornerPicker(corner: $settings.hotCorner)
                    Spacer()
                }
                Picker(tx("Köşede bekleme", "Delay in corner"), selection: $settings.hotCornerDelay) {
                    Text(tx("Hemen", "Immediately")).tag(0.0)
                    Text(tx("0,25 sn", "0.25 s")).tag(0.25)
                    Text(tx("0,5 sn", "0.5 s")).tag(0.5)
                    Text(tx("1 sn", "1 s")).tag(1.0)
                }
                .disabled(settings.hotCorner == .none)
                if let conflict = HotCornerMonitor.systemAction(at: settings.hotCorner) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(tx("macOS bu köşeye \(conflict) atamış; ikisi birlikte açılır. Sistem Ayarları > Masaüstü ve Dock > Sıcak Köşeler'den kaldırabilirsiniz.", "macOS has assigned \(conflict) to this corner; both will open. You can remove it in System Settings > Desktop & Dock > Hot Corners."))
                            .font(.callout)
                        Spacer()
                        Button(tx("Aç", "Open")) { SystemTrackpad.openHotCornerSettings() }
                    }
                }
            } header: {
                Text(tx("Sıcak köşe", "Hot corner"))
            } footer: {
                Text(tx("Köşeye tıklayarak seç; seçili köşeye yeniden tıklamak kapatır. İmleç köşeye gelince sahne açılır, açıksa kapanır. Fare düğmesi basılıyken tetiklenmez.", "Click a corner to choose it; click the chosen corner again to turn it off. Moving the pointer into the corner opens the scene, or closes it if open. Not triggered while a mouse button is held."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private var sceneGestureSummary: String {
        let cells = TrackpadGestureMap.fingerCounts.flatMap { fingers in
            SwipeDirection.allCases.compactMap { direction in
                settings.trackpadGestures[fingers, direction] == .scene ? TrackpadTab.gestureName(fingers: fingers, direction: direction) : nil
            }
        }
        return cells.isEmpty ? tx("Yok", "None") : cells.joined(separator: ", ")
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
            return
        }
        shortcutMessage = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return
        }
        let flags = event.modifierFlags
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        guard ShortcutFormat.isAcceptable(control: control, option: option, shift: shift, command: command) else {
            shortcutMessage = tx("Kısayolda ⌃, ⌥ ya da ⌘ tuşlarından biri olmalı.", "A shortcut needs ⌃, ⌥ or ⌘.")
            return
        }

        var carbon = 0
        if control { carbon |= controlKey }
        if option { carbon |= optionKey }
        if shift { carbon |= shiftKey }
        if command { carbon |= cmdKey }

        let key = Int(event.keyCode) == kVK_Space
            ? "Space"
            : (event.charactersIgnoringModifiers ?? "").uppercased(with: Locale(identifier: "tr_TR"))
        let next = Shortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: UInt32(carbon),
            display: ShortcutFormat.display(control: control, option: option, shift: shift, command: command, key: key)
        )
        stopRecording()
        if !settings.setShortcut(next) {
            shortcutMessage = tx("\(next.display) başka bir uygulamada kullanılıyor.", "\(next.display) is used by another app.")
        }
    }
}

private struct WindowsTab: View {
    @ObservedObject var settings: AppSettings

    private var macName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    /// Tailscale'i olmayan bilgisayarlar için: `<yerel ad>.local` ve yerel ağ IP adresleri.
    private var localAddresses: [String] {
        let bonjour = SCDynamicStoreCopyLocalHostName(nil).map { "\($0 as String).local" }
        return (bonjour.map { [$0] } ?? []) + RemoteBridge.localAddresses()
    }
    private var connected: Bool { settings.remoteBridgeEnabled && !settings.connectedRemotes.isEmpty }
    private var statusColor: Color { connected ? .green : settings.remoteBridgeEnabled ? .orange : .secondary }
    private var statusLabel: String { connected ? tx("Bağlı", "Connected") : settings.remoteBridgeEnabled ? tx("Bekleniyor", "Waiting") : tx("Kapalı", "Off") }
    private var statusDetail: String {
        if connected { return settings.connectedRemotes.joined(separator: ", ") }
        if !settings.trackpadGestures.opensScene { return tx("Trackpad'de sahneyi açan hareket yok; önce Trackpad sayfasında birini seçin.", "No trackpad gesture opens the scene; choose one on the Trackpad page first.") }
        return settings.remoteBridgeEnabled ? tx("Windows'taki uygulamanın bağlanması bekleniyor.", "Waiting for Berth on Windows to connect.") : tx("Windows'a hareket gönderilmiyor.", "Gestures aren't sent to Windows.")
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    SidebarIcon(symbol: "pc", tint: .teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tx("Durum", "Status"))
                        Text(statusDetail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusLabel).font(.callout)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(statusColor.opacity(0.8), lineWidth: 1))
                }
            }
            Section {
                Toggle(tx("Windows App oturumunda hareketi Windows'a gönder", "Send the gesture to Windows in Windows App sessions"), isOn: $settings.remoteBridgeEnabled)
                    .disabled(!settings.trackpadGestures.opensScene)
                Toggle(tx("Windows App öndeyken harici klavyelerin niteleme tuşu eşlemesini kaldır", "Lift external keyboards' modifier key mapping while Windows App is in front"),
                       isOn: $settings.remoteKeyboardLift)
                Text(tx("Windows klavyesinde macOS için yapılan eşleme (Ctrl → ⌘ gibi) uzak masaüstünde kalkar, tuşlar karşıya kendi adlarıyla gider. Windows App arkaya geçince eşleme geri gelir. Dahili klavyeye dokunulmaz.",
                        "A Mac mapping on a Windows keyboard (like Ctrl → ⌘) is lifted in the remote desktop, so keys reach Windows as labeled. It comes back when Windows App moves to the background. The built-in keyboard isn't touched."))
                    .font(.callout).foregroundStyle(.secondary)
                if settings.remoteBridgeEnabled {
                    if !settings.remoteSessionNames.isEmpty {
                        TextField(tx("Oturum adları", "Session names"), text: $settings.remoteSessionNames, prompt: Text(tx("Boşsa: bu Mac'e bağlı Windows'larla eşleşen oturumlar", "If empty: sessions matching a Windows PC connected to this Mac")))
                    }
                    LabeledContent(tx("Bu Mac'in adı", "This Mac's name")) {
                        HStack(spacing: 6) {
                            Text(macName).textSelection(.enabled)
                            CopyButton(value: macName)
                        }
                    }
                    LabeledContent(tx("Eşleştirme kodu", "Pairing code")) {
                        HStack(spacing: 8) {
                            Text(settings.remoteToken).font(.body.monospaced()).textSelection(.enabled)
                            CopyButton(value: settings.remoteToken)
                            Button(tx("Yenile", "Renew")) { settings.renewRemoteToken() }
                        }
                    }
                    LabeledContent(tx("Yerel ağ adresi", "Local network address")) {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(localAddresses, id: \.self) { address in
                                HStack(spacing: 6) {
                                    Text(address).font(.body.monospaced()).textSelection(.enabled)
                                    CopyButton(value: address)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(tx("Uzak masaüstü (Windows)", "Remote desktop (Windows)"))
            } footer: {
                Text(tx("Windows'taki Berth ayarlarına bu Mac'in adını ve kodu girin; bağlantıyı Windows'taki uygulama kurar. Ad bulunamıyorsa ya da bir VPN kullanıyorsanız, aynı ağdaki veya aynı modeme bağlı bilgisayardan bağlanmak için Mac'in adı yerine yerel ağ adresini (.local ya da IP) yazın. Birden çok Windows aynı kodla bağlanabilir. Windows App'te o oturum öndeyken yukarı kaydırma oradaki sahneyi açar ya da kapatır. Uygulamanın kurulu olmadığı oturumlarda Mac'in sahnesi açılır.", "Enter this Mac's name and the code in Berth's settings on Windows; the PC makes the connection. If the name can't be found or you use a VPN, enter the local network address (.local or IP) instead of the Mac's name to connect from a PC on the same network or router. Several Windows PCs can connect with the same code. While that session is in front in Windows App, swiping up opens or closes the scene there. In sessions without Berth, the Mac's scene opens."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if settings.remoteBridgeEnabled {
                Section {
                    if settings.connectedRemotes.isEmpty && settings.blockedRemotes.isEmpty {
                        Text(tx("Bağlı Windows yok", "No Windows connected")).foregroundStyle(.secondary)
                    }
                    ForEach(settings.connectedRemotes, id: \.self) { name in
                        LabeledContent {
                            HStack(spacing: 8) {
                                TextField("", text: settings.sessionAlias(for: name), prompt: Text(tx("Windows App oturum adı", "Windows App session name")))
                                    .labelsHidden()
                                    .frame(width: 190)
                                    .help(tx("Windows App'teki oturum başlığı bu bilgisayarın adını taşımıyorsa buraya yazın.", "If the session title in Windows App doesn't include this PC's name, enter it here."))
                                Button(tx("Bağlantıyı kes", "Disconnect")) { settings.disconnectRemote(name) }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(.green).frame(width: 7, height: 7)
                                Text(name)
                            }
                        }
                    }
                    ForEach(settings.blockedRemotes, id: \.self) { name in
                        LabeledContent {
                            Button(tx("İzin ver", "Allow")) { settings.allowRemote(name) }
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(.secondary).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(name)
                                    Text(tx("Bağlantısı kesildi", "Disconnected")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(tx("Bağlı bilgisayarlar", "Connected PCs"))
                } footer: {
                    Text(tx("Hareket, Windows App'te öndeki oturumun başlığı bilgisayarın adını ya da yanına yazılan oturum adını taşıyorsa o bilgisayara gider. Bağlantısı kesilen bilgisayar, izin verilene kadar yeniden bağlanamaz; kodu yenilemek tüm bilgisayarların bağlantısını keser.", "The gesture goes to a PC when the title of the session in front in Windows App includes the PC's name or the session name entered next to it. A disconnected PC can't reconnect until you allow it again; renewing the code disconnects every PC."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
    }
}

/// Değeri panoya kopyalayan küçük simge; kopyalanınca kısa süre onay işareti gösterir.
private struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tx("Kopyala", "Copy"))
        .accessibilityLabel(tx("Kopyala", "Copy"))
    }
}

private struct UsageTab: View {
    @ObservedObject var settings: AppSettings
    @AppStorage("language") private var language = L10n.Language.automatic.rawValue
    @State private var languageAtLaunch = UserDefaults.standard.integer(forKey: "language")

    /// Uygulamanın yeni bir kopyasını açıp bu kopyayı kapatır.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–" }

    var body: some View {
        Form {
            Section {
                Picker(tx("Dil", "Language"), selection: $language) {
                    Text(tx("Sistem dili", "System language")).tag(L10n.Language.automatic.rawValue)
                    Text("Türkçe").tag(L10n.Language.turkish.rawValue)
                    Text("English").tag(L10n.Language.english.rawValue)
                }
                if language != languageAtLaunch {
                    HStack {
                        Text(tx("Yeni dil Berth yeniden başlatılınca geçerli olur.", "The new language takes effect after Berth restarts."))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(tx("Şimdi yeniden başlat", "Restart now")) { Self.relaunch() }
                    }
                }
            }
            Section {
                Toggle(tx("Pencerelerin gerçek görüntüsünü göster", "Show live window previews"), isOn: $settings.windowPreviewsEnabled)
                Text(settings.windowPreviewsEnabled
                     ? tx("Ekran Kaydı izni gerekir. Görüntüler yalnızca sahne ya da Dock önizlemesi açılınca alınır; macOS bu sırada kayıt göstergesini gösterebilir.", "Needs Screen Recording access. Images are captured only while the scene or a Dock preview is open; macOS may show its recording indicator then.")
                     : tx("Hiç ekran yakalaması yapılmaz; izin daha önce verilmiş olsa bile kullanılmaz. Pencereler simge ve başlıkla gösterilir. Başka masaüstündeki pencerelerin başlığı görünmeyebilir.", "Nothing on screen is captured, even if access was granted before. Windows are shown with their icon and title. Titles of windows on other desktops may not be available."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(tx("Pencere önizlemeleri", "Window previews"))
            }
            Section(tx("Sahne", "Scene")) {
                Toggle(tx("Aşağı kaydırınca diğer uygulamaların pencerelerini göster", "Show other apps' windows when scrolling down"), isOn: $settings.otherAppsScrollEnabled)
                Text(tx("Sabit olmayan uygulamalar sahnenin altında kendi hücreleri ve önizlemeleriyle listelenir. Kapalıyken yalnızca alt sıradaki çipler görünür.", "Apps you haven't pinned are listed below the scene with their own cells and previews. When off, only the row of chips at the bottom is shown."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Dock") {
                Toggle(tx("Dock simgesinin üstüne gelince pencereleri göster", "Show windows when hovering a Dock icon"), isOn: $settings.dockPreviewsEnabled)
                Text(tx("Uygulamanın tüm masaüstlerindeki pencereleri simgenin yanında önizlenir.", "The app's windows on every desktop are previewed next to the icon."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(tx("Önizleme açıkken Dock gizlenmesin", "Keep the Dock visible while a preview is open"), isOn: $settings.keepDockOpenDuringPreview)
                    .disabled(!settings.dockPreviewsEnabled)
                Text(tx("Dock otomatik gizliyse önizlemeye geçince de açık kalır. Bunun için macOS'un otomatik gizleme ayarı önizleme süresince kapatılıp sonra geri açılır.", "If the Dock hides automatically, it stays visible while you move into the preview. To do this, macOS's auto-hide setting is turned off for the preview and turned back on afterwards."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(tx("Tam ekranda kenara değince Dock şeridini aç", "Show a Dock strip at the screen edge in full screen"), isOn: $settings.fullScreenDockEnabled)
                    .disabled(!settings.dockPreviewsEnabled)
                Text(tx("macOS tam ekranda Dock'u her zaman açmıyor. Şerit, Dock'un olduğu kenarda aynı uygulamaları gösterir.", "macOS doesn't always show the Dock in full screen. The strip shows the same apps on the Dock's edge."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(tx("Windows App tam ekrandayken Dock'u göster", "Show the Dock while Windows App is in full screen"), isOn: $settings.fullScreenDockInWindowsApp)
                Text(tx("Kapalıyken Windows App tam ekrandayken ne Berth'ün şeridi ne macOS'un Dock'u açılır: imleç Dock'un kenarından bir nokta içeride tutulur, kenar Windows'ta kalır. Windows'ta görev çubuğu aynı kenarda ve otomatik gizliyse oradan açılmayabilir.", "When off, neither Berth's strip nor the macOS Dock opens while Windows App is in full screen: the pointer is kept a point away from the Dock's edge, so the edge stays with Windows. If the Windows taskbar hides automatically on the same edge, it may not open from there."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(tx("Windows App tam ekrandayken menü çubuğunu göster", "Show the menu bar while Windows App is in full screen"), isOn: $settings.fullScreenMenuBarInWindowsApp)
                Text(tx("Kapalıyken imleç üst kenara değince macOS'un menü çubuğu ve Windows App'in başlığı inmez; imleç üst kenardan birkaç nokta aşağıda tutulur. Köşeler serbesttir, sıcak köşe çalışır. Menü çubuğuna ihtiyaç olursa Windows App'i tam ekrandan çıkarmak yeter.", "When off, the macOS menu bar and Windows App's title don't slide down when the pointer reaches the top edge; the pointer is kept a few points below it. Corners stay free, so hot corners still work. If you need the menu bar, take Windows App out of full screen."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section(tx("Başlangıç", "Startup")) {
                Toggle(tx("Oturum açıldığında başlat", "Open at login"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Berth").font(.headline)
                        Text(tx("Sürüm \(Self.version) · Masaüstleri ve pencereler için sabit yerleşimli sahne",
                                 "Version \(Self.version) · A fixed-layout overview of your desktops and windows"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Kenar geçişi için basılı tutulacak niteleme tuşları: kaydederken tuşlara basılıp bırakılır.
private struct EdgeHoldRecorder: View {
    @Binding var hold: EdgeSwitch.HoldKeys
    @State private var recording = false
    @State private var captured = EdgeSwitch.HoldKeys()
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(tx("Basılı tutulacak tuş", "Key to hold")) {
                HStack(spacing: 8) {
                    Text(recording ? (captured.isEmpty ? tx("Tuşlara basın…", "Press the keys…") : captured.display)
                                   : (hold.isEmpty ? tx("Yok", "None") : hold.display))
                        .foregroundStyle(recording || hold.isEmpty ? .secondary : .primary)
                    Button(recording ? tx("Vazgeç", "Cancel") : tx("Kaydet", "Record")) { recording ? stop() : start() }
                    if !hold.isEmpty, !recording {
                        Button(tx("Kaldır", "Remove")) { hold = [] }
                    }
                }
            }
            Text(hold.isEmpty
                 ? tx("Tuş seçilmezse kenara değmek yeter. Bir tuş seçilirse yalnızca o tuş basılıyken geçilir (⌃, ⌥, ⇧, ⌘, fn ya da birlikte).",
                      "With no key, touching the edge is enough. With a key, you switch only while holding it (⌃, ⌥, ⇧, ⌘, fn or a combination).")
                 : tx("\(hold.display) basılıyken imleci kenara dayayın; tuşa kenarda beklerken basmak da geçirir.",
                      "Hold \(hold.display) and push the pointer against the edge; pressing it while waiting at the edge works too."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        captured = []
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if Int(event.keyCode) == kVK_Escape { stop() }
                return nil
            }
            let now = EdgeSwitchMonitor.pressedKeys
            if now.isEmpty {
                // Tümü bırakılınca o ana kadar birlikte basılanlar kaydedilir.
                if !captured.isEmpty { hold = captured }
                stop()
            } else {
                captured.formUnion(now)
            }
            return event
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Klavyelerin niteleme tuşları için hazır ayarlar. macOS'un kendi ayarına yazılır (Niteleme Tuşları).
private struct KeyboardSections: View {
    @State private var keyboards: [KeyboardModifiers.Keyboard] = []
    @State private var mappings: [String: Set<ModifierPair>] = [:]

    var body: some View {
        Section {
            if keyboards.isEmpty {
                Text(tx("Bağlı klavye bulunamadı.", "No keyboard found.")).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(keyboards) { keyboard in
                let preset = keyboard.builtIn ? ModifierPreset.macWindowsLike : ModifierPreset.windowsKeyboard
                let current = mappings[keyboard.id] ?? []
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { current == preset }, set: { on in
                        KeyboardModifiers.setMapping(on ? preset : [], for: keyboard)
                        reload()
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(keyboard.name)
                            Text(keyboard.builtIn
                                 ? tx("Windows'a yakın: Kontrol → Dünya, Komut → Kontrol, Dünya → Komut. Boşluğun yanındaki tuş Ctrl gibi çalışır.",
                                      "Windows-like: Control → Globe, Command → Control, Globe → Command. The key next to the space bar works like Ctrl.")
                                 : tx("Windows klavyesi: Ctrl → ⌘, Windows → ⌥, Alt → ⌃. Alt sıra Windows'taki gibi çalışır.",
                                      "Windows keyboard: Ctrl → ⌘, Windows → ⌥, Alt → ⌃. The bottom row works as it does on Windows."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !current.isEmpty, current != preset {
                        Text(tx("Bu klavyede Sistem Ayarları'nda başka bir eşleme var; açmak onun yerine geçer.",
                                "This keyboard has a different mapping in System Settings; turning this on replaces it."))
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text(tx("Klavye", "Keyboard"))
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text(tx("macOS'un Niteleme Tuşları ayarına yazılır; Sistem Ayarları'nda da görünür ve Berth kapalıyken de geçerlidir. Kapatmak o klavyeyi macOS'un saptanmışına döndürür. Windows App öndeyken harici klavyelerin eşlemesi Windows bağlantısı sayfasından kaldırılabilir.",
                        "Written to macOS's Modifier Keys setting; it shows in System Settings and stays in effect without Berth. Turning it off returns that keyboard to macOS's defaults. External keyboard mappings can be lifted while Windows App is in front on the Windows connection page."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(tx("Niteleme Tuşları", "Modifier Keys")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        keyboards = KeyboardModifiers.connected()
        mappings = Dictionary(uniqueKeysWithValues: keyboards.map { ($0.id, KeyboardModifiers.mapping(for: $0)) })
    }
}

/// 3 ve 4 parmakla dikey kaydırmanın işleri. macOS'un kendi hareket ayarı da tabloya göre yazılır.
private struct TrackpadTab: View {
    @ObservedObject var settings: AppSettings

    static func gestureName(fingers: Int, direction: SwipeDirection) -> String {
        direction == .up ? tx("\(fingers) parmak yukarı", "\(fingers) fingers up") : tx("\(fingers) parmak aşağı", "\(fingers) fingers down")
    }

    var body: some View {
        Form {
            Section {
                Text(tx("Trackpad'de üç ya da dört parmakla yukarı ve aşağı kaydırmanın ne yapacağını seçin. macOS'un kendi hareketi de bu tabloya göre ayarlanır; Sistem Ayarları her hareket için tek parmak sayısı gösterebildiğinden orada eksik görünebilir, geçerli olan bu tablodur.",
                        "Choose what swiping up and down with three or four fingers does. macOS's own gesture setting is updated to match; System Settings can show only one finger count per gesture, so it may look incomplete there, but this table is what applies."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(TrackpadGestureMap.fingerCounts, id: \.self) { fingers in
                Section(tx("\(fingers) parmak", "\(fingers) fingers")) {
                    ForEach(SwipeDirection.allCases, id: \.self) { direction in
                        Picker(direction == .up ? tx("Yukarı kaydırma", "Swipe up") : tx("Aşağı kaydırma", "Swipe down"), selection: Binding(
                            get: { settings.trackpadGestures[fingers, direction] },
                            set: { settings.setGesture($0, fingers: fingers, direction: direction) })) {
                            ForEach(GestureAction.allCases, id: \.self) { action in
                                Text(action.label).tag(action)
                            }
                        }
                    }
                    if fingers == 3, SystemTrackpad.threeFingerDrag {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(tx("Üç parmakla sürükleme açık: macOS üç parmak kaydırmalarını kullanmaz, Berth yine tanır ama sürüklerken de tetiklenebilir.",
                                    "Three-finger drag is on: macOS doesn't use three-finger swipes; Berth still recognizes them, but they may also fire while dragging."))
                                .font(.callout)
                        }
                    }
                }
            }
            Section {
                Text(tx("Mission Control ve App Exposé macOS'un hareketi açıksa parmağı izleyen kendi animasyonuyla açılır; değilse Berth açar. Sahne açıkken aşağı kaydırma sahneyi kapatır. Berth kapalıyken Berth sahnesi seçilen hareket macOS'un kendi işini yapar (yukarı Mission Control, aşağı App Exposé). Windows App oturumundayken (Windows bağlantısı) sahne ve uygulama pencereleri o bilgisayarda açılır.",
                        "Mission Control and App Exposé open with macOS's own finger-tracking animation when macOS's gesture is on; otherwise Berth opens them. While the scene is open, swiping down closes it. When Berth isn't running, the gesture set to Berth scene does macOS's own action (up: Mission Control, down: App Exposé). In a Windows App session (Windows connection), the scene and app windows open on that PC."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(tx("Sistem Ayarları'nda Trackpad", "Trackpad in System Settings")) { SystemTrackpad.openTrackpadSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshSystemGestures() }
    }
}

/// Harici fare: hız ve ivme ayrı, her fareye kendi ayarı (`MouseTuner`).
private struct MouseTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(tx("Harici farelerde hızı ve ivmeyi ayrı ayarla", "Set speed and acceleration separately for external mice"),
                       isOn: Binding(get: { settings.mouseTuneEnabled }, set: { enabled in
                           // İlk açılışta tek fare varsa onun ayarı da açılsın.
                           if enabled, settings.mouseProfiles.isEmpty, settings.connectedMice.count == 1 {
                               settings.mouseProfiles[settings.connectedMice[0]] = .suggested
                           }
                           settings.mouseTuneEnabled = enabled
                       }))
                Text(tx("macOS'ta izleme hızını artırmak ivmeyi de dikleştirir: kısa harekette imleç durgun kalır, hızlı harekette fırlar. Burada ikisi ayrı, Windows'taki \"İşaretçi hassasiyetini artır\" hissine yakın: hız kısa mesafeyi, ivme uzun ve hızlı hareketi belirler. Her farenin ayarı ayrı saklanır; trackpad etkilenmez.",
                        "On macOS, raising the tracking speed also steepens acceleration: the pointer feels sluggish on short moves and jumps on fast ones. Here the two are separate, closer to Windows' \"Enhance pointer precision\": speed sets short moves, acceleration sets long, fast ones. Each mouse keeps its own setting; the trackpad isn't affected."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if mice.isEmpty {
                Section {
                    Text(tx("Bağlı harici fare yok. Bir fare bağlanınca burada görünür.", "No external mouse connected. A mouse shows up here when it connects."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(mice, id: \.self) { name in
                MouseProfileSection(settings: settings, name: name)
            }
            Section(tx("Fare tekerleği", "Mouse wheel")) {
                Toggle(tx("Tekerleği Windows gibi kaydır", "Scroll the wheel like Windows"), isOn: $settings.scrollWheelEnabled)
                Stepper(value: $settings.scrollLines, in: ScrollWheel.lineRange) {
                    Text(tx("Çentik başına \(settings.scrollLines) satır", "\(settings.scrollLines) lines per notch"))
                }
                .disabled(!settings.scrollWheelEnabled)
                Text(tx("macOS tekerleğe ivme uygular: yavaş çevrilen çentik çok az kaydırır, hızlı çevirdikçe artar. Açıkken her çentik Windows'taki gibi sabit sayıda satır kaydırır (Windows'un varsayılanı 3), yumuşak akar; tekerleği hızlı çevirdikçe çentik başına mesafe 4 katına kadar büyür. Tüm harici farelerde geçerli; trackpad ve Magic Mouse değişmez. Windows App öndeyken tekerleğe dokunulmaz. Erişilebilirlik izni gerekir.",
                        "macOS accelerates the wheel: a slowly turned notch scrolls very little, more the faster you turn. When on, every notch scrolls a fixed number of lines as on Windows (Windows' default is 3) and glides smoothly; spinning the wheel faster makes each notch go up to 4 times further. Applies to all external mice; the trackpad and Magic Mouse are unchanged. The wheel is left alone while Windows App is in front. Needs Accessibility access."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(tx("Kenar geçişi", "Edge switching")) {
                Toggle(tx("İmleç sol ya da sağ kenara değince masaüstünü değiştir", "Switch desktops when the pointer hits the left or right edge"),
                       isOn: $settings.edgeSwitchEnabled)
                Picker(tx("Kenarın etkin bölümü", "Active part of the edge"), selection: $settings.edgeSwitchBand) {
                    ForEach(EdgeSwitch.bandChoices, id: \.self) { ratio in
                        Text(ratio >= 1 ? tx("Tamamı", "All of it") : tx("Ortadaki %\(Int(ratio * 100))", "Middle \(Int(ratio * 100))%")).tag(ratio)
                    }
                }
                .disabled(!settings.edgeSwitchEnabled)
                EdgeHoldRecorder(hold: $settings.edgeSwitchHold)
                    .disabled(!settings.edgeSwitchEnabled)
                Text(tx("İmleç ekranın sol kenarına değince bir masaüstü sola, sağ kenarına değince sağa geçilir. Yalnızca dış kenarlar: yanında başka ekran olan kenar sayılmaz. Fare düğmesi basılıyken (pencere sürüklerken, boyutlandırırken) ve sahne açıkken tetiklenmez; yeniden geçmek için imleci kenardan biraz ayırın. Fare ve trackpad için geçerli, Erişilebilirlik izni gerekir.",
                        "When the pointer touches the left edge of the screen you move one desktop left; the right edge, one desktop right. Outer edges only: an edge next to another display doesn't count. Not triggered while a mouse button is held (dragging or resizing a window) or while the scene is open; move the pointer off the edge to switch again. Works with mouse and trackpad; needs Accessibility access."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            KeyboardSections()
            Section {
                Text(tx("Berth önerisi: hız 2×, ivme 3. Windows'ta \"İşaretçi hassasiyetini artır\" açık ve hız en yüksekteyken alınan hisse göre seçildi; kişisel ayarın değil, başlangıç noktası. macOS değerleri: hız 1× ve Sistem Ayarları > Fare'deki izleme hızı ivme olarak; fare macOS'taki gibi hissettirir, oradan ayarlamaya başlanabilir. Sistem Ayarları'nda imleç ivmesi açık kalmalı.",
                        "Berth's suggestion: speed 2×, acceleration 3, chosen to match Windows with \"Enhance pointer precision\" on and the speed at maximum; a starting point, not your personal setting. macOS values: speed 1× and the tracking speed from System Settings > Mouse as acceleration; the mouse feels as it does on macOS and you can tune from there. Keep pointer acceleration on in System Settings."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Bağlı fareler, ardından ayarı kayıtlı ama bağlı olmayanlar.
    private var mice: [String] {
        settings.connectedMice + settings.mouseProfiles.keys.filter { !settings.connectedMice.contains($0) }.sorted()
    }
}

private struct MouseProfileSection: View {
    @ObservedObject var settings: AppSettings
    let name: String
    // Kaydırıcı sürüklenirken her adımda hidutil çalışmasın: bırakınca uygulanır.
    @State private var speed = MouseTune.defaultSpeed
    @State private var acceleration = MouseTune.defaultAcceleration

    private var profile: MouseProfile? { settings.mouseProfiles[name] }
    private var active: Bool { settings.mouseTuneEnabled && profile?.enabled == true }
    private var connected: Bool { settings.connectedMice.contains(name) }

    var body: some View {
        Section {
            Toggle(tx("Bu farede Berth ayarını kullan", "Use Berth's setting for this mouse"), isOn: Binding(
                get: { profile?.enabled == true },
                set: { enabled in update { $0.enabled = enabled } }))
                .disabled(!settings.mouseTuneEnabled)
            if let status = settings.mouseStatuses[name] {
                Text(status.text).font(.callout)
                    .foregroundStyle(status == .applied || status == .appliedFlat ? Color.accentColor : .secondary)
            }
            slider(tx("Hız", "Speed"), value: $speed, range: MouseTune.speedRange, label: String(format: "%.2f×", speed)) {
                update { $0.speed = speed }
            }
            slider(tx("İvme", "Acceleration"), value: $acceleration, range: MouseTune.accelerationRange,
                   label: String(format: "%.2f", acceleration)) {
                update { $0.acceleration = acceleration }
            }
            HStack {
                Button(tx("Berth önerisi", "Berth's suggestion")) { set(.suggested) }
                Button(tx("macOS değerleri", "macOS values")) { set(.system(scaling: MouseTuner.systemScaling)) }
                Spacer()
                if !connected {
                    Button(tx("Bu fareyi unut", "Forget this mouse"), role: .destructive) { settings.mouseProfiles[name] = nil }
                }
            }
            .disabled(!active && connected)
        } header: {
            Text(connected ? name : tx("\(name) (bağlı değil)", "\(name) (not connected)"))
        }
        .onAppear(perform: load)
        .onChange(of: profile) { _, _ in load() }
    }

    private func load() {
        let current = profile ?? .suggested
        speed = current.speed
        acceleration = current.acceleration
    }

    /// Hız ve ivmeyi değiştirir, açık/kapalıyı korur.
    private func set(_ values: MouseProfile) {
        update {
            $0.speed = values.speed
            $0.acceleration = values.acceleration
        }
    }

    private func update(_ change: (inout MouseProfile) -> Void) {
        var next = profile ?? MouseProfile(enabled: false)
        change(&next)
        settings.mouseProfiles[name] = next
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String,
                        commit: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 0.05) { editing in
                    if !editing { commit() }
                }
                Text(label)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .disabled(!active)
    }
}

/// macOS'un trackpad hareketi ve Sıcak Köşe ayarları. Hareket ayarı yalnızca kullanıcı Berth'ün
/// Trackpad sayfasında bir hücreyi değiştirince yazılır.
enum SystemTrackpad {
    private static let trackpadDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    private static let verticalKeys = [3: "TrackpadThreeFingerVertSwipeGesture", 4: "TrackpadFourFingerVertSwipeGesture"]
    /// Sistem Ayarları aynı değeri bu bilgisayara özel genel alanda da tutuyor.
    private static let hostVerticalKeys = [3: "com.apple.trackpad.threeFingerVertSwipeGesture", 4: "com.apple.trackpad.fourFingerVertSwipeGesture"]
    private static let dock = "com.apple.dock" as CFString

    static var gestures: SystemGestures {
        let domain = trackpadDomains[0] as CFString
        var vertical: [Int: Bool] = [:]
        for (fingers, key) in verticalKeys {
            let value = (CFPreferencesCopyAppValue(key as CFString, domain) as? Int)
                ?? (CFPreferencesCopyValue(hostVerticalKeys[fingers]! as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int)
            vertical[fingers] = value == 2
        }
        func dockFlag(_ key: String) -> Bool { CFPreferencesCopyAppValue(key as CFString, dock) as? Bool ?? true }
        return SystemGestures(vertical: vertical, missionControl: dockFlag("showMissionControlGestureEnabled"),
                              appExpose: dockFlag("showAppExposeGestureEnabled"))
    }

    /// Üç parmakla sürükleme açıksa macOS üç parmak kaydırmalarını kullanmaz (Erişilebilirlik ayarı).
    static var threeFingerDrag: Bool {
        trackpadDomains.contains { CFPreferencesCopyAppValue("TrackpadThreeFingerDrag" as CFString, $0 as CFString) as? Bool == true }
    }

    static func write(_ gestures: SystemGestures) {
        for name in trackpadDomains {
            let domain = name as CFString
            for (fingers, key) in verticalKeys {
                CFPreferencesSetAppValue(key as CFString, (gestures.vertical[fingers] == true ? 2 : 0) as CFNumber, domain)
            }
            CFPreferencesAppSynchronize(domain)
        }
        for (fingers, key) in hostVerticalKeys {
            CFPreferencesSetValue(key as CFString, (gestures.vertical[fingers] == true ? 2 : 0) as CFNumber,
                                  kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSetAppValue("showMissionControlGestureEnabled" as CFString, gestures.missionControl as CFBoolean, dock)
        CFPreferencesSetAppValue("showAppExposeGestureEnabled" as CFString, gestures.appExpose as CFBoolean, dock)
        CFPreferencesAppSynchronize(dock)
    }

    static func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openHotCornerSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Düzenler

private struct LayoutsTab: View {
    @ObservedObject var layouts: WorkspaceLayoutStore
    let actions: LayoutActions
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if layouts.layouts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.3x2").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(tx("Henüz kayıtlı düzen yok", "No saved layouts yet")).font(.headline)
                        Text(tx("\"Şimdiki düzeni kaydet\" pencerelerin yerini saklar; sonra buradan, menü çubuğundan ya da kendi kısayoluyla yüklersin.", "\"Save current layout\" stores where your windows are; restore it here, from the menu bar or with its own shortcut."))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ForEach(layouts.layouts, id: \.name) { layout in
                        LayoutRow(layout: layout, layouts: layouts, actions: actions, message: $message)
                    }
                }
            } header: {
                HStack(alignment: .bottom) {
                    Text(tx("Pencerelerin yeri, boyutu ve küçültülme durumu. Yüklerken kapalı uygulamalar açılır. Başka alandaki ve tam ekran pencereler kaydedilmez.", "Each window's position, size and minimized state. Restoring launches apps that are closed. Windows on other spaces and in full screen aren't saved."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 16)
                    Button(tx("Şimdiki düzeni kaydet", "Save current layout")) { actions.saveCurrent() }
                        .buttonStyle(.borderedProminent)
                }
                .textCase(nil)
            } footer: {
                if let message {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LayoutRow: View {
    let layout: WorkspaceLayout
    @ObservedObject var layouts: WorkspaceLayoutStore
    let actions: LayoutActions
    @Binding var message: String?
    @State private var name = ""
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField(tx("Ad", "Name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit {
                        if !layouts.rename(layout.name, to: name) {
                            name = layout.name
                            message = tx("Bu ad boş ya da başka bir düzende kullanılıyor.", "This name is empty or used by another layout.")
                        } else {
                            message = nil
                        }
                    }
                Text(tx("\(layout.windows.count) pencere · \(layout.savedAt.formatted(date: .abbreviated, time: .shortened))", "\(layout.windows.count) windows · \(layout.savedAt.formatted(date: .abbreviated, time: .shortened))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(recording ? tx("Kısayola basın…", "Press a shortcut…") : (layout.hotKey?.display ?? tx("Kısayol ata", "Set shortcut"))) { toggleRecording() }
                .help(tx("Esc vazgeçer, ⌫ kısayolu kaldırır.", "Esc cancels, ⌫ removes the shortcut."))
            Button(tx("Yükle", "Restore")) { actions.restore(layout) }
            Button {
                layouts.remove(named: layout.name)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(tx("Düzeni sil", "Delete layout"))
        }
        .onAppear { name = layout.name }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if recording { stopRecording(); return }
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { stopRecording(); return }
        if Int(event.keyCode) == kVK_Delete {
            layouts.setHotKey(nil, for: layout.name)
            stopRecording()
            return
        }
        let flags = event.modifierFlags
        let control = flags.contains(.control), option = flags.contains(.option)
        let shift = flags.contains(.shift), command = flags.contains(.command)
        guard ShortcutFormat.isAcceptable(control: control, option: option, shift: shift, command: command) else {
            message = tx("Kısayolda ⌃, ⌥ ya da ⌘ tuşlarından biri olmalı.", "A shortcut needs ⌃, ⌥ or ⌘.")
            return
        }
        var carbon = 0
        if control { carbon |= controlKey }
        if option { carbon |= optionKey }
        if shift { carbon |= shiftKey }
        if command { carbon |= cmdKey }
        let key = Int(event.keyCode) == kVK_Space
            ? "Space"
            : (event.charactersIgnoringModifiers ?? "").uppercased(with: Locale(identifier: "tr_TR"))
        let hotKey = WorkspaceLayout.HotKey(
            keyCode: UInt32(event.keyCode), modifiers: UInt32(carbon),
            display: ShortcutFormat.display(control: control, option: option, shift: shift, command: command, key: key)
        )
        stopRecording()
        if hotKey == layout.hotKey { return }
        guard actions.isHotKeyFree(hotKey) else {
            message = tx("\(hotKey.display) başka bir yerde kullanılıyor.", "\(hotKey.display) is already in use.")
            return
        }
        layouts.setHotKey(hotKey, for: layout.name)
    }
}

private struct ArrangementTab: View {
    @ObservedObject var store: ArrangementStore
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tx("Sahnede yeri sabit olan uygulamalar; soldan sağa bu sırayla yerleşir. Boyut, hücrenin genişliğidir.", "Apps with a fixed place in the scene, laid out left to right in this order. Size is the cell width."))
                .font(.callout)
                .foregroundStyle(.secondary)

            PinStrip(store: store, selection: $selection)

            List(selection: $selection) {
                ForEach(store.arrangement.pinned, id: \.self) { id in
                    AppRow(id: id, store: store)
                }
                .onMove { source, destination in
                    store.update { $0.pinned.move(fromOffsets: source, toOffset: destination) }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack(spacing: 8) {
                Menu(tx("Uygulama ekle", "Add app")) {
                    ForEach(addableApps(), id: \.id) { app in
                        Button(app.name) {
                            store.update { $0.pin(app.id, windowCount: 1) }
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Text(tx("Sıralamak için satırı sürükleyin.", "Drag a row to reorder."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func addableApps() -> [(id: String, name: String)] {
        let pinned = Set(store.arrangement.pinned)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app -> (id: String, name: String)? in
                guard let id = app.bundleIdentifier, !pinned.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Sahnedeki sıra ve genişlik: küçük 1, orta 2, büyük 3 birim. Tıklanan hücre listede seçilir.
private struct PinStrip: View {
    @ObservedObject var store: ArrangementStore
    @Binding var selection: String?

    var body: some View {
        GeometryReader { proxy in
            let ids = store.arrangement.pinned
            let units = ids.reduce(0) { $0 + weight(store.arrangement.size(of: $1)) }
            let gap: CGFloat = 6
            let unit = units > 0 ? (proxy.size.width - gap * CGFloat(max(ids.count - 1, 0))) / CGFloat(units) : 0
            HStack(spacing: gap) {
                ForEach(ids, id: \.self) { id in
                    let width = max(unit * CGFloat(weight(store.arrangement.size(of: id))), 0)
                    cell(id, showsName: width >= 64).frame(width: width)
                }
            }
            .overlay {
                if ids.isEmpty {
                    Text(tx("Henüz sabit uygulama yok. Sahnede bir uygulamaya sağ tıklayıp sabitleyebilir ya da aşağıdan ekleyebilirsin.", "No pinned apps yet. Right-click an app in the scene to pin it, or add one below."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 64)
    }

    private func weight(_ size: SlotSize) -> Int {
        switch size {
        case .small: return 1
        case .medium: return 2
        case .large: return 3
        }
    }

    private func cell(_ id: String, showsName: Bool) -> some View {
        let on = selection == id
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = url.map { InstalledApps.name(bundleURL: $0, fallback: FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")) } ?? id
        return Button {
            selection = id
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application))
                    .resizable().frame(width: 24, height: 24)
                if showsName {
                    Text(name).font(.caption).lineLimit(1).foregroundStyle(on ? Color.white : Color.primary)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Color.clear : Color.secondary.opacity(0.25)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

private struct AppRow: View {
    let id: String
    @ObservedObject var store: ArrangementStore

    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    private var name: String {
        guard let url else { return id }
        let display = FileManager.default.displayName(atPath: url.path)
        return InstalledApps.name(bundleURL: url, fallback: display.hasSuffix(".app") ? String(display.dropLast(4)) : display)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application))
                .resizable()
                .frame(width: 20, height: 20)
            Text(name).lineLimit(1)
            Spacer()
            Picker(tx("Boyut", "Size"), selection: Binding(
                get: { store.arrangement.size(of: id) },
                set: { size in store.update { $0.sizes[id] = size } }
            )) {
                Text(tx("Küçük", "Small")).tag(SlotSize.small)
                Text(tx("Orta", "Medium")).tag(SlotSize.medium)
                Text(tx("Büyük", "Large")).tag(SlotSize.large)
            }
            .labelsHidden()
            .fixedSize()
            Button {
                store.update { $0.unpin(id) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(tx("Sabitlemeyi kaldır", "Unpin"))
        }
    }
}

private struct PermissionsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var screenRecording = Permissions.screenRecording
    @State private var accessibility = Permissions.accessibility
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                if settings.windowPreviewsEnabled {
                    row(tx("Ekran Kaydı", "Screen Recording"), detail: tx("Pencere önizlemeleri ve başlıkları", "Window previews and titles"), granted: screenRecording) {
                        Permissions.openScreenRecordingSettings()
                    }
                } else {
                    HStack {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tx("Ekran Kaydı", "Screen Recording"))
                            Text(screenRecording
                                 ? tx("Gerekmiyor, önizlemeler kapalı. Daha önce verilen izni Sistem Ayarları'ndan kaldırabilirsiniz.", "Not needed, previews are off. You can remove access you granted earlier in System Settings.")
                                 : tx("Gerekmiyor, önizlemeler kapalı.", "Not needed, previews are off."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                row(tx("Erişilebilirlik", "Accessibility"), detail: tx("Pencereye geçme, yaslama, kapatma, Dock önizlemesi", "Switching, snapping and closing windows, Dock previews"), granted: accessibility) {
                    Permissions.openAccessibilitySettings()
                }
            }
            Section(tx("Bu macOS sürümüyle uyumluluk", "Compatibility with this macOS version")) {
                ForEach(Compatibility.check()) { item in
                    HStack(alignment: .top) {
                        Image(systemName: item.works ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(item.works ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.works ? item.feature : tx("Çalışmıyor: \(item.feature)", "Not working: \(item.feature)"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            screenRecording = Permissions.screenRecording
            accessibility = Permissions.accessibility
        }
    }

    private func row(_ title: String, detail: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(tx("Sistem Ayarları'nı Aç", "Open System Settings"), action: open)
            }
        }
    }
}
