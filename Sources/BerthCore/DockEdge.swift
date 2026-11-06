import CoreGraphics

/// Dock'un durduğu kenar ve tam ekrandaki şeridin yerleşimi. Görünüm uzayı: sol alt orijin (NSScreen).
public enum DockEdge: String, Sendable {
    case left, right, bottom

    /// `com.apple.dock orientation` değeri; bilinmeyen değer varsayılan olan alta düşer.
    public init(orientation: String?) {
        self = DockEdge(rawValue: orientation ?? "") ?? .bottom
    }

    public var isVertical: Bool { self != .bottom }

    /// İmleç bu kenara değiyor mu? Köşeler hariç: oralar sıcak köşeler ve menü çubuğu içindir.
    public func isTouched(by point: CGPoint, screen: CGRect, tolerance: CGFloat = 1.5, cornerMargin: CGFloat = 48) -> Bool {
        switch self {
        case .right:
            return point.x >= screen.maxX - tolerance
                && point.y > screen.minY + cornerMargin && point.y < screen.maxY - cornerMargin
        case .left:
            return point.x <= screen.minX + tolerance
                && point.y > screen.minY + cornerMargin && point.y < screen.maxY - cornerMargin
        case .bottom:
            return point.y <= screen.minY + tolerance
                && point.x > screen.minX + cornerMargin && point.x < screen.maxX - cornerMargin
        }
    }

    /// Şeridin ekrandaki karesi: kenara yaslı, ortalı, ekrana sığacak kadar.
    public func stripFrame(length: CGFloat, thickness: CGFloat, screen: CGRect, margin: CGFloat = 4) -> CGRect {
        switch self {
        case .right:
            let height = min(length, screen.height - 2 * margin)
            return CGRect(x: screen.maxX - thickness - margin, y: screen.midY - height / 2, width: thickness, height: height)
        case .left:
            let height = min(length, screen.height - 2 * margin)
            return CGRect(x: screen.minX + margin, y: screen.midY - height / 2, width: thickness, height: height)
        case .bottom:
            let width = min(length, screen.width - 2 * margin)
            return CGRect(x: screen.midX - width / 2, y: screen.minY + margin, width: width, height: thickness)
        }
    }

    /// Kayarak açılışın başladığı kare: kenarın dışında.
    public func hiddenFrame(from frame: CGRect, screen: CGRect) -> CGRect {
        var out = frame
        switch self {
        case .right: out.origin.x = screen.maxX
        case .left: out.origin.x = screen.minX - frame.width
        case .bottom: out.origin.y = screen.minY - frame.height
        }
        return out
    }
}
