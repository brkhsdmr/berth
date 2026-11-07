import CoreGraphics
import Foundation

/// Uygulama hücresinin boyutu. Yalnızca kullanıcı değiştirir; pencere sayısı değiştirmez.
public enum SlotSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var units: Int {
        switch self {
        case .small: return 2
        case .medium: return 3
        case .large: return 4
        }
    }

    /// Uygulama ilk görüldüğünde verilen boyut. Sonra saklanır ve kendiliğinden değişmez.
    public static func initial(windowCount: Int) -> SlotSize {
        switch windowCount {
        case ...1: return .small
        case 2...3: return .medium
        default: return .large
        }
    }
}

public struct SlotSpec: Equatable, Sendable {
    public var id: String
    public var size: SlotSize
    public init(id: String, size: SlotSize) {
        self.id = id
        self.size = size
    }
}

public struct PlacedSlot: Equatable, Sendable {
    public var id: String
    public var size: SlotSize
    /// Yığın ve etiket dahil hücre.
    public var frame: CGRect
    /// Pencerelerin dizildiği alan.
    public var pile: CGRect
}

/// Sürüklenen hücrenin bırakılacağı aralık ve aralığı gösteren çizgi.
public struct SlotDrop: Equatable, Sendable {
    /// `Arrangement.move(_:toGap:)` için aralık.
    public var gap: Int
    public var markX: CGFloat
    public var markMinY: CGFloat
    public var markMaxY: CGFloat
}

public struct StageMetrics: Sendable {
    public var gap: CGFloat = 20
    public var rowGap: CGFloat = 18
    public var labelHeight: CGFloat = 32
    public var maxRows = 6
    public init() {}
}

/// Hücrelerin yerini hesaplar.
///
/// Girdi yalnızca sıra ve hücre boyutudur. **Pencere sayısı girdi değildir**, bu yüzden
/// bir pencere açmak ya da kapatmak hiçbir hücrenin yerini değiştiremez.
public enum StageLayout {

    public static func place(_ slots: [SlotSpec], in stage: CGRect, metrics: StageMetrics = StageMetrics()) -> [PlacedSlot] {
        guard !slots.isEmpty, stage.width > 0, stage.height > 0 else { return [] }

        let total = slots.reduce(0) { $0 + $1.size.units }
        let widest = slots.map(\.size.units).max() ?? 2

        var best: (score: CGFloat, rows: [[SlotSpec]], unitsPerRow: Int)?
        for target in 1...min(slots.count, metrics.maxRows) {
            var unitsPerRow = max(widest, Int((Double(total) / Double(target)).rounded(.up)))
            var rows = pack(slots, unitsPerRow: unitsPerRow)
            while rows.count > target {
                unitsPerRow += 1
                rows = pack(slots, unitsPerRow: unitsPerRow)
            }
            let score = tileWidth(unitsPerRow: unitsPerRow, rowCount: rows.count, stage: stage, metrics: metrics)
            if best == nil || score > best!.score + 0.5 {
                best = (score, rows, unitsPerRow)
            }
        }
        guard let chosen = best else { return [] }

        let unit = unitWidth(unitsPerRow: chosen.unitsPerRow, stage: stage, metrics: metrics)
        let widestSlot = slotWidth(units: widest, unit: unit, gap: metrics.gap)
        let rowCount = CGFloat(chosen.rows.count)
        let available = (stage.height - (rowCount - 1) * metrics.rowGap) / rowCount
        // Çok az uygulama varken hücreler ekranı dikine doldurmasın.
        let rowHeight = min(available, widestSlot * 0.72 + metrics.labelHeight)
        let blockHeight = rowCount * rowHeight + (rowCount - 1) * metrics.rowGap
        var y = stage.minY + (stage.height - blockHeight) / 2

        var placed: [PlacedSlot] = []
        for row in chosen.rows {
            let widths = row.map { slotWidth(units: $0.size.units, unit: unit, gap: metrics.gap) }
            let rowWidth = widths.reduce(0, +) + CGFloat(row.count - 1) * metrics.gap
            var x = stage.minX + (stage.width - rowWidth) / 2
            for (slot, width) in zip(row, widths) {
                let frame = CGRect(x: x, y: y, width: width, height: rowHeight)
                let pile = CGRect(x: x, y: y, width: width, height: rowHeight - metrics.labelHeight)
                placed.append(PlacedSlot(id: slot.id, size: slot.size, frame: frame, pile: pile))
                x += width + metrics.gap
            }
            y += rowHeight + metrics.rowGap
        }
        return placed
    }

