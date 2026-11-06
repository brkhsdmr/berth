import CoreGraphics

/// Sahneyi açan ekran köşesi. Görünüm uzayı: sol alt orijin (NSScreen).
public enum ScreenCorner: String, CaseIterable, Sendable {
    case none, topLeft, topRight, bottomLeft, bottomRight

    public var label: String {
        switch self {
        case .none: return "Yok"
        case .topLeft: return "Sol üst"
        case .topRight: return "Sağ üst"
        case .bottomLeft: return "Sol alt"
        case .bottomRight: return "Sağ alt"
        }
    }

    /// macOS'un Sıcak Köşeler ayarındaki adı (`wvous-tl-corner` gibi).
    public var dockKey: String? {
        switch self {
        case .none: return nil
        case .topLeft: return "tl"
        case .topRight: return "tr"
        case .bottomLeft: return "bl"
        case .bottomRight: return "br"
        }
    }

    /// İmlecin bulunduğu köşe. İmleç ekranın en kenarına ancak `frame.maxX - 1`'e kadar gidebilir,
    /// bu yüzden köşe birkaç noktalık kare olarak sınanır.
    public static func corner(of point: CGPoint, in frame: CGRect, tolerance: CGFloat = 3) -> ScreenCorner {
        let left = point.x <= frame.minX + tolerance
        let right = point.x >= frame.maxX - 1 - tolerance
        let bottom = point.y <= frame.minY + tolerance
        let top = point.y >= frame.maxY - 1 - tolerance
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: return .none
        }
    }
}

/// Trackpad'deki ham dokunmalardan çok parmakla dikey kaydırmayı tanır.
///
/// Konumlar trackpad'e göre 0...1 arasıdır, y yukarı doğru artar. Bir oturum ilk dokunuşla başlar,
/// tüm parmaklar kalkınca biter; oturumda bir kez tetiklenir. Seçilenden fazla parmak değen oturum
/// (beş parmakla sıkıştırma gibi) yok sayılır.
public struct MultiFingerSwipe: Sendable {
    public enum Action: Equatable, Sendable { case none, open, close }

    /// Trackpad yüksekliğinin oranı: Dock hareketinin eşiğine yakın.
    public static let distance = 0.12

    public var fingers: Int
    private var baseline: CGPoint?
    private var maxCount = 0
    private var fired = false

    public init(fingers: Int) {
        self.fingers = fingers
    }

    /// Oturumda şimdiye kadar değen en fazla parmak.
    public var sessionFingers: Int { maxCount }

    public mutating func handle(_ points: [CGPoint], overlayOpen: Bool) -> Action {
        guard !points.isEmpty else {
            baseline = nil
            maxCount = 0
            fired = false
            return .none
        }
        maxCount = max(maxCount, points.count)
        guard fingers > 0, points.count == fingers, maxCount == fingers, !fired else {
            if points.count != fingers { baseline = nil }
            return .none
        }

        let center = CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
        )
        guard let start = baseline else {
            baseline = center
            return .none
        }
        let dx = center.x - start.x
        let dy = center.y - start.y
        guard abs(dy) >= Self.distance, abs(dx) < abs(dy) else { return .none }
        fired = true
        if dy > 0, !overlayOpen { return .open }
        if dy < 0, overlayOpen { return .close }
        return .none
    }
}
