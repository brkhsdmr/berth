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
        // Başlık bölümün adıdır (navigationTitle); Pencere menüsünde de o görünür.
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
        case .opening: return "Açılış"
        case .pinned: return "Sabit uygulamalar"
        case .layouts: return "Çalışma düzenleri"
        case .windows: return "Windows bağlantısı"
        case .general: return "Genel"
        case .permissions: return "İzinler"
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
                Toggle("Klavye kısayoluyla aç", isOn: $settings.shortcutEnabled)
                LabeledContent("Kısayol") {
                    HStack(spacing: 8) {
                        Text(recording ? "Bir kısayola basın…" : settings.shortcut.display)
                            .monospacedDigit()
                            .foregroundStyle(recording ? .secondary : .primary)
                        Button(recording ? "Vazgeç" : "Değiştir") { toggleRecording() }
                    }
                }
                .disabled(!settings.shortcutEnabled)
                if let shortcutMessage {
                    Text(shortcutMessage).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Klavye")
            } footer: {
                Text("Aynı kısayol sahne açıkken kapatır. Menü çubuğu simgesine tıklamak da açar ya da kapatır.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Picker("Yukarı kaydırma", selection: $settings.trackpadFingers) {
                    Text("Kapalı").tag(0)
                    Text("3 parmak").tag(3)
                    Text("4 parmak").tag(4)
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
                Picker("Köşede bekleme", selection: $settings.hotCornerDelay) {
                    Text("Hemen").tag(0.0)
                    Text("0,25 sn").tag(0.25)
                    Text("0,5 sn").tag(0.5)
                    Text("1 sn").tag(1.0)
                }
                .disabled(settings.hotCorner == .none)
                if let conflict = HotCornerMonitor.systemAction(at: settings.hotCorner) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("macOS bu köşeye \(conflict) atamış; ikisi birlikte açılır. Sistem Ayarları > Masaüstü ve Dock > Sıcak Köşeler'den kaldırabilirsiniz.")
                            .font(.callout)
                        Spacer()
                        Button("Aç") { SystemTrackpad.openHotCornerSettings() }
                    }
                }
            } header: {
                Text("Sıcak köşe")
            } footer: {
                Text("Köşeye tıklayarak seç; seçili köşeye yeniden tıklamak kapatır. İmleç köşeye gelince sahne açılır, açıksa kapanır. Fare düğmesi basılıyken tetiklenmez.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private var trackpadNote: String {
        guard settings.trackpadFingers > 0 else {
            return "Mission Control macOS'ta olduğu gibi çalışır."
        }
        let chosen = settings.trackpadFingers
        let other = chosen == 3 ? 4 : 3
        var lines = ["\(chosen) parmakla yukarı kaydırma sahneyi açar, sahne açıkken aşağı kaydırma kapatır."]
        if systemFingers.contains(other) {
            lines.append("\(other) parmak Mission Control'ü açmaya devam eder.")
        }
        if !systemFingers.contains(chosen) {
            lines.append("macOS bu hareketi başka işe atamış olabilir (örneğin üç parmakla sürükleme); çakışırsa Sistem Ayarları > Trackpad'den kapatın.")
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
            shortcutMessage = "Kısayolda ⌃, ⌥ ya da ⌘ tuşlarından biri olmalı."
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
            shortcutMessage = "\(next.display) başka bir uygulamada kullanılıyor."
        }
    }
}

private struct WindowsTab: View {
    @ObservedObject var settings: AppSettings

