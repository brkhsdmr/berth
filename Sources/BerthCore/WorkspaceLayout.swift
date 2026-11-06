import CoreGraphics
import Foundation

/// Kaydedilmiş çalışma düzeni: pencerelerin yeri, boyutu ve küçültülmüş olup olmadığı.
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var appID: String
        public var title: String
        /// Pencere koordinatları (ana ekranın sol üstü orijin).
        public var frame: CGRect
        public var minimized: Bool
        /// Kaydedildiği andaki pencere kimliği; pencere hâlâ açıksa önce o eşleşir.
        public var windowID: UInt32?

        public init(appID: String, title: String, frame: CGRect, minimized: Bool, windowID: UInt32? = nil) {
            self.appID = appID
            self.title = title
            self.frame = frame
            self.minimized = minimized
            self.windowID = windowID
        }
    }

    /// Düzeni yükleyen genel kısayol (Carbon tuş kodu ve değiştiriciler).
    public struct HotKey: Codable, Equatable, Sendable {
        public var keyCode: UInt32
        public var modifiers: UInt32
        public var display: String
        public init(keyCode: UInt32, modifiers: UInt32, display: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.display = display
        }
    }

    public var name: String
    public var savedAt: Date
    public var windows: [Window]
    public var hotKey: HotKey?

    public init(name: String, savedAt: Date, windows: [Window], hotKey: HotKey? = nil) {
        self.name = name
        self.savedAt = savedAt
        self.windows = windows
        self.hotKey = hotKey
    }

    /// Düzendeki uygulamalar, ilk görüldükleri sırayla ve bir kez.
    public var appIDs: [String] {
        var seen = Set<String>()
        return windows.map(\.appID).filter { seen.insert($0).inserted }
    }
}

/// Kayıttaki pencereleri şu anki pencerelerle eşleştirir.
///
/// Önce aynı pencere (kimliği hâlâ geçerliyse), sonra aynı uygulama ve aynı başlık; kalanlar aynı uygulamanın kalan pencereleriyle sırayla.
/// Başlıklar değişebilir (açık sekme, belge adı): ikinci tur bunu karşılar. Her pencere en çok
/// bir kez kullanılır.
public enum LayoutMatcher {
    public struct Candidate: Equatable, Sendable {
        public var appID: String
        public var title: String
        public var windowID: UInt32?
        public init(appID: String, title: String, windowID: UInt32? = nil) {
            self.appID = appID
            self.title = title
            self.windowID = windowID
        }
    }

    /// (kayıt sırası, şu anki sıra) çiftleri, kayıt sırasına göre.
    public static func match(saved: [WorkspaceLayout.Window], current: [Candidate]) -> [(saved: Int, current: Int)] {
        var used = Set<Int>()
        var result: [Int: Int] = [:]
        for (i, window) in saved.enumerated() {
            guard let id = window.windowID else { continue }
            if let j = current.indices.first(where: { !used.contains($0) && current[$0].windowID == id && current[$0].appID == window.appID }) {
                used.insert(j)
                result[i] = j
            }
        }
        for (i, window) in saved.enumerated() where result[i] == nil {
            if let j = current.indices.first(where: { !used.contains($0) && current[$0].appID == window.appID && current[$0].title == window.title }) {
                used.insert(j)
                result[i] = j
            }
        }
        for (i, window) in saved.enumerated() where result[i] == nil {
            if let j = current.indices.first(where: { !used.contains($0) && current[$0].appID == window.appID }) {
                used.insert(j)
                result[i] = j
            }
        }
        return result.keys.sorted().map { ($0, result[$0]!) }
    }

    /// Kaydedilecek yeni düzenin adı: "Düzen 1", "Düzen 2"… boş olan ilk numara.
    public static func nextName(existing: [String]) -> String {
        var number = 1
        while existing.contains("Düzen \(number)") { number += 1 }
        return "Düzen \(number)"
    }
}
