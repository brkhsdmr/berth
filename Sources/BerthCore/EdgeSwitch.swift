import CoreGraphics

/// İmleç ekranın sol ya da sağ dış kenarına değince bir masaüstü sola ya da sağa geçmenin kuralları.
public enum EdgeSwitch {
    public enum Side: Equatable, Sendable { case left, right }

    /// Kenarın dikeyde ortadaki etkin bölümü için seçenekler (üst ve alt menü çubuğu, Dock ve
    /// köşeler için boş kalır).
    public static let bandChoices: [Double] = [0.3, 0.5, 0.7, 1.0]
    public static let defaultBand = 0.5

    /// Geçiş için basılı tutulması gereken niteleme tuşları; boşsa kenara değmek yeter.
    public struct HoldKeys: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = HoldKeys(rawValue: 1 << 0)
        public static let option = HoldKeys(rawValue: 1 << 1)
        public static let shift = HoldKeys(rawValue: 1 << 2)
        public static let command = HoldKeys(rawValue: 1 << 3)
        public static let function = HoldKeys(rawValue: 1 << 4)

        /// Apple'ın menü sırası: fn ⌃ ⌥ ⇧ ⌘.
        public var display: String {
            var text = ""
            if contains(.function) { text += "fn " }
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            return text.trimmingCharacters(in: .whitespaces)
        }

        /// Basılı olanlar istenenleri içeriyor mu (fazladan basılı tuş engel değil).
        public func isHeld(in pressed: HoldKeys) -> Bool { pressed.isSuperset(of: self) }
    }

    /// `point`, ekranlardan birinin dış sol ya da sağ kenarına `margin` içinde ve dikeyde ortadaki
    /// `band` oranındaysa o kenar. Yanında başka ekran olan kenar sayılmaz: imleç oradan öbür
    /// ekrana geçer. Koordinatlar AppKit'inki (y yukarı); yalnızca oranlar kullanıldığı için fark etmez.
    public static func side(at point: CGPoint, screens: [CGRect], band: Double, margin: CGFloat) -> Side? {
        // İmleç sağ kenarda maxX'e eşit olabilir; `contains` onu dışarıda sayar.
        guard let frame = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { return nil }
        let ratio = CGFloat(min(1, max(0.1, band)))
        let inset = frame.height * (1 - ratio) / 2
        guard point.y >= frame.minY + inset, point.y <= frame.maxY - inset else { return nil }

        func hasNeighbour(onLeft: Bool) -> Bool {
            screens.contains { other in
                guard other != frame, other.maxY > frame.minY, other.minY < frame.maxY else { return false }
                return onLeft ? abs(other.maxX - frame.minX) < 1 : abs(other.minX - frame.maxX) < 1
            }
        }

        if point.x - frame.minX <= margin, !hasNeighbour(onLeft: true) { return .left }
        // mouseLocation sağ kenarda en fazla maxX - 1'e ulaşır.
        if frame.maxX - point.x <= margin + 1, !hasNeighbour(onLeft: false) { return .right }
        return nil
    }
}
