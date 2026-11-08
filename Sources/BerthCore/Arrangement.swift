import Foundation

/// Kullanıcının kurduğu düzen: sabit uygulamalar, sıraları ve hücre boyutları.
public struct Arrangement: Codable, Equatable, Sendable {
    public var pinned: [String]
    public var sizes: [String: SlotSize]

    public init(pinned: [String] = [], sizes: [String: SlotSize] = [:]) {
        self.pinned = pinned
        self.sizes = sizes
    }

    public func size(of id: String) -> SlotSize { sizes[id] ?? .small }

    /// Sabit olmayan uygulamanın hücre boyutu: daha önce sabitlendiyse saklı boyutu, yoksa pencere
    /// sayısından gelir. Boyut saklanmaz, çünkü sabit olmayan uygulamanın sabit bir yeri de yok.
    public func unpinnedSize(of id: String, windowCount: Int) -> SlotSize {
        sizes[id] ?? .initial(windowCount: windowCount)
    }

    public var specs: [SlotSpec] {
        pinned.map { SlotSpec(id: $0, size: size(of: $0)) }
    }

    /// Daha önce boyutu belirlenmemiş uygulamaya ilk boyutunu verir. Var olanı değiştirmez.
    /// - Returns: Bir şey değiştiyse `true`.
    @discardableResult
    public mutating func assignInitialSizeIfNeeded(id: String, windowCount: Int) -> Bool {
        guard sizes[id] == nil else { return false }
        sizes[id] = .initial(windowCount: windowCount)
        return true
    }

    public mutating func pin(_ id: String, windowCount: Int) {
        guard !pinned.contains(id) else { return }
        pinned.append(id)
        assignInitialSizeIfNeeded(id: id, windowCount: windowCount)
    }

    public mutating func unpin(_ id: String) {
        pinned.removeAll { $0 == id }
    }

    public mutating func move(_ id: String, by offset: Int) {
        guard let index = pinned.firstIndex(of: id) else { return }
        let target = min(max(index + offset, 0), pinned.count - 1)
        guard target != index else { return }
        pinned.remove(at: index)
        pinned.insert(id, at: target)
    }

    /// Uygulamayı iki hücrenin arasına taşır. `gap`, taşımadan önceki sıraya göredir: 0 en baş,
    /// `pinned.count` en son.
    public mutating func move(_ id: String, toGap gap: Int) {
        guard let index = pinned.firstIndex(of: id) else { return }
        let bounded = min(max(gap, 0), pinned.count)
        pinned.remove(at: index)
        pinned.insert(id, at: bounded > index ? bounded - 1 : bounded)
    }
}

/// Masaüstü adları. macOS normal masaüstlerine ad vermez, tam ekranlarda pencere başlığı vardır.
public enum SpaceNaming {
    public struct Input: Equatable, Sendable {
        public var isFullScreen: Bool
        public var name: String
        public init(isFullScreen: Bool, name: String) {
            self.isFullScreen = isFullScreen
            self.name = name
        }
    }

    public static func labels(_ spaces: [Input]) -> [String] {
        let desktops = spaces.filter { !$0.isFullScreen }.count
        var desktopIndex = 0
        return spaces.map { space in
            if space.isFullScreen {
                return space.name.isEmpty ? tx("Tam ekran", "Full screen") : space.name
            }
            desktopIndex += 1
            return desktops > 1 ? tx("Masaüstü \(desktopIndex)", "Desktop \(desktopIndex)") : tx("Masaüstü", "Desktop")
        }
    }
}

/// Pencere listesindeki gürültüyü ayıklayan kural.
public enum WindowFilter {
    public static let minimumSize = CGSize(width: 80, height: 60)

