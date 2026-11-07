import AppKit
import Carbon.HIToolbox
import BerthCore
import ServiceManagement
import SwiftUI

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
        static let keepDockOpen = "keepDockOpenDuringPreview"
        static let windowPreviews = "windowPreviewsEnabled"
        static let otherAppsScroll = "otherAppsScrollEnabled"
        static let trackpadGesture = "trackpadGestureEnabled"
        static let trackpadFingers = "trackpadFingers"
        static let hotCorner = "hotCorner"
        static let hotCornerDelay = "hotCornerDelay"
        static let shortcutEnabled = "shortcutEnabled"
        static let remoteBridge = "remoteBridgeEnabled"
        static let remoteToken = "remoteToken"
        static let remoteSessions = "remoteSessionNames"
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

    /// Sahneyi açan yukarı kaydırmanın parmak sayısı; 0 kapalı.
    @Published var trackpadFingers: Int {
        didSet {
            UserDefaults.standard.set(trackpadFingers, forKey: Key.trackpadFingers)
            onTrackpadFingersChange?(trackpadFingers)
        }
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

    /// Dock otomatik gizliyken önizleme açık kaldıkça Dock gizlenmez.
    @Published var keepDockOpenDuringPreview: Bool {
        didSet { UserDefaults.standard.set(keepDockOpenDuringPreview, forKey: Key.keepDockOpen) }
    }

    @Published private(set) var shortcut: Shortcut
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginError: String?

    var onDockPreviewsChange: ((Bool) -> Void)?
    var onWindowPreviewsChange: ((Bool) -> Void)?
    var onTrackpadFingersChange: ((Int) -> Void)?
    var onHotCornerChange: ((ScreenCorner, Double) -> Void)?
    var onShortcutEnabledChange: ((Bool) -> Void)?
    var onRemoteBridgeChange: ((Bool) -> Void)?
    var onRemoteTokenChange: ((String) -> Void)?
    var onFullScreenDockChange: ((Bool) -> Void)?
    /// Kısayol alınabildiyse `true` döner.
    var onShortcutChange: ((Shortcut) -> Bool)?

    init() {
        let defaults = UserDefaults.standard
        dockPreviewsEnabled = defaults.object(forKey: Key.dockPreviews) as? Bool ?? true
        fullScreenDockEnabled = defaults.object(forKey: Key.fullScreenDock) as? Bool ?? true
        keepDockOpenDuringPreview = defaults.object(forKey: Key.keepDockOpen) as? Bool ?? true
        otherAppsScrollEnabled = defaults.object(forKey: Key.otherAppsScroll) as? Bool ?? false
        // Eski açık/kapalı ayarı: kapalıysa kapalı kalır.
        if let saved = defaults.object(forKey: Key.trackpadFingers) as? Int {
            trackpadFingers = saved
        } else {
            trackpadFingers = (defaults.object(forKey: Key.trackpadGesture) as? Bool ?? true) ? 3 : 0
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

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        return window
    }
}

// MARK: - Görünüm

/// Ayarların bölümleri: Sistem Ayarları'ndaki gibi solda renkli simgeleriyle.
enum SettingsPage: String, CaseIterable, Identifiable {
    case opening, pinned, layouts, windows, general, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opening: return tx("Açılış", "Opening")
        case .pinned: return tx("Sabit uygulamalar", "Pinned apps")
        case .layouts: return tx("Çalışma düzenleri", "Workspace layouts")
        case .windows: return tx("Windows bağlantısı", "Windows connection")
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

    private var systemFingers: [Int] { SystemTrackpad.missionControlFingers }

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
                Picker(tx("Yukarı kaydırma", "Swipe up"), selection: $settings.trackpadFingers) {
                    Text(tx("Kapalı", "Off")).tag(0)
                    Text(tx("3 parmak", "3 fingers")).tag(3)
                    Text(tx("4 parmak", "4 fingers")).tag(4)
                }
                Text(trackpadNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    private var trackpadNote: String {
        guard settings.trackpadFingers > 0 else {
            return tx("Mission Control macOS'ta olduğu gibi çalışır.", "Mission Control works as it does in macOS.")
        }
        let chosen = settings.trackpadFingers
        let other = chosen == 3 ? 4 : 3
        var lines = [tx("\(chosen) parmakla yukarı kaydırma sahneyi açar, sahne açıkken aşağı kaydırma kapatır.", "Swiping up with \(chosen) fingers opens the scene; swiping down closes it.")]
        if systemFingers.contains(other) {
            lines.append(tx("\(other) parmak Mission Control'ü açmaya devam eder.", "\(other) fingers still open Mission Control."))
        }
        if !systemFingers.contains(chosen) {
            lines.append(tx("macOS bu hareketi başka işe atamış olabilir (örneğin üç parmakla sürükleme); çakışırsa Sistem Ayarları > Trackpad'den kapatın.", "macOS may use this gesture for something else (for example three-finger drag); if they clash, turn it off in System Settings > Trackpad."))
        }
        return lines.joined(separator: " ")
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

    private var connected: Bool { settings.remoteBridgeEnabled && !settings.connectedRemotes.isEmpty }
    private var statusColor: Color { connected ? .green : settings.remoteBridgeEnabled ? .orange : .secondary }
    private var statusLabel: String { connected ? tx("Bağlı", "Connected") : settings.remoteBridgeEnabled ? tx("Bekleniyor", "Waiting") : tx("Kapalı", "Off") }
    private var statusDetail: String {
        if connected { return settings.connectedRemotes.joined(separator: ", ") }
        if settings.trackpadFingers == 0 { return tx("Açılış'ta trackpad hareketi kapalı; önce onu açın.", "The trackpad gesture is off in Opening; turn it on first.") }
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
                    .disabled(settings.trackpadFingers == 0)
                if settings.remoteBridgeEnabled {
                    TextField(tx("Oturum adları", "Session names"), text: $settings.remoteSessionNames, prompt: Text(tx("Boşsa: bu Mac'e bağlı Windows'larla eşleşen oturumlar", "If empty: sessions matching a Windows PC connected to this Mac")))
                    LabeledContent(tx("Bu Mac'in adı", "This Mac's name")) {
                        Text(Host.current().localizedName ?? ProcessInfo.processInfo.hostName).textSelection(.enabled)
                    }
                    LabeledContent(tx("Eşleştirme kodu", "Pairing code")) {
                        HStack(spacing: 8) {
                            Text(settings.remoteToken).font(.body.monospaced()).textSelection(.enabled)
                            Button(tx("Yenile", "Renew")) { settings.renewRemoteToken() }
                        }
                    }
                    LabeledContent(tx("Bağlı", "Connected")) {
                        Text(settings.connectedRemotes.isEmpty ? tx("Bağlı Windows yok", "No Windows connected") : settings.connectedRemotes.joined(separator: ", "))
                            .foregroundStyle(settings.connectedRemotes.isEmpty ? .secondary : .primary)
                    }
                }
            } header: {
                Text(tx("Uzak masaüstü (Windows)", "Remote desktop (Windows)"))
            } footer: {
                Text(tx("Windows'taki Berth ayarlarına bu Mac'in adını ve kodu girin; Windows uygulaması bu Mac'e Tailscale ya da yerel ağ üzerinden bağlanır. Windows App'te o oturum öndeyken yukarı kaydırma oradaki sahneyi açar ya da kapatır. Uygulamanın kurulu olmadığı oturumlarda Mac'in sahnesi açılır.", "Enter this Mac's name and the code in Berth's settings on Windows; it connects to this Mac over Tailscale or the local network. While that session is in front in Windows App, swiping up opens or closes the scene there. In sessions without Berth, the Mac's scene opens."))
                    .font(.callout).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
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

/// macOS'un trackpad ve Sıcak Köşe ayarlarını okur; hiçbirini değiştirmez.
enum SystemTrackpad {
    /// Mission Control'e atanmış yukarı kaydırma parmak sayıları.
    static var missionControlFingers: [Int] {
        let domain = "com.apple.AppleMultitouchTrackpad" as CFString
        func value(_ key: String) -> Int? { CFPreferencesCopyAppValue(key as CFString, domain) as? Int }
        var result: [Int] = []
        if value("TrackpadThreeFingerVertSwipeGesture") == 2 { result.append(3) }
        if value("TrackpadFourFingerVertSwipeGesture") == 2 { result.append(4) }
        return result
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
