import AppKit
import BerthCore

/// Ekrana çizilecek tek pencere.
struct SceneWindow: Identifiable, Equatable {
    enum State: Equatable {
        /// Şu anki masaüstünde görünüyor; açılışta gerçek yerinden uçar.
        case visible
        case otherSpace
        case fullScreen
        case minimized
        case hidden
    }

    var id: CGWindowID
    var pid: pid_t
    var appID: String
    var title: String
    /// CGWindowList uzayı: ana ekranın sol üstü orijin, y aşağı büyür.
    var frame: CGRect
    var state: State
    var spaceID: UInt64?
    /// Önizleme köşesindeki yazı.
    var badge: String
    /// Ön-arka sırası; 0 en önde.
    var zRank: Int
    /// `WindowActivator` eşleştirmesinde son çare olan uygulama içi sıra.
    var appIndex: Int

    var aspect: CGFloat { frame.height > 0 ? frame.width / frame.height : 1.6 }

    /// Başlık yoksa pencereleri ayıran yedek ad.
    func displayName(appName: String, windowCount: Int) -> String {
        WindowNaming.display(title: title, appName: appName, index: appIndex, windowCount: windowCount)
    }
}

struct SceneSpace: Identifiable, Equatable {
    var id: UInt64
    var label: String
    var isFullScreen: Bool
    var isCurrent: Bool
    var index: Int
}

struct SceneApp {
    var id: String
    var name: String
    var icon: NSImage
    var isRunning: Bool
    var pid: pid_t?
    var bundleURL: URL?
    /// Açılış sırası (pencere kimliği artan): kullanım sırası yığını karıştırmaz.
    var windows: [SceneWindow]
}

struct SceneSnapshot {
    var apps: [String: SceneApp]
    var spaces: [SceneSpace]
    var currentSpaceIsFullScreen: Bool

    func app(_ id: String) -> SceneApp? { apps[id] }