    /// - Parameters:
    ///   - hasSpace: Pencere bir masaüstüne bağlı mı.
    ///   - canReadTitles: Ekran Kaydı izni var mı; yoksa başlıklar hep boş gelir.
    public static func isUserWindow(
        title: String,
        isOnScreen: Bool,
        hasSpace: Bool,
        size: CGSize,
        canReadTitles: Bool
    ) -> Bool {
        guard size.width >= minimumSize.width, size.height >= minimumSize.height else { return false }
        if canReadTitles {
            // Başlıklı pencere gerçektir (masaüstü bilgisi yoksa küçültülmüş ya da gizlidir).
            // Başlıksız pencere ancak o an gerçekten ekrandaysa kullanıcı penceresidir:
            // uygulamaların çerçeve, gölge ve hayalet pencereleri başlıksız ve ekran dışıdır.
            if !title.isEmpty { return true }
            // Boyut şartı da gerekli: Chrome tam ekrandayken araç çubuğunu ayrı, başlıksız ve
            // ekranda duran bir şerit olarak tutuyor (ölçüldü: 1710x149 ve 1710x81).
            return isOnScreen && hasSpace && size.width >= 200 && size.height >= 200
        }
        // Başlık yoksa eleme zayıflar: çerçeve pencerelerini atmak için büyüklüğe bakılır.
        return hasSpace && size.width >= 300 && size.height >= 200
    }

    /// Üst kenarı kendi ekranının üstünde kalan pencere, uygulamanın park ettiği gizli penceredir.
    /// macOS kullanıcının başlık çubuğunu menü çubuğunun üstüne taşımasına izin vermez.
    public static func isParked(_ frame: CGRect, screens: [CGRect]) -> Bool {
        guard !screens.isEmpty else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let host = screens.first { $0.contains(center) }
            ?? screens.max { area($0.intersection(frame)) < area($1.intersection(frame)) }
        guard let host, area(host.intersection(frame)) > 0 else { return true }
        return frame.minY < host.minY
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}

/// Yazarak arama: büyük/küçük harf ve Türkçe işaretlerden bağımsız.
public enum SearchMatcher {
    public static func normalize(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
    }

    public static func matches(query: String, in fields: [String]) -> Bool {
        let needle = normalize(query).trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return fields.contains { normalize($0).contains(needle) }
    }

    /// Ad aramaya ne kadar uyuyor: 0 adın başı, 1 bir sözcüğün başı, 2 içinde; uymuyorsa nil.
    public static func rank(query: String, name: String) -> Int? {
        let needle = normalize(query).trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        let hay = normalize(name)
        if hay.hasPrefix(needle) { return 0 }
        let words = hay.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" })
        if words.contains(where: { $0.hasPrefix(needle) }) { return 1 }
        return hay.contains(needle) ? 2 : nil
    }
}

/// Windows App oturum penceresinin, Mac'e bağlı hangi Windows'a ait olduğunu bulur.
///
/// Windows bağlanırken bilgisayar adını gönderir ("OFFICEPC"); oturum penceresinin başlığı
/// kullanıcının verdiği addır ("Office PC Tailscale"). Harf, boşluk ve aksan farkları atılarak
/// başlığın içinde bilgisayar adı aranır.
public enum RemoteSessionMatcher {
    public static func key(_ text: String) -> String {
        SearchMatcher.normalize(text).filter { $0.isLetter || $0.isNumber }
    }

    /// Başlığa uyan bağlı bilgisayar; yoksa nil. `aliases` bilgisayar adından (büyük/küçük harf
    /// fark etmez) Windows App'teki oturum adına: oturum adı bilgisayarın adını taşımıyorsa
    /// kullanıcı ayarlardan verir. Önce oturum adları denenir.
    public static func match(title: String, computers: [String], aliases: [String: String] = [:]) -> String? {
        let haystack = key(title)
        let byAlias = computers.first { computer in
            guard let alias = aliases[computer.lowercased()], !key(alias).isEmpty else { return false }
            return haystack.contains(key(alias))
        }
        return byAlias ?? computers.first { !key($0).isEmpty && haystack.contains(key($0)) }
    }
}
