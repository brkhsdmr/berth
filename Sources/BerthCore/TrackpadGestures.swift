import Foundation

public enum SwipeDirection: String, CaseIterable, Sendable { case up, down }

/// Trackpad'de çok parmakla dikey kaydırmanın yapacağı iş.
public enum GestureAction: String, CaseIterable, Sendable {
    case nothing, scene, missionControl, appExpose

    public var label: String {
        switch self {
        case .nothing: return tx("Hiçbir şey", "Nothing")
        case .scene: return tx("Berth sahnesi", "Berth scene")
        case .missionControl: return "Mission Control"
        case .appExpose: return tx("Uygulama pencereleri (App Exposé)", "App windows (App Exposé)")
        }
    }
}

/// macOS'un kendi trackpad hareketi ayarı (Sistem Ayarları > Trackpad > Diğer Hareketler).
///
/// macOS dikey kaydırmayı parmak sayısı başına açar ya da kapatır
/// (`TrackpadThreeFingerVertSwipeGesture`, `…FourFinger…`); açıksa yukarı Mission Control, aşağı
/// App Exposé'dir ve ikisi Dock'ta ayrı ayrı açılıp kapanır (`showMissionControlGestureEnabled`,
/// `showAppExposeGestureEnabled`). Sistem Ayarları her biri için tek parmak sayısı gösterebiliyor;
/// 3 ve 4 birlikte açıksa ekranda görünmez ama çalışır.
public struct SystemGestures: Equatable, Sendable {
    public var vertical: [Int: Bool]
    public var missionControl: Bool
    public var appExpose: Bool

    public init(vertical: [Int: Bool], missionControl: Bool, appExpose: Bool) {
        self.vertical = vertical
        self.missionControl = missionControl
        self.appExpose = appExpose
    }

    /// Berth olmasaydı macOS'un bu harekette yapacağı.
    public func native(fingers: Int, direction: SwipeDirection) -> GestureAction {
        guard vertical[fingers] == true else { return .nothing }
        switch direction {
        case .up: return missionControl ? .missionControl : .nothing
        case .down: return appExpose ? .appExpose : .nothing
        }
    }
}

/// Parmak sayısı ve yön başına hareket tablosu.
public struct TrackpadGestureMap: Equatable, Sendable {
    public static let fingerCounts = [3, 4]

    private var actions: [String: GestureAction]

    public init(_ actions: [Int: [SwipeDirection: GestureAction]] = [:]) {
        self.actions = [:]
        for (fingers, row) in actions {
            for (direction, action) in row { self[fingers, direction] = action }
        }
    }

    private static func key(_ fingers: Int, _ direction: SwipeDirection) -> String { "\(fingers)-\(direction.rawValue)" }

    public subscript(fingers: Int, direction: SwipeDirection) -> GestureAction {
        get { actions[Self.key(fingers, direction)] ?? .nothing }
        set { actions[Self.key(fingers, direction)] = newValue }
    }

    /// Eski tek seçenekten (sahneyi açan parmak sayısı, 0 kapalı) ve macOS'un ayarından: sahne
    /// seçilen sayıda yukarıda, kalan hücreler macOS'un o an yaptığı.
    public static func migrated(sceneFingers: Int, system: SystemGestures) -> TrackpadGestureMap {
        var map = TrackpadGestureMap()
        for fingers in fingerCounts {
            for direction in SwipeDirection.allCases {
                map[fingers, direction] = system.native(fingers: fingers, direction: direction)
            }
        }
        if fingerCounts.contains(sceneFingers) { map[sceneFingers, .up] = .scene }
        return map
    }

    /// Sahneyi açan hareket var mı.
    public var opensScene: Bool { contains(.scene) }

    public func contains(_ action: GestureAction) -> Bool {
        Self.fingerCounts.contains { fingers in SwipeDirection.allCases.contains { self[fingers, $0] == action } }
    }

    /// Bu tabloya en yakın macOS ayarı: Berth kapalıyken de mümkün olduğunca aynı davranılsın,
    /// Sistem Ayarları da tabloyla çelişmesin. Bir parmak sayısında yalnızca "hiçbir şey" varsa macOS
    /// o hareketi kapatır; Berth'ün işleri (sahne) macOS'ta Mission Control / App Exposé olarak kalır.
    public var systemEquivalent: SystemGestures {
        var vertical: [Int: Bool] = [:]
        for fingers in Self.fingerCounts {
            vertical[fingers] = SwipeDirection.allCases.contains { self[fingers, $0] != .nothing }
        }
        func sceneOn(_ direction: SwipeDirection) -> Bool { Self.fingerCounts.contains { self[$0, direction] == .scene } }
        return SystemGestures(vertical: vertical, missionControl: contains(.missionControl) || sceneOn(.up),
                              appExpose: contains(.appExpose) || sceneOn(.down))
    }

    /// `UserDefaults` için.
    public var dictionary: [String: String] { actions.mapValues(\.rawValue) }

    public init(dictionary: [String: String]) {
        actions = dictionary.compactMapValues(GestureAction.init(rawValue:))
    }
}

/// Bir hareketin Berth'te ne olacağı.
public enum GestureRouting {
    public enum Outcome: Equatable, Sendable { case none, perform(GestureAction), close }

    /// Parmak sayısı okunamadıysa (0) üç parmak sayılır.
    public static func fingers(_ count: Int) -> Int { TrackpadGestureMap.fingerCounts.contains(count) ? count : 3 }

    /// Hareket macOS'a gitmeyip Berth'te mi kalır? Tablodaki iş macOS'un zaten yapacağıysa macOS'a
    /// bırakılır (parmağı izleyen kendi animasyonuyla). `remoteDown`: Windows App oturumu öndeyken
    /// App Exposé o bilgisayara gider.
    public static func captures(fingers: Int, direction: SwipeDirection, map: TrackpadGestureMap, system: SystemGestures,
                                overlayOpen: Bool, remoteDown: Bool) -> Bool {
        if overlayOpen { return true }
        let action = map[fingers, direction]
        if remoteDown, action == .appExpose { return true }
        return action != system.native(fingers: fingers, direction: direction)
    }

    /// Sahne açıkken aşağı kaydırma kapatır, yukarı bir şey yapmaz.
    public static func outcome(fingers: Int, direction: SwipeDirection, map: TrackpadGestureMap, overlayOpen: Bool) -> Outcome {
        if overlayOpen { return direction == .down ? .close : .none }
        let action = map[fingers, direction]
        return action == .nothing ? .none : .perform(action)
    }
}