    /// Sabit olmayan, penceresi olan uygulamalar: ada göre, böylece çiplerin yeri de sabit.
    func otherApps(pinned: [String]) -> [SceneApp] {
        let pinnedSet = Set(pinned)
        return apps.values
            .filter { !pinnedSet.contains($0.id) && !$0.windows.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var allWindows: [SceneWindow] { apps.values.flatMap(\.windows) }

    func windows(inSpace id: UInt64) -> [SceneWindow] {
        apps.values.flatMap(\.windows).filter { $0.spaceID == id && $0.state != .minimized && $0.state != .hidden }
    }
}

/// Sistemden o anki durumu okur. Yoklama yok: yalnızca kaplama açılırken çağrılır.
@MainActor
enum SceneSource {

    static func snapshot(for screen: NSScreen, pinned: [String]) -> SceneSnapshot {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        var runningByPID: [pid_t: NSRunningApplication] = [:]
        for app in running { runningByPID[app.processIdentifier] = app }

        let canReadTitles = Permissions.screenRecording
        var (spaces, labelByID, fullScreenIDs, currentIDs) = readSpaces(for: screen)
        // Birden çok ekranda, başka ekrandaki alanın etiketine ekranın adı eklenir: "Masaüstü"
        // tek başına hangi ekran olduğunu söylemez.
        let otherDisplayLabels = otherDisplayNames(excluding: screen)
        for (id, name) in otherDisplayLabels {
            labelByID[id] = labelByID[id].map { "\(name) · \($0)" } ?? name
        }
        var accessibleByPID: [pid_t: [(title: String, frame: CGRect, minimized: Bool)]] = [:]
        func accessible(_ pid: pid_t) -> [(title: String, frame: CGRect, minimized: Bool)] {
            let list = accessibleByPID[pid] ?? WindowActivator.accessibleWindows(pid: pid)
            accessibleByPID[pid] = list
            return list
        }
        let screens = activeDisplayBounds()

        var windowsByApp: [String: [SceneWindow]] = [:]
        // Pencere başına değil uygulama başına bir sorgu; yalnızca gerektiğinde yapılır.
        var minimizedTitles: [pid_t: [String]] = [:]
        func isMinimized(pid: pid_t, title: String) -> Bool {
            let titles = minimizedTitles[pid] ?? WindowActivator.minimizedWindowTitles(pid: pid)
            minimizedTitles[pid] = titles
            return titles.contains { WindowActivator.titleMatches($0, wanted: title) }
        }
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        var rank = 0
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let owner = runningByPID[pid],
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { continue }
            guard !WindowFilter.isParked(frame, screens: screens) else { continue }

            // İzin yokken ad boş gelir (sınama bayrağında da boş sayılır).
            var title = canReadTitles ? ((info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : ""
            let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false

            // Boyut elemesini API çağrısından önce yapmak yüzlerce gereksiz çağrıyı önler.
            guard frame.width >= WindowFilter.minimumSize.width,
                  frame.height >= WindowFilter.minimumSize.height else { continue }

            let windowSpaces = SkyLight.spaces(forWindow: number)
            // SkyLight yoksa her pencere bir masaüstünde sayılır; eleme başlığa dayanır.
            let hasSpace = SkyLight.isAvailable ? !windowSpaces.isEmpty : true

            // İzin yokken başlığı ve küçültülmüş durumu Erişilebilirlik söyler.
            var verifiedMinimized = false
            if !canReadTitles, frame.width >= 200, frame.height >= 200 {
                let candidates = accessible(pid).map { (element: $0, frame: $0.frame) }
                if let match = WindowNaming.uniqueMatch(frame: frame, candidates: candidates) {
                    title = match.title
                    verifiedMinimized = match.minimized
                }
            }

            guard verifiedMinimized || WindowFilter.isUserWindow(
                title: title,
                isOnScreen: isOnScreen,
                hasSpace: hasSpace,
                size: frame.size,
                canReadTitles: canReadTitles
            ) else { continue }

            let spaceID = windowSpaces.first
            let canVerify = canReadTitles && WindowActivator.isTrusted && !title.isEmpty

            // Masaüstü bilgisi olmayan ya da ekrana dizili olmayan başlıklı pencere ya
            // küçültülmüştür ya da uygulamanın kapatıp sakladığı bir penceredir (ölçüldü:
            // Mail'in eski bir penceresi; Windows App'in kapatılan "Devices" penceresi bir
            // masaüstüne bağlı görünüyor ama dizili değil, tıklanınca hiçbir şey olmuyordu).
            // Erişilebilirlik ayırt edebiliyor: küçültülmüş değilse kullanıcı ona ulaşamaz.
            let orderedOut = !isOnScreen && SkyLight.isOrderedIn(number) == false
            if SkyLight.isAvailable, spaceID == nil || orderedOut, !owner.isHidden, canVerify,
               !isMinimized(pid: pid, title: title) {
                continue
            }

            let state: SceneWindow.State
            if owner.isHidden {
                state = .hidden
            } else if isOnScreen {
                state = .visible
            } else if let spaceID {
                if fullScreenIDs.contains(spaceID) {
                    state = .fullScreen
                } else if currentIDs.contains(spaceID) {
                    // Bu masaüstünde ama ekranda değil: küçültülmüş.
                    state = .minimized
                } else {
                    state = .otherSpace
                }
            } else {
                state = SkyLight.isAvailable ? .minimized : .otherSpace
            }

            let appID = owner.bundleIdentifier ?? "pid:\(pid)"
            let badge: String
            switch state {
            case .hidden: badge = tx("Gizli", "Hidden")
            case .minimized:
                // Bu masaüstünde ama ekranda değil: küçültülmüş olduğu doğrulanmadıysa
                // bilmediğimizi söylemek, yanlış söylemekten iyidir.
                let verified = verifiedMinimized || (canReadTitles && (!canVerify || isMinimized(pid: pid, title: title)))
                badge = verified ? tx("Küçültülmüş", "Minimized") : tx("Görünmüyor", "Not visible")
            case .fullScreen: badge = tx("Tam ekran", "Full screen")
            case .visible, .otherSpace:
                badge = spaceID.flatMap { fullScreenIDs.contains($0) ? tx("Tam ekran", "Full screen") : labelByID[$0] } ?? ""
            }

            windowsByApp[appID, default: []].append(SceneWindow(
                id: number,
                pid: pid,
                appID: appID,
                title: title,
                frame: frame,
                state: state,
                spaceID: spaceID,
                badge: badge,
                zRank: rank,
                appIndex: windowsByApp[appID]?.count ?? 0
            ))
            rank += 1
        }

        // Başlık okunamayınca tam ekran alanı, içindeki uygulamanın adıyla anılır.
        for index in spaces.indices where spaces[index].isFullScreen && spaces[index].label == tx("Tam ekran", "Full screen") {
            let owner = windowsByApp.first { $0.value.contains { $0.spaceID == spaces[index].id } }?.key
            let name = owner.flatMap { id in running.first { $0.bundleIdentifier == id }?.localizedName }
            if let name { spaces[index].label = cleanName(name) }
        }
        _ = labelByID

        var apps: [String: SceneApp] = [:]
        for app in running {
            let id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
            let windows = (windowsByApp[id] ?? []).sorted { $0.id < $1.id }
            apps[id] = SceneApp(
                id: id,
                name: cleanName(app.localizedName ?? id),
                icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
                isRunning: true,
                pid: app.processIdentifier,
                bundleURL: app.bundleURL,
                windows: windows
            )
        }

        // Sabit ama kapalı uygulamaların yuvası boş kalır, adını ve simgesini diskten alır.
        for id in pinned where apps[id] == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let display = FileManager.default.displayName(atPath: url.path)
            apps[id] = SceneApp(
                id: id,
                name: cleanName(display.hasSuffix(".app") ? String(display.dropLast(4)) : display),
                icon: NSWorkspace.shared.icon(forFile: url.path),
                isRunning: false,
                pid: nil,
                bundleURL: url,
                windows: []
            )
        }

        let current = spaces.first { $0.isCurrent }
        return SceneSnapshot(apps: apps, spaces: spaces, currentSpaceIsFullScreen: current?.isFullScreen ?? false)
    }

    // MARK: - Masaüstleri

    /// Ekranın masaüstleri, Mission Control'deki sırayla.
    static func managedDisplay(for screen: NSScreen) -> SkyLight.ManagedDisplay? {
        let displays = SkyLight.displays()
        let uuid = screen.displayUUID
        return displays.first { $0.identifier.caseInsensitiveCompare(uuid) == .orderedSame }
            ?? displays.first { $0.identifier == "Main" }
            ?? displays.first
    }

    static func currentSpaceIsFullScreen(on screen: NSScreen) -> Bool {
        readSpaces(for: screen).spaces.first { $0.isCurrent }?.isFullScreen ?? false
    }

    private static func readSpaces(for screen: NSScreen) -> (
        spaces: [SceneSpace],
        labels: [UInt64: String],
        fullScreen: Set<UInt64>,
        current: Set<UInt64>
    ) {
        let displays = SkyLight.displays()
        var labels: [UInt64: String] = [:]
        var fullScreen: Set<UInt64> = []
        var current: Set<UInt64> = []

        for display in displays {
            let names = SpaceNaming.labels(display.spaces.map {
                .init(isFullScreen: $0.isFullScreen, name: Permissions.screenRecording ? $0.name : "")
            })
            for (space, name) in zip(display.spaces, names) {
                labels[space.id] = name
                if space.isFullScreen { fullScreen.insert(space.id) }
            }
            current.insert(display.currentSpaceID)
        }

        let uuid = screen.displayUUID
        let display = displays.first { $0.identifier.caseInsensitiveCompare(uuid) == .orderedSame }
            ?? displays.first { $0.identifier == "Main" }
            ?? displays.first
        guard let display else { return ([], labels, fullScreen, current) }

        let spaces = display.spaces.enumerated().map { index, space in
            SceneSpace(
                id: space.id,
                label: labels[space.id] ?? "",
                isFullScreen: space.isFullScreen,
                isCurrent: space.id == display.currentSpaceID,
                index: index
            )
        }
        return (spaces, labels, fullScreen, current)
    }

    /// Bu ekran dışındaki ekranların alanları ve o ekranın adı.
    private static func otherDisplayNames(excluding screen: NSScreen) -> [UInt64: String] {
        guard NSScreen.screens.count > 1 else { return [:] }
        let own = screen.displayUUID
        var result: [UInt64: String] = [:]
        for display in SkyLight.displays() where display.identifier.caseInsensitiveCompare(own) != .orderedSame {
            let name = NSScreen.screens.first { $0.displayUUID.caseInsensitiveCompare(display.identifier) == .orderedSame }?
                .localizedName ?? tx("Diğer ekran", "Other display")
            let short = name.hasPrefix("Built-in") || name.hasPrefix(tx("Yerleşik", "Built-in")) ? tx("Dahili ekran", "Built-in display") : name
            for space in display.spaces { result[space.id] = short }
        }
        return result
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Bazı uygulama adları görünmez yön işaretiyle başlar ("\u{200E}WhatsApp").
    private static func cleanName(_ name: String) -> String {
        name.unicodeScalars
            .filter { !["\u{200E}", "\u{200F}", "\u{202A}", "\u{202C}"].contains(String($0)) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var displayUUID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String? ?? ""
    }
}
