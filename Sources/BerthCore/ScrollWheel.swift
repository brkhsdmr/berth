import Foundation

/// Fare tekerleğinde Windows gibi kaydırma: her çentik sabit sayıda satır.
///
/// macOS tekerleğe ivme uygular: yavaş, tek tek çevrilen çentik çok az kaydırır, hızlı çevirdikçe
/// artar. Windows'ta her çentik (varsayılan) 3 satırdır. Burada çentik başına satır sabitlenir,
/// ivme kalkar. Yalnızca satırlı (sürekli olmayan) olaylar: trackpad ve Magic Mouse'un hassas
/// kaydırması değişmez.
public enum ScrollWheel {
    public static let lineRange = 1...10
    public static let defaultLines = 3
    /// macOS'un bir satıra verdiği piksel (ivmesiz, `kCGScrollWheelEventPointDeltaAxis*`).
    public static let pointsPerLine = 10.0

    public struct Delta: Equatable, Sendable {
        public var lines: Int64
        public var fixed: Double
        public var points: Int64
    }

    /// Bir eksendeki olay değerlerinden (satır, sabit noktalı satır) yönü alır, `lines` satıra çevirir.
    /// Hareket yoksa `nil`.
    public static func flattened(lines delta: Int64, fixed: Double, to lines: Int) -> Delta? {
        let sign: Int64 = delta != 0 ? (delta > 0 ? 1 : -1) : fixed > 0 ? 1 : fixed < 0 ? -1 : 0
        guard sign != 0 else { return nil }
        let count = Int64(min(lineRange.upperBound, max(lineRange.lowerBound, lines)))
        return Delta(lines: sign * count, fixed: Double(sign * count), points: sign * count * Int64(pointsPerLine))
    }
}

/// Çentiği Windows'taki gibi yumuşak kaydırmaya çevirir: her çentik hedefe piksel ekler, hedef
/// kısa sürede azalan adımlarla (piksel cinsinden sürekli olaylar) gönderilir. Satırlı olay doğrudan
/// geçerse Chrome gibi uygulamalar çentikte sıçrar, takılıyormuş gibi görünür.
public struct SmoothScroll: Equatable, Sendable {
    /// Windows'ta 3 satır Chrome'da yaklaşık 100 piksel; 33'te Mac'te yavaş bulundu, 40 (2026-11-20).
    public static let pointsPerLine = 40.0
    /// Her adımda kalanın gönderilen oranı; 120 Hz'de yaklaşık 100 ms'de biter (0,25 ağır geldi).
    static let rate = 0.35

    public private(set) var remainingY = 0.0
    public private(set) var remainingX = 0.0
    private var carryY = 0.0
    private var carryX = 0.0

    public init() {}

    public var isIdle: Bool { remainingY == 0 && remainingX == 0 }

    /// Hızlı çevirmede çentik başına mesafe en çok bu kat büyür.
    public static let maxBoost = 4.0
    /// Çentikler bu aralıktan (sn) seyrekse büyütme yok; sıklaştıkça artar.
    static let boostInterval = 0.1

    /// Önceki çentikten `interval` sn sonra gelen çentiğin katı: tek tek çevirmede 1, hızlı
    /// çevirdikçe `maxBoost`'a kadar. Tekerleği tekrar tekrar çevirmeden uzağa gidilsin.
    public static func boost(interval: TimeInterval) -> Double {
        guard interval > 0, interval < boostInterval else { return 1 }
        return min(maxBoost, boostInterval / interval)
    }

    /// Bir çentik: `lines` satır × `boost`, yön işaretle. Ters yöne dönülürse kalan bırakılır.
    public mutating func add(vertical: Int64, horizontal: Int64, lines: Int, boost: Double = 1) {
        let count = Double(min(ScrollWheel.lineRange.upperBound, max(ScrollWheel.lineRange.lowerBound, lines))) * max(1, boost)
        if vertical != 0 {
            let amount = Double(vertical.signum()) * count * Self.pointsPerLine
            if remainingY != 0, (remainingY > 0) != (amount > 0) { remainingY = 0 }
            remainingY += amount
        }
        if horizontal != 0 {
            let amount = Double(horizontal.signum()) * count * Self.pointsPerLine
            if remainingX != 0, (remainingX > 0) != (amount > 0) { remainingX = 0 }
            remainingX += amount
        }
    }

    /// Bu adımda gönderilecek tam pikseller (dikey, yatay).
    public mutating func step() -> (y: Int32, x: Int32) {
        var y = remainingY, cy = carryY, x = remainingX, cx = carryX
        let stepY = Self.take(&y, carry: &cy), stepX = Self.take(&x, carry: &cx)
        remainingY = y; carryY = cy; remainingX = x; carryX = cx
        return (stepY, stepX)
    }

    private static func portion(_ remaining: Double) -> Double {
        let part = remaining * Self.rate
        // Son pikseller sürünmesin.
        return abs(remaining) <= 2 ? remaining : (abs(part) < 1 ? (remaining > 0 ? 1 : -1) : part)
    }

    private static func take(_ remaining: inout Double, carry: inout Double) -> Int32 {
        guard remaining != 0 else { carry = 0; return 0 }
        let part = portion(remaining)
        remaining -= part
        if abs(remaining) < 0.01 { remaining = 0 }
        let exact = part + carry
        // Son adımda artan kesir de gönderilir: çentiğin tamamı gitsin.
        let whole = remaining == 0 ? exact.rounded() : exact.rounded(.towardZero)
        carry = remaining == 0 ? 0 : exact - whole
        return Int32(whole)
    }
}