    private var connected: Bool { settings.remoteBridgeEnabled && !settings.connectedRemotes.isEmpty }
    private var statusColor: Color { connected ? .green : settings.remoteBridgeEnabled ? .orange : .secondary }
    private var statusLabel: String { connected ? "Bağlı" : settings.remoteBridgeEnabled ? "Bekleniyor" : "Kapalı" }
    private var statusDetail: String {
        if connected { return settings.connectedRemotes.joined(separator: ", ") }
        if settings.trackpadFingers == 0 { return "Açılış'ta trackpad hareketi kapalı; önce onu açın." }
        return settings.remoteBridgeEnabled ? "Windows'taki uygulamanın bağlanması bekleniyor." : "Windows'a hareket gönderilmiyor."
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    SidebarIcon(symbol: "pc", tint: .teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Durum")
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
                Toggle("Windows App oturumunda hareketi Windows'a gönder", isOn: $settings.remoteBridgeEnabled)
                    .disabled(settings.trackpadFingers == 0)
                if settings.remoteBridgeEnabled {
                    TextField("Oturum adları", text: $settings.remoteSessionNames, prompt: Text("Boşsa: bu Mac'e bağlı Windows'larla eşleşen oturumlar"))
                    LabeledContent("Bu Mac'in adı") {
                        Text(Host.current().localizedName ?? ProcessInfo.processInfo.hostName).textSelection(.enabled)
                    }
                    LabeledContent("Eşleştirme kodu") {
                        HStack(spacing: 8) {
                            Text(settings.remoteToken).font(.body.monospaced()).textSelection(.enabled)
                            Button("Yenile") { settings.renewRemoteToken() }
                        }
                    }
                    LabeledContent("Bağlı") {
                        Text(settings.connectedRemotes.isEmpty ? "Bağlı Windows yok" : settings.connectedRemotes.joined(separator: ", "))
                            .foregroundStyle(settings.connectedRemotes.isEmpty ? .secondary : .primary)
                    }
                }
            } header: {
                Text("Uzak masaüstü (Windows)")
            } footer: {
                Text("Windows'taki Berth ayarlarına bu Mac'in adını ve kodu girin; Windows uygulaması bu Mac'e Tailscale ya da yerel ağ üzerinden bağlanır. Windows App'te o oturum öndeyken yukarı kaydırma oradaki sahneyi açar ya da kapatır. Uygulamanın kurulu olmadığı oturumlarda Mac'in sahnesi açılır.")
                    .font(.callout).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }
}

private struct UsageTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Pencerelerin gerçek görüntüsünü göster", isOn: $settings.windowPreviewsEnabled)
                Text(settings.windowPreviewsEnabled
                     ? "Ekran Kaydı izni gerekir. Görüntüler yalnızca sahne ya da Dock önizlemesi açılınca alınır; macOS bu sırada kayıt göstergesini gösterebilir."
                     : "Hiç ekran yakalaması yapılmaz; izin daha önce verilmiş olsa bile kullanılmaz. Pencereler simge ve başlıkla gösterilir. Başka masaüstündeki pencerelerin başlığı görünmeyebilir.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pencere önizlemeleri")
            }
            Section("Dock") {
                Toggle("Dock simgesinin üstüne gelince pencereleri göster", isOn: $settings.dockPreviewsEnabled)
                Text("Uygulamanın tüm masaüstlerindeki pencereleri simgenin yanında önizlenir.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Önizleme açıkken Dock gizlenmesin", isOn: $settings.keepDockOpenDuringPreview)
                    .disabled(!settings.dockPreviewsEnabled)
                Text("Dock otomatik gizliyse önizlemeye geçince de açık kalır. Bunun için macOS'un otomatik gizleme ayarı önizleme süresince kapatılıp sonra geri açılır.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Tam ekranda kenara değince Dock şeridini aç", isOn: $settings.fullScreenDockEnabled)
                    .disabled(!settings.dockPreviewsEnabled)
                Text("macOS tam ekranda Dock'u her zaman açmıyor. Şerit, Dock'un olduğu kenarda aynı uygulamaları gösterir.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Başlangıç") {
                Toggle("Oturum açıldığında başlat", isOn: Binding(
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
                        Text("Sürüm \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") · Masaüstleri ve pencereler için sabit yerleşimli sahne")
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
                        Text("Henüz kayıtlı düzen yok").font(.headline)
                        Text("\"Şimdiki düzeni kaydet\" pencerelerin yerini saklar; sonra buradan, menü çubuğundan ya da kendi kısayoluyla yüklersin.")
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
                    Text("Pencerelerin yeri, boyutu ve küçültülme durumu. Yüklerken kapalı uygulamalar açılır. Başka alandaki ve tam ekran pencereler kaydedilmez.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 16)
                    Button("Şimdiki düzeni kaydet") { actions.saveCurrent() }
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
                TextField("Ad", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit {
                        if !layouts.rename(layout.name, to: name) {
                            name = layout.name
                            message = "Bu ad boş ya da başka bir düzende kullanılıyor."
                        } else {
                            message = nil
                        }
                    }
                Text("\(layout.windows.count) pencere · \(layout.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(recording ? "Kısayola basın…" : (layout.hotKey?.display ?? "Kısayol ata")) { toggleRecording() }
                .help("Esc vazgeçer, ⌫ kısayolu kaldırır.")
            Button("Yükle") { actions.restore(layout) }
            Button {
                layouts.remove(named: layout.name)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Düzeni sil")
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
            message = "Kısayolda ⌃, ⌥ ya da ⌘ tuşlarından biri olmalı."
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
            message = "\(hotKey.display) başka bir yerde kullanılıyor."
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
            Text("Sahnede yeri sabit olan uygulamalar; soldan sağa bu sırayla yerleşir. Boyut, hücrenin genişliğidir.")
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
                Menu("Uygulama ekle") {
                    ForEach(addableApps(), id: \.id) { app in
                        Button(app.name) {
                            store.update { $0.pin(app.id, windowCount: 1) }
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Text("Sıralamak için satırı sürükleyin.")
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
                    Text("Henüz sabit uygulama yok. Sahnede bir uygulamaya sağ tıklayıp sabitleyebilir ya da aşağıdan ekleyebilirsin.")
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
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
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
        return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application))
                .resizable()
                .frame(width: 20, height: 20)
            Text(name).lineLimit(1)
            Spacer()
            Picker("Boyut", selection: Binding(
                get: { store.arrangement.size(of: id) },
                set: { size in store.update { $0.sizes[id] = size } }
            )) {
                Text("Küçük").tag(SlotSize.small)
                Text("Orta").tag(SlotSize.medium)
                Text("Büyük").tag(SlotSize.large)
            }
            .labelsHidden()
            .fixedSize()
            Button {
                store.update { $0.unpin(id) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Sabitlemeyi kaldır")
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
                    row("Ekran Kaydı", detail: "Pencere önizlemeleri ve başlıkları", granted: screenRecording) {
                        Permissions.openScreenRecordingSettings()
                    }
                } else {
                    HStack {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ekran Kaydı")
                            Text(screenRecording
                                 ? "Gerekmiyor, önizlemeler kapalı. Daha önce verilen izni Sistem Ayarları'ndan kaldırabilirsiniz."
                                 : "Gerekmiyor, önizlemeler kapalı.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                row("Erişilebilirlik", detail: "Pencereye geçme, yaslama, kapatma, Dock önizlemesi", granted: accessibility) {
                    Permissions.openAccessibilitySettings()
                }
            }
            Section("Bu macOS sürümüyle uyumluluk") {
                ForEach(Compatibility.check()) { item in
                    HStack(alignment: .top) {
                        Image(systemName: item.works ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(item.works ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.works ? item.feature : "Çalışmıyor: \(item.feature)")
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
                Button("Sistem Ayarları'nı Aç", action: open)
            }
        }
    }
}
