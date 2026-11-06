import CoreGraphics

/// Ekran Kaydı izni yokken pencere başlığı listeden okunamaz; bu kurallar yedek yolu tanımlar.
public enum WindowNaming {
    /// Başlık yoksa pencereleri birbirinden ayıran bir ad.
    public static func display(title: String, appName: String, index: Int, windowCount: Int) -> String {
        if !title.isEmpty { return title }
        return windowCount > 1 ? tx("\(appName) · Pencere \(index + 1)", "\(appName) · Window \(index + 1)") : appName
    }

    /// Erişilebilirlikten okunan pencerelerden kareyle eşleşen. Birden çok aday varsa nil:
    /// tam ekran pencereler aynı kareyi paylaşır, yanlış başlık yazmaktansa başlıksız kalmak iyidir.
    public static func uniqueMatch<Element>(
        frame: CGRect,
        candidates: [(element: Element, frame: CGRect)],
        tolerance: CGFloat = 6
    ) -> Element? {
        let matches = candidates.filter {
            abs($0.frame.minX - frame.minX) <= tolerance && abs($0.frame.minY - frame.minY) <= tolerance
                && abs($0.frame.width - frame.width) <= tolerance && abs($0.frame.height - frame.height) <= tolerance
        }
        return matches.count == 1 ? matches[0].element : nil
    }
}
