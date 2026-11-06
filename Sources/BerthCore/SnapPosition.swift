import CoreGraphics

/// Tek pencereyi yaslama hedefleri.
public enum SnapPosition: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, fill

    public var label: String {
        switch self {
        case .leftHalf: return "Sola yasla"
        case .rightHalf: return "Sağa yasla"
        case .fill: return "Ekranı kapla"
        }
    }

    public var symbolName: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .fill: return "rectangle.fill"
        }
    }

    /// Kare, verilen çalışma alanının içindedir (menü çubuğu ve Dock zaten dışındadır).
    /// İki yarım tam noktada buluşur: arada çizgi kalmaz, üst üste de binmezler.
    public func frame(in workArea: CGRect) -> CGRect {
        guard workArea.width > 0, workArea.height > 0 else { return .zero }
        let split = (workArea.width / 2).rounded()
        switch self {
        case .fill:
            return workArea
        case .leftHalf:
            return CGRect(x: workArea.minX, y: workArea.minY, width: split, height: workArea.height)
        case .rightHalf:
            return CGRect(x: workArea.minX + split, y: workArea.minY, width: workArea.width - split, height: workArea.height)
        }
    }
}
