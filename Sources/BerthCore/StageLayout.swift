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
