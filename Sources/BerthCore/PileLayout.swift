import CoreGraphics

/// Bir uygulamanın pencerelerini kendi hücresinin içine dizer.
public enum PileLayout {

    /// Yığında gösterilen en fazla pencere; kalanı "+N" olur.
    public static let maxVisible = 6

    /// `aspects` en-boy oranlarıdır; dönen kareler aynı sıradadır (sonraki öndedir).
    /// Yığın alanın dibine oturur: pencereler altındaki etikete yakın durur.
    public static func frames(in rect: CGRect, aspects: [CGFloat], overlap: CGFloat = 0.1) -> [CGRect] {
        let count = aspects.count
        guard count > 0, rect.width > 0, rect.height > 0 else { return [] }
        let safe = aspects.map { $0 > 0.01 ? $0 : 1.6 }

        var bestColumns = 1
        var bestScore: CGFloat = -1
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let cell = cellSize(rect, columns: columns, rows: rows, overlap: overlap)
            let score = safe.map { aspect -> CGFloat in
                let fitted = fit(aspect, in: cell)
                return fitted.width * fitted.height
            }.min() ?? 0
            if score > bestScore * 1.001 {
                bestScore = score
                bestColumns = columns
            }
        }

        let columns = bestColumns
        let rows = (count + columns - 1) / columns
        let cell = cellSize(rect, columns: columns, rows: rows, overlap: overlap)
        let stepX = cell.width * (1 - overlap)
        let stepY = cell.height * (1 - overlap)

        // Hücreler yüksekliğin izin verdiğinden kısa pencerelerle dolunca boşluk üste kalsın.
        let tallest = safe.map { fit($0, in: cell).height }.max() ?? cell.height
        let usedHeight = stepY * CGFloat(rows - 1) + tallest
        let gridTop = rect.maxY - usedHeight

        var result: [CGRect] = []
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            let inRow = row == rows - 1 ? count - row * columns : columns
            let rowWidth = stepX * CGFloat(inRow - 1) + cell.width
            let originX = rect.minX + (rect.width - rowWidth) / 2 + CGFloat(column) * stepX
            let originY = gridTop + CGFloat(row) * stepY

            let size = fit(safe[index], in: cell)
            var frame = CGRect(
                x: originX + (cell.width - size.width) / 2,
                y: originY + tallest - size.height,
                width: size.width,
                height: size.height
            )
            // Tek sütun ve sırada kaydırma yok; çoklu dizilimde hafif kademe yığın hissi verir.
            if count > 1, inRow > 1 {
                frame.origin.y += (column % 2 == 0 ? -1 : 1) * cell.height * 0.03
            }
            result.append(clamp(frame, to: rect))
        }
        return result
    }

    private static func cellSize(_ rect: CGRect, columns: Int, rows: Int, overlap: CGFloat) -> CGSize {
        let c = CGFloat(columns)
        let r = CGFloat(rows)
        return CGSize(
            width: rect.width / (c - (c - 1) * overlap),
            height: rect.height / (r - (r - 1) * overlap)
        )
    }

    private static func fit(_ aspect: CGFloat, in cell: CGSize) -> CGSize {
        let width = min(cell.width, cell.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private static func clamp(_ frame: CGRect, to rect: CGRect) -> CGRect {
        var out = frame
        out.origin.x = min(max(out.minX, rect.minX), rect.maxX - out.width)
        out.origin.y = min(max(out.minY, rect.minY), rect.maxY - out.height)
        return out
    }
}