    /// Kaydırılarak ulaşılan bölüm: hücreler `top`tan başlar, ortalanmaz. Uygulama çoğaldıkça bölüm
    /// uzar; hücreler tek ekrana sığsın diye küçülmez.
    public static func placeFlowing(
        _ slots: [SlotSpec],
        x: CGFloat,
        width: CGFloat,
        top: CGFloat,
        viewportHeight: CGFloat,
        metrics: StageMetrics = StageMetrics()
    ) -> [PlacedSlot] {
        let pages = max(1, (slots.count + flowingSlotsPerPage - 1) / flowingSlotsPerPage)
        var flowing = metrics
        flowing.maxRows = metrics.maxRows * pages
        let stage = CGRect(x: x, y: top, width: width, height: viewportHeight * CGFloat(pages))
        let placed = place(slots, in: stage, metrics: flowing)
        guard let first = placed.first else { return [] }
        let shift = top - first.frame.minY
        return placed.map { slot in
            var moved = slot
            moved.frame.origin.y += shift
            moved.pile.origin.y += shift
            return moved
        }
    }

    private static let flowingSlotsPerPage = 12

    /// İmlecin altındaki aralık. Satır, imlece dikine en yakın olandır; hücrenin yeri değişmeyecekse
    /// (kendi iki yanı) nil döner.
    /// - Parameter slots: Yerleşim sırasıyla hücreler (`place` sonucu).
    public static func drop(
        at point: CGPoint,
        moving id: String,
        in slots: [PlacedSlot],
        metrics: StageMetrics = StageMetrics()
    ) -> SlotDrop? {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return nil }

        var rows: [Range<Int>] = []
        var start = 0
        for current in slots.indices.dropFirst() where slots[current].frame.minY != slots[start].frame.minY {
            rows.append(start..<current)
            start = current
        }
        rows.append(start..<slots.count)

        func distance(_ row: Range<Int>) -> CGFloat {
            let frame = slots[row.lowerBound].frame
            return max(frame.minY - point.y, point.y - frame.maxY, 0)
        }
        guard let row = rows.min(by: { distance($0) < distance($1) }) else { return nil }

        let gap = row.first { point.x < slots[$0].frame.midX } ?? row.upperBound
        guard gap != index, gap != index + 1 else { return nil }
        let x = gap < row.upperBound
            ? slots[gap].frame.minX - metrics.gap / 2
            : slots[row.upperBound - 1].frame.maxX + metrics.gap / 2
        let frame = slots[row.lowerBound].frame
        return SlotDrop(gap: gap, markX: x, markMinY: frame.minY, markMaxY: frame.maxY)
    }

    static func pack(_ slots: [SlotSpec], unitsPerRow: Int) -> [[SlotSpec]] {
        var rows: [[SlotSpec]] = []
        var current: [SlotSpec] = []
        var used = 0
        for slot in slots {
            if used + slot.size.units > unitsPerRow, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(slot)
            used += slot.size.units
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private static func unitWidth(unitsPerRow: Int, stage: CGRect, metrics: StageMetrics) -> CGFloat {
        let count = CGFloat(unitsPerRow)
        return (stage.width - (count - 1) * metrics.gap) / count
    }

    private static func slotWidth(units: Int, unit: CGFloat, gap: CGFloat) -> CGFloat {
        CGFloat(units) * unit + CGFloat(units - 1) * gap
    }

    /// Küçük bir hücreye 16:10 pencere sığdığında alacağı genişlik: düzenlerin karşılaştırma ölçütü.
    private static func tileWidth(unitsPerRow: Int, rowCount: Int, stage: CGRect, metrics: StageMetrics) -> CGFloat {
        let unit = unitWidth(unitsPerRow: unitsPerRow, stage: stage, metrics: metrics)
        let width = slotWidth(units: SlotSize.small.units, unit: unit, gap: metrics.gap)
        let rows = CGFloat(rowCount)
        let rowHeight = (stage.height - (rows - 1) * metrics.rowGap) / rows
        return min(width, (rowHeight - metrics.labelHeight) * 1.6)
    }
}
