import AppKit
import BerthCore
import QuartzCore

@MainActor
protocol SceneViewDelegate: AnyObject {
    func sceneDidRequestDismiss()
    func scene(didChoose window: SceneWindow)
    func scene(didSnap window: SceneWindow, to position: SnapPosition)
    func scene(didClose window: SceneWindow)
    func scene(didMinimize window: SceneWindow)
    func scene(didMoveToNextDisplay window: SceneWindow)
    func scene(didToggleFullScreen window: SceneWindow, entering: Bool)
    /// Pencere şeritte iki alanın arasına bırakıldı. `before` sağındaki alan; nil ise en sağ.
    func scene(didDrop window: SceneWindow, before: UInt64?)
    /// Şeritteki alan sürüklenip iki alanın arasına bırakıldı.
    func scene(didChooseApp app: SceneApp)
    /// Açık olmayan, kurulu bir uygulama aramadan seçildi.
    func scene(didLaunchApp url: URL)
    func scene(didChooseSpace space: SceneSpace)
    func sceneDidRequestScreenRecordingSettings()
    func sceneDidRequestAccessibilitySettings()
    func scene(changeArrangement change: (inout Arrangement) -> Void)
}

/// Önizlemenin köşesindeki düğmeler.
enum TileAction: Equatable {
    case snap(SnapPosition)
    /// `entering` true ise tam ekran yapar, false ise tam ekrandan çıkarır.
    case fullScreen(entering: Bool)
    case minimize
    case nextDisplay
    case close

    /// Tam ekran pencere küçültülemez ve ekran değiştiremez (macOS izin vermiyor); küçültülmüş
    /// olanda küçült düğmesi anlamsız. Ekran düğmesi yalnızca birden çok ekranda çıkar.
    static func all(isFullScreen: Bool, isMinimized: Bool, multipleDisplays: Bool) -> [TileAction] {
        let minimize: [TileAction] = isFullScreen || isMinimized ? [] : [.minimize]
        let display: [TileAction] = multipleDisplays && !isFullScreen ? [.nextDisplay] : []
        return SnapPosition.allCases.map(TileAction.snap) + display + [.fullScreen(entering: !isFullScreen)] + minimize + [.close]
    }

    var label: String {
        switch self {
        case .snap(let position): return position.label
        case .fullScreen(let entering): return entering ? tx("Tam ekran yap", "Enter full screen") : tx("Tam ekrandan çık", "Exit full screen")
        case .minimize: return tx("Dock'a küçült", "Minimize to Dock")
        case .nextDisplay: return tx("Diğer ekrana taşı", "Move to next display")
        case .close: return tx("Pencereyi kapat", "Close window")
        }
    }

    var symbolName: String {
        switch self {
        case .snap(let position): return position.symbolName
        case .fullScreen(let entering):
            return entering ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
        case .minimize: return "minus"
        case .nextDisplay: return "rectangle.on.rectangle"
        case .close: return "xmark"
        }
    }

    /// Yıkıcı eylem üstüne gelince kırmızı olur.
    var hoverColor: NSColor {
        switch self {
        case .snap, .fullScreen, .minimize, .nextDisplay: return NSColor(calibratedWhite: 1, alpha: 0.26)
        case .close: return NSColor.systemRed
        }
    }
}

struct SceneContent {
    var snapshot: SceneSnapshot
    var arrangement: Arrangement
    /// Dock ve menü çubuğu dışındaki alan; görünüm uzayında (sol üst orijin).
    var usable: CGRect
    /// Ekranın CGWindowList uzayındaki sol üst köşesi.
    var screenOrigin: CGPoint
    var backingScale: CGFloat
    var wallpaper: WallpaperStore.Entry?
    /// Pencere görüntüleri bekleniyor mu? Yoksa kartlar simge ve başlıkla çizilir.
    var previewsAvailable: Bool
    /// Aşağı kaydırınca sabit olmayan uygulamalar kendi hücreleriyle listelenir.
    var showsOtherAppWindows: Bool
    /// Önizlemeler kapalıyken izin uyarısı gösterilmez, bu yüzden `true` sayılır.
    var screenRecordingGranted: Bool
    var accessibilityGranted: Bool
}

/// Sahne: bulanık duvar kağıdı, masaüstü şeridi, sabit yığınlar, diğer uygulama çipleri.
///
/// Tamamı Core Animation katmanı: onlarca önizlemenin aynı anda uçması ve üstüne gelme
/// efektleri ana iş parçacığını yormadan GPU'da çalışır. Yazılar `CATextLayer` ve sistem
/// fontu; renkler sistem vurgu rengini izler. Görünüm uzayı sol üst orijinlidir, yani
/// CGWindowList kareleriyle aynı yöndedir.
final class SceneView: NSView {

    weak var delegate: SceneViewDelegate?
    var thumbnailProvider: ((CGWindowID) -> CGImage?)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hedefler

    private enum Target: Equatable {
        case window(CGWindowID)
        case action(CGWindowID, TileAction)
        case app(String)
        case chip(String)
        case overflow(String)
        case space(UInt64)
        case permission
        case search
        case fanBackground
        /// Arama altındaki kurulu uygulamalar listesinin satırı.
        case launch(Int)
    }

    private struct Hit {
        var rect: CGRect
        var target: Target
    }

    private final class Tile {
        let window: SceneWindow
        let frame: CGRect
        let root = CALayer()
        let image = CALayer()
        let ring = CALayer()
        var placeholder: CALayer?
        var badge: CALayer?
        var actions: CALayer?
        var buttons: [(action: TileAction, rect: CGRect, layer: CALayer)] = []
        var restZ: CGFloat = 0

        init(window: SceneWindow, frame: CGRect) {
            self.window = window
            self.frame = frame
        }
    }

    // MARK: Durum

    private var content: SceneContent?
    private let backdrop = CALayer()
    private let dim = CALayer()
    private let chrome = CALayer()
    /// Kaydırılan kısmı kırpar. İçindekiler görünüm uzayında kurulur, kaydırma `bounds` kökenidir.
    private let page = CALayer()
    private let pageChrome = CALayer()
    private let tileHost = CALayer()
    private let top = CALayer()

    private var tiles: [CGWindowID: Tile] = [:]
    private var fanTiles: [CGWindowID: Tile] = [:]
    private var miniWindows: [CGWindowID: CALayer] = [:]
    private var spaceThumbs: [UInt64: CALayer] = [:]
    private var spaceWallpapers: [CALayer] = []
    private var chipLayers: [String: CALayer] = [:]
    private var slotLayers: [String: [CALayer]] = [:]
    private var slotFrames: [String: CGRect] = [:]
    /// Kaymayan hedefler; görünüm uzayında.
    private var hits: [Hit] = []
    /// Sayfayla kayan hedefler; sayfa uzayında (`scrollOffset` kadar aşağıda).
    private var pageHits: [Hit] = []
    private var fanHits: [Hit] = []
    private var fanApp: String?
    private var fanLayer: CALayer?
    private var hovered: Target?
    private var tip: CALayer?
    private var hintContainer: CALayer?
    private var hintRect: CGRect = .zero
    private var query = ""
    /// Arama kutusuna tıklandı: imleç yanıp söner. Yazmaya başlamak da odaklar.
    private var searchFocused = false
    /// ⌘A ile aramadaki yazının tümü seçili: ⌫ siler, yazmak yerine koyar.
    private var selectAll = false
    /// Aramaya uyan, açık olmayan kurulu uygulamalar.
    private var appResults: [InstalledApps.App] = []
    private var resultsLayer: CALayer?
    private var trackingArea: NSTrackingArea?

    // Sürükleme
    private struct Drag {
        var tile: Tile?
        var ghost: CALayer
        var gap: Int?
        /// Sürüklenen sabit uygulama: başka bir hücreye bırakılırsa sırası değişir.
        var slot: String?
        var slotDrop: SlotDrop?
        var faded: [(layer: CALayer, opacity: Float)] = []
    }
    private var pressed: (target: Target?, point: CGPoint)?
    private var drag: Drag?
    private var spaceRects: [(id: UInt64, rect: CGRect)] = []
    private var insertionMark: CALayer?

    // Kaydırma
    private var scrollOffset: CGFloat = 0
    private var maxScroll: CGFloat = 0
    /// Sayfanın göründüğü alan; kaydırılacak bir şey yoksa tüm görünüm.
    private var viewport: CGRect = .zero
    /// Animasyonla başa dönerken üst kenar, animasyon bitene kadar kırpılı kalır.
    private var holdsTopClip = false
    private var pinnedSlots: [PlacedSlot] = []
    private var pinnedArea: CGRect = .zero

    private var scale: CGFloat { content?.backingScale ?? 2 }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Kurulum

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        for sublayer in [backdrop, dim, chrome, page, top] {
            sublayer.actions = Self.noActions
            layer?.addSublayer(sublayer)
        }
        for sublayer in [pageChrome, tileHost] {
            sublayer.actions = Self.noActions
            page.addSublayer(sublayer)
        }
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        dim.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.05, blue: 0.04, alpha: 0.28).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull(),
        "transform": NSNull(), "sublayers": NSNull(), "hidden": NSNull(), "zPosition": NSNull(),
        "backgroundColor": NSNull(), "borderColor": NSNull(), "borderWidth": NSNull(), "string": NSNull(),
        "foregroundColor": NSNull(), "frame": NSNull(), "shadowOpacity": NSNull()
    ]

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Dış arayüz

    func present(_ content: SceneContent) {
        self.content = content
        query = ""
        selectAll = false
        appResults = []
        InstalledApps.shared.refresh()
        // Açılınca arama odaklı: yazmaya başlamak uygulamayı bulur, ↩ açar.
        searchFocused = true
        scrollOffset = 0
        withoutActions { build() }
        animateIn()
    }

    func applyArrangement(_ arrangement: Arrangement, usable: CGRect) {
        guard var current = content else { return }
        current.arrangement = arrangement
        current.usable = usable
        content = current
        closeFan()
        let previous = slotFrames
        withoutActions { build() }
        animateSlotMoves(from: previous)
    }

    /// Pencere kapandıktan sonra sahneyi tazeler. Hücrelerin yeri değişmez, kaplama açık kalır.
    func applySnapshot(_ snapshot: SceneSnapshot) {
        guard content != nil else { return }
        content?.snapshot = snapshot
        closeFan()
        withoutActions { build() }
        // Sahne yeniden kurulurken üstüne gelme durumu sıfırlandı; imleç aynı yerde olabilir.
        if let window, let point = Optional(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            setHover(target(at: point))
        }
    }

    func updateThumbnail(_ id: CGWindowID, _ image: CGImage) {
        withoutActions {
            if let tile = tiles[id] { apply(image, to: tile) }
            if let tile = fanTiles[id] { apply(image, to: tile) }
            if let mini = miniWindows[id] {
                mini.contents = image
                mini.backgroundColor = nil
            }
        }
    }

    func updateWallpaper(_ entry: WallpaperStore.Entry?) {
        guard let entry else { return }
        content?.wallpaper = entry
        withoutActions {
            backdrop.contents = entry.blurred
            for layer in spaceWallpapers { layer.contents = entry.raw }
        }
    }

    func teardown() {
        withoutActions {
            for host in [chrome, pageChrome, tileHost, top] {
                host.sublayers?.forEach { $0.removeFromSuperlayer() }
                host.removeAllAnimations()
                host.opacity = 1
            }
            pageChrome.isHidden = false
            page.removeAllAnimations()
            page.masksToBounds = false
            backdrop.removeAllAnimations()
            dim.removeAllAnimations()
            backdrop.contents = nil
        }
        tiles = [:]
        fanTiles = [:]
        miniWindows = [:]
        spaceThumbs = [:]
        spaceWallpapers = []
        chipLayers = [:]
        slotLayers = [:]
        slotFrames = [:]
        hits = []
        pageHits = []
        fanHits = []
        fanApp = nil
        fanLayer = nil
        hovered = nil
        tip = nil
        hintContainer = nil
        resultsLayer = nil
        appResults = []
        content = nil
        pressed = nil
        drag = nil
        spaceRects = []
        insertionMark = nil
        scrollOffset = 0
        maxScroll = 0
        holdsTopClip = false
        pinnedSlots = []
    }

    // MARK: - Kurma

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func build() {
        guard let content else { return }
        for host in [chrome, pageChrome, tileHost, top] { host.sublayers?.forEach { $0.removeFromSuperlayer() } }
        tiles = [:]
        miniWindows = [:]
        spaceThumbs = [:]
        spaceWallpapers = []
        chipLayers = [:]
        slotLayers = [:]
        slotFrames = [:]
        hits = []
        pageHits = []
        hovered = nil
        tip = nil
        spaceRects = []
        insertionMark = nil
        drag = nil
        pressed = nil

        for host in [backdrop, dim, chrome, pageChrome, tileHost, top] {
            host.frame = bounds
            host.contentsScale = scale
        }
        backdrop.contents = content.wallpaper?.blurred
        // Duvar kağıdı henüz yoksa koyu zemin: kaplama hiçbir zaman saydam kalmaz.
        backdrop.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor

        let u = content.usable
        let stripBottom = buildSpaceStrip(top: u.minY + 8)
        let hintBottom = buildHint(top: stripBottom + 6)

        let chipHeight: CGFloat = 30
        let chipsY = u.maxY - chipHeight - 12
        let separatorY = chipsY - 16
        let stage = CGRect(
            x: u.minX + 36,
            y: hintBottom + 10,
            width: u.width - 72,
            height: separatorY - 12 - (hintBottom + 10)
        )
        buildSeparator(y: separatorY, x: stage.minX, width: stage.width)

        let others = content.snapshot.otherApps(pinned: content.arrangement.pinned)
        buildChips(others, y: chipsY, height: chipHeight, x: stage.minX, width: stage.width)

        let placed = StageLayout.place(content.arrangement.specs, in: stage)
        pinnedSlots = placed
        pinnedArea = CGRect(x: stage.minX, y: stage.minY, width: stage.width, height: separatorY - stage.minY)
        var z: CGFloat = 1
        for slot in placed {
            slotFrames[slot.id] = slot.frame
            guard let app = content.snapshot.app(slot.id) else {
                // Uygulama diskten silinmiş: yeri korunur, simgesi olmaz.
                continue
            }
            if app.windows.isEmpty {
                buildEmptySlot(app, slot: slot)
            } else {
                buildPile(app, slot: slot, z: &z)
            }
            buildLabel(app, slot: slot)
        }

        // Kaydırınca gelen bölüm ekranın hemen altından başlar, ilk görünüm değişmez.
        let viewportTop = hintBottom + 6
        var pageBottom = u.maxY
        if content.showsOtherAppWindows, !others.isEmpty {
            let specs = others.map {
                SlotSpec(id: $0.id, size: content.arrangement.unpinnedSize(of: $0.id, windowCount: $0.windows.count))
            }
            let flowing = StageLayout.placeFlowing(
                specs, x: stage.minX, width: stage.width, top: u.maxY + 16, viewportHeight: u.maxY - viewportTop - 16
            )
            for slot in flowing {
                slotFrames[slot.id] = slot.frame
                guard let app = content.snapshot.app(slot.id) else { continue }
                buildPile(app, slot: slot, z: &z)
                buildLabel(app, slot: slot)
                pageBottom = max(pageBottom, slot.frame.maxY + 16)
            }
        }
        maxScroll = max(0, pageBottom - u.maxY)
        viewport = maxScroll > 0
            ? CGRect(x: bounds.minX, y: viewportTop, width: bounds.width, height: u.maxY - viewportTop)
            : bounds
        scrollOffset = min(scrollOffset, maxScroll)
        applyScroll()
        applyQuery()
    }

    // MARK: Kaydırma

    private func applyScroll() {
        let scrollable = maxScroll > 0
        let clipTop = scrollable && (scrollOffset > 0 || holdsTopClip) ? viewport.minY : bounds.minY
        let clipBottom = scrollable ? viewport.maxY : bounds.maxY
        page.masksToBounds = scrollable
        page.frame = CGRect(x: bounds.minX, y: clipTop, width: bounds.width, height: clipBottom - clipTop)
        page.bounds.origin.y = clipTop + scrollOffset
    }

    private func setScroll(_ value: CGFloat, animated: Bool = false) {
        let next = min(max(value, 0), maxScroll)
        guard next != scrollOffset else { return }
        let previous = scrollOffset
        guard animated, !reduceMotion else {
            scrollOffset = next
            withoutActions { applyScroll() }
            return
        }
        scrollOffset = next
        holdsTopClip = true
        withoutActions { applyScroll() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdsTopClip = false
                self.withoutActions { self.applyScroll() }
            }
        }
        let slide = CABasicAnimation(keyPath: "bounds.origin.y")
        slide.fromValue = page.bounds.origin.y - next + previous
        slide.toValue = page.bounds.origin.y
        slide.duration = 0.24
        slide.timingFunction = Self.flight
        page.add(slide, forKey: "scroll")
        CATransaction.commit()
    }

    /// Klavyeyle ya da aramayla seçilen pencere görünür alana gelir.
    private func scrollIntoView(_ tile: Tile) {
        guard maxScroll > 0, fanTiles[tile.window.id] == nil else { return }
        // Altta etiket satırı da görünsün.
        let margin: CGFloat = 12, labelHeight = StageMetrics().labelHeight
        let tileTop = tile.frame.minY - scrollOffset, tileBottom = tile.frame.maxY - scrollOffset + labelHeight
        if tileBottom > viewport.maxY - margin {
            setScroll(scrollOffset + tileBottom - (viewport.maxY - margin), animated: true)
        } else if tileTop < viewport.minY + margin {
            setScroll(scrollOffset - (viewport.minY + margin - tileTop), animated: true)
        }
    }

    private func pageOffset(of tile: Tile) -> CGFloat {
        fanTiles[tile.window.id] === tile ? 0 : scrollOffset
    }

    private func isVisible(_ tile: Tile) -> Bool {
        viewport.intersects(tile.frame.offsetBy(dx: 0, dy: -scrollOffset))
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxScroll > 0, drag == nil, fanApp == nil, resultsLayer == nil else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        guard delta != 0 else { return }
        clearHover()
        setScroll(scrollOffset - delta)
    }

    /// Hücreler yeni yerine kayar; `build` katmanları son yerlerine kurmuştur.
    private func animateSlotMoves(from previous: [String: CGRect]) {
        guard !reduceMotion else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(Self.flight)
        for (id, layers) in slotLayers {
            guard let old = previous[id], let new = slotFrames[id], old.origin != new.origin else { continue }
            let slide = CABasicAnimation(keyPath: "transform.translation")
            slide.fromValue = NSValue(size: CGSize(width: old.midX - new.midX, height: old.midY - new.midY))
            slide.toValue = NSValue(size: .zero)
            for layer in layers { layer.add(slide, forKey: "slide") }
        }
        CATransaction.commit()
    }

    // MARK: Masaüstü şeridi

    private func buildSpaceStrip(top y: CGFloat) -> CGFloat {
        guard let content, !content.snapshot.spaces.isEmpty else { return y + 8 }
        let spaces = content.snapshot.spaces
        let ratio = bounds.height > 0 ? bounds.height / bounds.width : 0.625
        let gap: CGFloat = 16
        let maxWidth = content.usable.width - 80
        let count = CGFloat(spaces.count)
        let thumbWidth = min(124, (maxWidth - (count - 1) * gap) / count)
        let thumbHeight = (thumbWidth * ratio).rounded()
        let totalWidth = count * thumbWidth + (count - 1) * gap
        var x = content.usable.midX - totalWidth / 2

        for space in spaces {
            let rect = CGRect(x: x, y: y, width: thumbWidth, height: thumbHeight)
            let holder = plainLayer()
            holder.frame = rect
            holder.cornerRadius = 7
            holder.masksToBounds = true
            holder.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
            holder.contentsGravity = .resizeAspectFill
            if !space.isFullScreen {
                holder.contents = content.wallpaper?.raw
                spaceWallpapers.append(holder)
            }
            holder.borderWidth = space.isCurrent ? 2 : 0.5
            holder.borderColor = space.isCurrent
                ? NSColor.controlAccentColor.cgColor
                : NSColor(calibratedWhite: 1, alpha: 0.32).cgColor

            let scaleX = thumbWidth / max(bounds.width, 1)
            let scaleY = thumbHeight / max(bounds.height, 1)
            let windows = content.snapshot.windows(inSpace: space.id)
                .sorted { $0.zRank > $1.zRank }
                .suffix(10)
            for window in windows {
                let mini = plainLayer()
                let local = CGRect(
                    x: (window.frame.minX - content.screenOrigin.x) * scaleX,
                    y: (window.frame.minY - content.screenOrigin.y) * scaleY,
                    width: window.frame.width * scaleX,
                    height: window.frame.height * scaleY
                )
                mini.frame = space.isFullScreen ? holder.bounds : local
                mini.contentsGravity = .resize
                mini.cornerRadius = space.isFullScreen ? 0 : 1.5
                mini.masksToBounds = true
                if let image = thumbnailProvider?(window.id) {
                    mini.contents = image
                } else {
                    // Önizlemesizken küçük resimler de cam: beyaz bloklar görüntü bekliyormuş gibi durur.
                    mini.backgroundColor = NSColor(calibratedWhite: 1, alpha: content.previewsAvailable ? 0.9 : 0.34).cgColor
                }
                holder.addSublayer(mini)
                miniWindows[window.id] = mini
            }
            chrome.addSublayer(holder)
            spaceThumbs[space.id] = holder

            let label = text(space.label, font: .systemFont(ofSize: 11, weight: .medium), shadow: true)
            let labelSize = CGSize(width: min(thumbWidth + 12, label.preferredFrameSize().width), height: 15)
            label.frame = CGRect(
                x: rect.midX - labelSize.width / 2,
                y: rect.maxY + 4,
                width: labelSize.width,
                height: labelSize.height
            )
            chrome.addSublayer(label)

            hits.append(Hit(rect: rect, target: .space(space.id)))
            spaceRects.append((space.id, rect))
            x += thumbWidth + gap
        }
        return y + thumbHeight + 4 + 15
    }

    // MARK: İpucu ve arama

    private func buildHint(top y: CGFloat) -> CGFloat {
        guard let content else { return y }
        let height: CGFloat = 34
        hintRect = CGRect(x: content.usable.midX, y: y, width: 0, height: height)
        renderHint()
        let needsPermission = !content.screenRecordingGranted || !content.accessibilityGranted
        hits.append(Hit(rect: hintRect, target: needsPermission ? .permission : .search))
        return y + height
    }

    private func renderHint() {
        guard let content else { return }
        hintContainer?.removeFromSuperlayer()

        let message: String
        var color = NSColor(calibratedWhite: 1, alpha: 0.72)
        // Arama hep odaklı; izin eksikse boş kutu yerine izin uyarısı görünür, yazmak yine aramadır.
        let needsPermission = !content.screenRecordingGranted || !content.accessibilityGranted
        if let drag {
            switch (drag.slot != nil, canDropOnStrip(drag)) {
            case (true, true):
                message = tx("Sıralamak için hücrelerin arasına, tam ekran için şeride bırak", "Drop between cells to reorder, on the strip for full screen")
            case (true, false):
                message = tx("Sıralamak için hücrelerin arasına bırak", "Drop between cells to reorder")
            default:
                message = tx("Tam ekran yapıp buraya yerleştirmek için bırak", "Drop to make it full screen here")
            }
            color = .white
        } else if !query.isEmpty {
            message = query
            color = .white
        } else if searchFocused && !needsPermission {
            message = tx("Uygulama ya da pencere ara", "Search apps and windows")
            color = NSColor(calibratedWhite: 1, alpha: 0.5)
        } else if !content.screenRecordingGranted {
            message = tx("Önizlemeler ve başlıklar için Ekran Kaydı izni gerekli. Vermek için tıkla.", "Previews and titles need Screen Recording access. Click to grant it.")
            color = .white
        } else if !content.accessibilityGranted {
            message = tx("Pencereye geçmek için Erişilebilirlik izni gerekli. Vermek için tıkla.", "Switching to windows needs Accessibility access. Click to grant it.")
            color = .white
        } else {
            message = tx("Aramak için yazmaya başlayın", "Start typing to search")
        }

        let label = text(message, font: .systemFont(ofSize: 14, weight: query.isEmpty ? .regular : .medium), color: color)
        let textSize = label.preferredFrameSize()
        let typing = drag == nil && (!query.isEmpty || (searchFocused && !needsPermission))
        // Arama yazılırken kutu sabit genişlikte durur, metin sola yaslanır: gerçek bir alan gibi.
        let width = typing ? max(380, min(textSize.width + 56, content.usable.width - 80))
                           : min(textSize.width + 28, content.usable.width - 80)
        let rect = CGRect(x: content.usable.midX - width / 2, y: hintRect.minY, width: width, height: hintRect.height)
        hintRect = rect

        let pill = plainLayer()
        pill.frame = rect
        pill.cornerRadius = rect.height / 2
        pill.backgroundColor = NSColor(calibratedWhite: 1, alpha: typing ? 0.2 : 0.13).cgColor
        if typing {
            pill.borderWidth = 1
            pill.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            let glass = plainLayer()
            if let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedWhite: 1, alpha: 0.7)]))) {
                var symbolRect = CGRect(x: 0, y: 0, width: symbol.size.width * scale, height: symbol.size.height * scale)
                glass.contents = symbol.cgImage(forProposedRect: &symbolRect, context: nil, hints: nil)
                glass.contentsGravity = .resizeAspect
                glass.frame = CGRect(x: 13, y: (rect.height - 16) / 2, width: 16, height: 16)
                pill.addSublayer(glass)
            }
            let textWidth = min(textSize.width, width - 56)
            label.frame = CGRect(x: 37, y: (rect.height - textSize.height) / 2, width: textWidth, height: textSize.height)
            let caret = plainLayer()
            caret.backgroundColor = NSColor.white.cgColor
            caret.frame = CGRect(x: query.isEmpty ? 37 : label.frame.maxX + 1, y: (rect.height - 18) / 2, width: 1.5, height: 18)
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1
            blink.toValue = 0
            blink.duration = 0.53
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            caret.add(blink, forKey: "blink")
            if selectAll && !query.isEmpty {
                let selection = plainLayer()
                selection.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
                selection.cornerRadius = 3
                selection.frame = label.frame.insetBy(dx: -2, dy: -1)
                pill.addSublayer(selection)
            } else {
                pill.addSublayer(caret)
            }
            if query.isEmpty { label.frame.origin.x = 40 }
        } else {
            label.frame = CGRect(x: 14, y: (rect.height - textSize.height) / 2, width: width - 28, height: textSize.height)
        }
        pill.addSublayer(label)
        chrome.addSublayer(pill)
        hintContainer = pill
        // Uygulama paneli açıkken arama satırı panelin içindedir.
        pill.isHidden = resultsLayer != nil

        if let index = hits.firstIndex(where: { $0.target == .permission || $0.target == .search }) {
            hits[index].rect = rect
        }
    }

    // MARK: Diğer uygulamalar

    private func buildSeparator(y: CGFloat, x: CGFloat, width: CGFloat) {
        guard let content else { return }
        let others = content.snapshot.otherApps(pinned: content.arrangement.pinned)
        guard !others.isEmpty else { return }

        let heading = content.showsOtherAppWindows
            ? tx("DİĞER AÇIK UYGULAMALAR · PENCERELER İÇİN KAYDIRIN", "OTHER OPEN APPS · SCROLL FOR WINDOWS")
            : tx("DİĞER AÇIK UYGULAMALAR", "OTHER OPEN APPS")
        let title = text(heading, font: .systemFont(ofSize: 10.5, weight: .semibold),
                         color: NSColor(calibratedWhite: 1, alpha: 0.82), kern: 0.7)
        let size = title.preferredFrameSize()
        title.frame = CGRect(x: x, y: y - size.height / 2, width: size.width, height: size.height)
        pageChrome.addSublayer(title)

        let line = plainLayer()
        line.frame = CGRect(x: x + size.width + 12, y: y, width: width - size.width - 12, height: 0.5)
        line.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.25).cgColor
        pageChrome.addSublayer(line)
    }

    private func buildChips(_ apps: [SceneApp], y: CGFloat, height: CGFloat, x: CGFloat, width: CGFloat) {
        guard !apps.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let iconSize: CGFloat = 20
        let gap: CGFloat = 8

        func chipTitle(_ app: SceneApp) -> String {
            app.windows.count > 1 ? "\(app.name) · \(app.windows.count)" : app.name
        }
        let titles = apps.map { text(chipTitle($0), font: font) }
        let widths = titles.map { 5 + iconSize + 6 + $0.preferredFrameSize().width + 12 }
        let fullWidth = widths.reduce(0, +) + CGFloat(apps.count - 1) * gap
        // Sığmazsa yalnızca simgeler: satır sayısı değişip yığınları itmesin.
        let iconOnly = fullWidth > width
        let chipWidths = iconOnly ? Array(repeating: iconSize + 12, count: apps.count) : widths
        let total = chipWidths.reduce(0, +) + CGFloat(apps.count - 1) * gap
        var cursor = x + (width - total) / 2

        for (index, app) in apps.enumerated() {
            let rect = CGRect(x: cursor, y: y, width: chipWidths[index], height: height)
            let chip = plainLayer()
            chip.frame = rect
            chip.cornerRadius = height / 2
            chip.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
            chip.borderWidth = 0.5
            chip.borderColor = NSColor(calibratedWhite: 1, alpha: 0.24).cgColor

            let icon = iconLayer(app.icon, size: iconSize)
            icon.frame = CGRect(x: iconOnly ? 6 : 5, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            chip.addSublayer(icon)

            if !iconOnly {
                let label = titles[index]
                let size = label.preferredFrameSize()
                label.frame = CGRect(x: 5 + iconSize + 6, y: (height - size.height) / 2, width: size.width, height: size.height)
                chip.addSublayer(label)
            }
            pageChrome.addSublayer(chip)
            chipLayers[app.id] = chip
            pageHits.append(Hit(rect: rect, target: .chip(app.id)))
            cursor += chipWidths[index] + gap
        }
    }

    // MARK: Yığınlar

    private func buildPile(_ app: SceneApp, slot: PlacedSlot, z: inout CGFloat) {
        let visible = Array(app.windows.prefix(PileLayout.maxVisible))
        let frames = PileLayout.frames(in: slot.pile.insetBy(dx: 2, dy: 2), aspects: visible.map(\.aspect))

        for (window, frame) in zip(visible, frames) {
            let tile = makeTile(window, frame: frame, badge: true)
            tile.restZ = z
            tile.root.zPosition = z
            z += 1
            tileHost.addSublayer(tile.root)
            tiles[window.id] = tile
            slotLayers[app.id, default: []].append(tile.root)
            pageHits.append(Hit(rect: frame, target: .window(window.id)))
        }

        let hidden = app.windows.count - visible.count
        if hidden > 0, let last = frames.last {
            let label = text("+\(hidden)", font: .systemFont(ofSize: 12, weight: .semibold))
            let size = label.preferredFrameSize()
            let pill = plainLayer()
            let pillSize = CGSize(width: size.width + 16, height: 24)
            let rect = CGRect(x: last.maxX - pillSize.width - 6, y: last.minY + 6, width: pillSize.width, height: pillSize.height)
            pill.frame = rect
            pill.cornerRadius = 12
            pill.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.78).cgColor
            pill.borderWidth = 0.5
            pill.borderColor = NSColor(calibratedWhite: 1, alpha: 0.3).cgColor
            label.frame = CGRect(x: 8, y: (24 - size.height) / 2, width: size.width, height: size.height)
            pill.addSublayer(label)
            pill.zPosition = z + 500
            tileHost.addSublayer(pill)
            slotLayers[app.id, default: []].append(pill)
            pageHits.append(Hit(rect: rect, target: .overflow(app.id)))
        }
        z += 1
    }

    private func buildEmptySlot(_ app: SceneApp, slot: PlacedSlot) {
        let area = slot.pile
        let height = min(area.height - 4, area.width * 0.72)
        let width = min(area.width - 4, height * 4 / 3)
        let rect = CGRect(x: area.midX - width / 2, y: area.maxY - height - 2, width: width, height: height)

        let dashed = CAShapeLayer()
        dashed.actions = Self.noActions
        dashed.frame = rect
        dashed.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 10, cornerHeight: 10, transform: nil)
        dashed.fillColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
        dashed.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.42).cgColor
        dashed.lineWidth = 1
        dashed.lineDashPattern = [5, 4]

        let iconSize = min(56, height * 0.45)
        let icon = iconLayer(app.icon, size: iconSize)
        icon.frame = CGRect(x: (width - iconSize) / 2, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        icon.opacity = 0.6
        dashed.addSublayer(icon)

        pageChrome.addSublayer(dashed)
        slotLayers[app.id, default: []].append(dashed)
        pageHits.append(Hit(rect: rect, target: .app(app.id)))
    }

    private func buildLabel(_ app: SceneApp, slot: PlacedSlot) {
        let iconSize: CGFloat = 24
        let suffix: String
        if app.windows.isEmpty {
            suffix = app.isRunning ? tx(" · pencere yok", " · no windows") : tx(" · kapalı", " · not running")
        } else {
            suffix = ""
        }
        let color = app.windows.isEmpty ? NSColor(calibratedWhite: 1, alpha: 0.72) : NSColor.white
        let label = text(app.name + suffix, font: .systemFont(ofSize: 13, weight: app.windows.isEmpty ? .medium : .semibold),
                         color: color, shadow: true)
        let size = label.preferredFrameSize()
        let textWidth = min(size.width, slot.frame.width - iconSize - 6)
        let total = iconSize + 6 + textWidth
        let centerY = slot.pile.maxY + (slot.frame.maxY - slot.pile.maxY) / 2
        let x = slot.frame.midX - total / 2

        let icon = iconLayer(app.icon, size: iconSize)
        icon.frame = CGRect(x: x, y: centerY - iconSize / 2, width: iconSize, height: iconSize)
        icon.opacity = app.windows.isEmpty ? 0.7 : 1
        pageChrome.addSublayer(icon)

        label.frame = CGRect(x: x + iconSize + 6, y: centerY - size.height / 2, width: textWidth, height: size.height)
        pageChrome.addSublayer(label)

        slotLayers[app.id, default: []].append(contentsOf: [icon, label])
    }

    // MARK: Önizleme

    private func makeTile(_ window: SceneWindow, frame: CGRect, badge showBadge: Bool) -> Tile {
        let tile = Tile(window: window, frame: frame)
        let radius = max(6, min(11, frame.width * 0.035))
        let local = CGRect(origin: .zero, size: frame.size)

        let root = tile.root
        root.actions = Self.noActions
        root.frame = frame
        root.contentsScale = scale
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0.42
        root.shadowRadius = 14
        root.shadowOffset = CGSize(width: 0, height: 7)
        root.shadowPath = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)

        let image = tile.image
        image.actions = Self.noActions
        image.frame = local
        image.cornerRadius = radius
        image.cornerCurve = .continuous
        image.masksToBounds = true
        image.contentsGravity = .resize
        image.borderWidth = 0.5
        image.borderColor = NSColor(calibratedWhite: 1, alpha: 0.2).cgColor
        root.addSublayer(image)

        if let thumbnail = thumbnailProvider?(window.id) {
            image.contents = thumbnail
        } else {
            let app = content?.snapshot.app(window.appID)
            if content?.previewsAvailable == true {
                // Görüntü birazdan gelecek.
                image.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 0.95).cgColor
                let iconSize = min(48, min(frame.width, frame.height) * 0.42)
                if let app {
                    let icon = iconLayer(app.icon, size: iconSize)
                    icon.frame = CGRect(x: (frame.width - iconSize) / 2, y: (frame.height - iconSize) / 2, width: iconSize, height: iconSize)
                    image.addSublayer(icon)
                    tile.placeholder = icon
                }
            } else if let app {
                // Önizlemesiz kart: duvar kağıdının üstünde cam, simge ve başlık.
                image.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
                image.borderColor = NSColor(calibratedWhite: 1, alpha: 0.3).cgColor
                root.shadowOpacity = 0.22
                let iconSize = min(56, min(frame.width, frame.height) * 0.38)
                let name = window.displayName(appName: app.name, windowCount: app.windows.count)
                let label = text(name, font: .systemFont(ofSize: 12, weight: .medium), shadow: true)
                label.alignmentMode = .center
                let labelHeight = ceil(label.preferredFrameSize().height)
                let blockHeight = iconSize + 8 + labelHeight
                let top = max(6, (frame.height - blockHeight) / 2 - 6)
                let icon = iconLayer(app.icon, size: iconSize)
                icon.frame = CGRect(x: (frame.width - iconSize) / 2, y: top, width: iconSize, height: iconSize)
                image.addSublayer(icon)
                label.frame = CGRect(x: 8, y: top + iconSize + 8, width: frame.width - 16, height: labelHeight)
                image.addSublayer(label)
            }
        }

        if showBadge, !window.badge.isEmpty, frame.width > 80 {
            let label = text(window.badge, font: .systemFont(ofSize: 10, weight: .medium))
            let size = label.preferredFrameSize()
            let width = min(size.width + 12, frame.width - 12)
            let pill = plainLayer()
            pill.frame = CGRect(x: 6, y: frame.height - 6 - 18, width: width, height: 18)
            pill.cornerRadius = 9
            pill.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.62).cgColor
            label.frame = CGRect(x: 6, y: (18 - size.height) / 2, width: width - 12, height: size.height)
            pill.addSublayer(label)
            root.addSublayer(pill)
            tile.badge = pill
        }

        let ring = tile.ring
        ring.actions = Self.noActions
        ring.frame = local.insetBy(dx: -3, dy: -3)
        ring.cornerRadius = radius + 3
        ring.cornerCurve = .continuous
        ring.borderWidth = 2.5
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.isHidden = true
        root.addSublayer(ring)

        buildActions(on: tile)
        return tile
    }

    /// Üstüne gelince sağ üstte beliren yaslama ve kapatma düğmeleri.
    private func buildActions(on tile: Tile) {
        let padding: CGFloat = 3
        let actions = TileAction.all(isFullScreen: isReorder(tile.window), isMinimized: tile.window.state == .minimized,
                                     multipleDisplays: NSScreen.screens.count > 1)
        // Dar önizlemede (Rota gibi dikey pencereler) düğmeler küçülür, kaybolmaz.
        let fullWidth = CGFloat(actions.count) * 26 + 2 * padding + 12
        let buttonSize: CGFloat = tile.frame.width >= fullWidth ? 26 : 21
        let width = CGFloat(actions.count) * buttonSize + 2 * padding
        let height = buttonSize + 2 * padding
        // Küçük önizlemede düğmeler pencerenin tamamını kapatmasın.
        guard tile.frame.width >= width + 12, tile.frame.height >= height * 2 else { return }

        let bar = plainLayer()
        bar.frame = CGRect(x: tile.frame.width - width - 6, y: 6, width: width, height: height)
        bar.cornerRadius = height / 2
        bar.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.78).cgColor
        bar.borderWidth = 0.5
        bar.borderColor = NSColor(calibratedWhite: 1, alpha: 0.24).cgColor
        bar.shadowColor = NSColor.black.cgColor
        bar.shadowOpacity = 0.3
        bar.shadowRadius = 6
        bar.shadowOffset = CGSize(width: 0, height: 2)
        bar.isHidden = true

        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

        for (index, action) in actions.enumerated() {
            let local = CGRect(x: padding + CGFloat(index) * buttonSize, y: padding, width: buttonSize, height: buttonSize)
            let button = plainLayer()
            button.frame = local
            button.cornerRadius = buttonSize / 2

            if let symbol = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.label)?
                .withSymbolConfiguration(configuration) {
                let glyph = plainLayer()
                let inset: CGFloat = buttonSize >= 26 ? 5 : 4
                glyph.frame = button.bounds.insetBy(dx: inset, dy: inset)
                var rect = CGRect(x: 0, y: 0, width: symbol.size.width * scale, height: symbol.size.height * scale)
                glyph.contents = symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                glyph.contentsGravity = .resizeAspect
                button.addSublayer(glyph)
            }
            bar.addSublayer(button)
            tile.buttons.append((action, local.offsetBy(dx: bar.frame.minX, dy: bar.frame.minY), button))
        }
        tile.root.addSublayer(bar)
        tile.actions = bar
    }

    private func apply(_ image: CGImage, to tile: Tile) {
        tile.image.contents = image
        tile.image.backgroundColor = nil
        tile.placeholder?.removeFromSuperlayer()
        tile.placeholder = nil
    }

    // MARK: Katman yardımcıları

    private func plainLayer() -> CALayer {
        let layer = CALayer()
        layer.actions = Self.noActions
        layer.contentsScale = scale
        return layer
    }

    private func iconLayer(_ image: NSImage, size: CGFloat) -> CALayer {
        let layer = plainLayer()
        var rect = CGRect(x: 0, y: 0, width: size * scale, height: size * scale)
        layer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        layer.contentsGravity = .resizeAspect
        return layer
    }

    private func text(
        _ string: String,
        font: NSFont,
        color: NSColor = .white,
        shadow: Bool = false,
        kern: CGFloat = 0
    ) -> CATextLayer {
        let layer = LabelLayer()
        layer.needsDisplayOnBoundsChange = true
        layer.actions = Self.noActions
        layer.contentsScale = scale
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attributes[.kern] = kern }
        layer.string = NSAttributedString(string: string, attributes: attributes)
        layer.truncationMode = .end
        layer.isWrapped = false
        layer.alignmentMode = .left
        if shadow {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowRadius = 2.5
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }
        return layer
    }

    // MARK: - Animasyon

    private static let flight = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.28, 1)

    private func realRect(_ window: SceneWindow) -> CGRect? {
        guard let content, window.state == .visible else { return nil }
        let rect = window.frame.offsetBy(dx: -content.screenOrigin.x, dy: -content.screenOrigin.y)
        return rect.intersects(bounds) ? rect : nil
    }

    private func flightTransform(for tile: Tile, to rect: CGRect) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(rect.midX - tile.frame.midX, rect.midY - (tile.frame.midY - scrollOffset), 0)
        transform = CATransform3DScale(transform, rect.width / tile.frame.width, rect.height / tile.frame.height, 1)
        return transform
    }

    private func animateIn() {
        let duration: CFTimeInterval = reduceMotion ? 0.15 : 0.34

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Self.flight)

        for host in [backdrop, dim, chrome, pageChrome] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = host === backdrop || host === dim ? min(duration, 0.2) : duration
            host.add(fade, forKey: "fade")
        }

        for tile in tiles.values {
            if !reduceMotion, isVisible(tile), let rect = realRect(tile.window) {
                let fly = CABasicAnimation(keyPath: "transform")
                fly.fromValue = flightTransform(for: tile, to: rect)
                fly.toValue = CATransform3DIdentity
                tile.root.add(fly, forKey: "fly")

                // Uçuş başında pencereler gerçek ön-arka sırasında, sonunda yığın sırasında.
                let depth = CABasicAnimation(keyPath: "zPosition")
                depth.fromValue = 3000 - CGFloat(tile.window.zRank)
                depth.toValue = tile.restZ
                tile.root.add(depth, forKey: "depth")

                if let badge = tile.badge {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    badge.add(fade, forKey: "fade")
                }
            } else {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                tile.root.add(fade, forKey: "fade")
                if !reduceMotion {
                    let grow = CABasicAnimation(keyPath: "transform.scale")
                    grow.fromValue = 0.92
                    grow.toValue = 1
                    tile.root.add(grow, forKey: "grow")
                }
            }
        }
        CATransaction.commit()
    }

    func dismiss(animated: Bool, focus: CGWindowID?, destination: CGRect? = nil, completion: @escaping () -> Void) {
        closeFan()
        clearHover()
        guard animated else {
            completion()
            return
        }
        let duration: CFTimeInterval = reduceMotion ? 0.12 : 0.24

        prepareForDismissal(focus: focus)
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock(completion)

        for host in [backdrop, dim, chrome, pageChrome] {
            add(opacityFrom: 1, to: 0, on: host)
        }
        for tile in tiles.values {
            let isFocus = tile.window.id == focus
            if !reduceMotion, let rect = (isFocus ? destination : nil) ?? realRect(tile.window) {
                let fly = CABasicAnimation(keyPath: "transform")
                fly.fromValue = CATransform3DIdentity
                fly.toValue = flightTransform(for: tile, to: rect)
                fly.isRemovedOnCompletion = false
                fly.fillMode = .forwards
                tile.root.add(fly, forKey: "fly")
                if isFocus {
                    tile.root.zPosition = 4000
                } else {
                    tile.root.zPosition = 3000 - CGFloat(tile.window.zRank)
                }
                if let badge = tile.badge { add(opacityFrom: 1, to: 0, on: badge) }
            } else {
                add(opacityFrom: 1, to: 0, on: tile.root)
            }
        }
        for layer in tileHost.sublayers ?? [] where !tiles.values.contains(where: { $0.root === layer }) {
            add(opacityFrom: 1, to: 0, on: layer)
        }
        CATransaction.commit()
    }

    /// Görünmeyen önizlemeler uçmaz. Kaydırılmışken pencereler kırpmadan çıkıp yerlerine uçar;
    /// yukarıda kalan etiketler de şeridin üstünde görünmesin diye gizlenir.
    private func prepareForDismissal(focus: CGWindowID?) {
        guard maxScroll > 0 else { return }
        withoutActions {
            for tile in tiles.values where !isVisible(tile) && tile.window.id != focus {
                tile.root.isHidden = true
            }
            let roots = Set(tiles.values.map { ObjectIdentifier($0.root) })
            for layer in tileHost.sublayers ?? [] where !roots.contains(ObjectIdentifier(layer)) {
                layer.isHidden = !viewport.intersects(layer.frame.offsetBy(dx: 0, dy: -scrollOffset))
            }
            if scrollOffset > 0 {
                pageChrome.isHidden = true
                page.masksToBounds = false
            }
        }
    }

    private func add(opacityFrom from: Float, to value: Float, on layer: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = value
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        layer.add(fade, forKey: "fadeOut")
    }

    // MARK: - Fare

    private func windowID(of target: Target?) -> CGWindowID? {
        switch target {
        case .window(let id), .action(let id, _): return id
        default: return nil
        }
    }

    /// Üstüne gelinen önizleme öne çıktığı için, imleç üstünde kaldıkça o seçili kalır.
    /// Yoksa çakışan yığınlarda arkadaki pencere seçimi kapar, düğmelere de ulaşılamaz.
    private func targetOnHoveredTile(at point: CGPoint) -> Target? {
        guard let id = windowID(of: hovered), let tile = tile(for: id) else { return nil }
        guard fanTiles[id] != nil || viewport.contains(point) else { return nil }
        let scaled = 1.05
        let local = CGPoint(
            x: (point.x - tile.frame.midX) / scaled + tile.frame.width / 2,
            y: (point.y - (tile.frame.midY - pageOffset(of: tile))) / scaled + tile.frame.height / 2
        )
        guard CGRect(origin: .zero, size: tile.frame.size).contains(local) else { return nil }
        if let button = tile.buttons.first(where: { $0.rect.contains(local) }) {
            return .action(id, button.action)
        }
        return .window(id)
    }

    private func target(at point: CGPoint) -> Target? {
        // Arama sonuçları paneli önizlemelerin üstündedir: içindeki tıklama alttaki pencereye
        // geçmez, simgeler arasındaki boşluk da hiçbir şey seçmez.
        if let resultsLayer, resultsLayer.frame.contains(point) {
            return hits.last { $0.rect.contains(point) && resultsLayer.frame.contains($0.rect) }?.target
        }
        if fanApp != nil, let fanLayer, fanLayer.frame.contains(point) {
            if let id = windowID(of: hovered), fanTiles[id] != nil, let target = targetOnHoveredTile(at: point) {
                return target
            }
            return fanHits.first { $0.rect.contains(point) }?.target ?? .fanBackground
        }
        if let target = targetOnHoveredTile(at: point) { return target }
        // Sonradan eklenen öndedir; pencereler yığın sırasıyla eklenir.
        if let fixed = hits.last(where: { $0.rect.contains(point) }) { return fixed.target }
        guard viewport.contains(point) else { return nil }
        let local = CGPoint(x: point.x, y: point.y + scrollOffset)
        return pageHits.last { $0.rect.contains(local) }?.target
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHover(target(at: point))
        // İmleç önizlemeye doğrudan düğmenin üstünden girdiyse düğme de hemen seçilsin.
        setHover(target(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    private func clearHover() { setHover(nil) }

    private func setHover(_ next: Target?) {
        guard next != hovered else { return }
        let previous = hovered
        let oldWindow = windowID(of: previous)
        let newWindow = windowID(of: next)
        hovered = next

        if let previous, oldWindow == nil { applyHover(previous, active: false) }
        if oldWindow != newWindow {
            if let oldWindow { applyHover(.window(oldWindow), active: false) }
            if let newWindow { applyHover(.window(newWindow), active: true) }
        }
        if let next, newWindow == nil { applyHover(next, active: true) }

        withoutActions {
            if case .action(let id, let action)? = previous {
                tile(for: id)?.buttons.first { $0.action == action }?.layer.backgroundColor = nil
            }
            guard let newWindow, let tile = tile(for: newWindow) else { return }
            if case .action(_, let action)? = next {
                tile.buttons.first { $0.action == action }?.layer.backgroundColor = action.hoverColor.cgColor
                showTip(for: tile, text: action.label)
            } else if case .action? = previous {
                showTip(for: tile)
            }
        }
    }

    private func tile(for id: CGWindowID) -> Tile? { fanTiles[id] ?? tiles[id] }

    private func applyHover(_ target: Target, active: Bool) {
        switch target {
        case .window(let id):
            guard let tile = tile(for: id) else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            let toScale: CGFloat = active ? 1.05 : 1
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = tile.root.presentation()?.value(forKeyPath: "transform.scale") ?? (active ? 1 : 1.05)
            animation.toValue = toScale
            tile.root.add(animation, forKey: "hover")
            CATransaction.commit()

            withoutActions {
                tile.root.transform = CATransform3DMakeScale(toScale, toScale, 1)
                tile.ring.isHidden = !active
                tile.actions?.isHidden = !active
                tile.root.zPosition = active ? 2000 : tile.restZ
                if active {
                    showTip(for: tile)
                } else {
                    tip?.removeFromSuperlayer()
                    tip = nil
                }
            }

        case .chip(let id):
            withoutActions {
                chipLayers[id]?.backgroundColor = NSColor(calibratedWhite: 1, alpha: active ? 0.28 : 0.16).cgColor
            }

        case .space(let id):
            guard let thumb = spaceThumbs[id], let space = content?.snapshot.spaces.first(where: { $0.id == id }) else { return }
            withoutActions {
                if !space.isCurrent {
                    thumb.borderWidth = active ? 1.5 : 0.5
                    thumb.borderColor = NSColor(calibratedWhite: 1, alpha: active ? 0.85 : 0.32).cgColor
                }
            }

        case .overflow(let id):
            // "+N" üstüne gelince tüm pencereler açılır.
            if active { openFan(id) }

        case .app(let id):
            withoutActions {
                (slotLayers[id]?.first as? CAShapeLayer)?.strokeColor =
                    NSColor(calibratedWhite: 1, alpha: active ? 0.85 : 0.42).cgColor
            }

        case .permission, .search, .fanBackground, .action, .launch:
            break
        }
    }

    private func showTip(for tile: Tile, text override: String? = nil) {
        tip?.removeFromSuperlayer()
        tip = nil
        let title = override
            ?? content?.snapshot.app(tile.window.appID).map {
                tile.window.displayName(appName: $0.name, windowCount: $0.windows.count)
            }
            ?? tile.window.title
        guard !title.isEmpty else { return }

        let label = text(title, font: .systemFont(ofSize: 12, weight: .semibold))
        let size = label.preferredFrameSize()
        let width = min(size.width + 22, 420)
        let height: CGFloat = 26
        let source = tile.frame.offsetBy(dx: 0, dy: -pageOffset(of: tile))
        var x = source.midX - width / 2
        x = min(max(x, 12), bounds.width - width - 12)
        let y = max(source.minY - height - 8, 8)

        let pill = plainLayer()
        pill.frame = CGRect(x: x, y: y, width: width, height: height)
        pill.cornerRadius = height / 2
        pill.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.86).cgColor
        pill.zPosition = 3000
        label.frame = CGRect(x: 11, y: (height - size.height) / 2, width: width - 22, height: size.height)
        pill.addSublayer(label)
        top.addSublayer(pill)
        tip = pill
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = (target(at: point), point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if drag == nil {
            // Küçük kaymalar tıklama sayılır.
            guard let pressed, hypot(point.x - pressed.point.x, point.y - pressed.point.y) > 6 else { return }
            let slot = pinnedSlot(at: pressed.point)
            switch pressed.target {
            case .window(let id)?:
                // Tam ekran alanların sırası değiştirilemez: macOS bunu yalnızca kendi Mission
                // Control'ünde yapıyor, taklit etmek onu ekranda açıp sürüklemek demekti. Tam ekran
                // pencere de yine hücresiyle birlikte sıralanabilir.
                guard let tile = tile(for: id), slot != nil || !isReorder(tile.window) else { return }
                beginDrag(tile, slot: slot, at: point)
            case .app?, .overflow?, nil:
                // Etiket, boş hücre ya da hücrenin boşluğu: yalnızca sıralama.
                guard let slot else { return }
                beginDrag(nil, slot: slot, at: point)
            default:
                return
            }
        }
        updateDrag(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let start = pressed
        pressed = nil
        if drag != nil {
            finishDrag(at: point)
            return
        }
        // Tıklama, basılan yerde bırakmaktır: başka yerde bırakılınca hiçbir şey etkinleşmemeli.
        let released = target(at: point)
        guard let start, start.target == released else { return }
        activate(released)
    }

    // MARK: Şeride sürükleme

    /// Zaten tam ekran olan pencere: yalnızca alanının yeri değişir.
    private func isReorder(_ window: SceneWindow) -> Bool {
        guard let spaceID = window.spaceID else { return false }
        return content?.snapshot.spaces.first { $0.id == spaceID }?.isFullScreen ?? false
    }

    /// Sıralanabilecek sabit hücre. Arama ya da panel açıkken sıralama olmaz.
    private func pinnedSlot(at point: CGPoint) -> String? {
        guard fanApp == nil, query.isEmpty, pinnedSlots.count > 1, viewport.contains(point) else { return nil }
        let local = CGPoint(x: point.x, y: point.y + scrollOffset)
        return pinnedSlots.first { $0.frame.contains(local) }?.id
    }

    private func canDropOnStrip(_ drag: Drag) -> Bool {
        guard let window = drag.tile?.window else { return false }
        return !isReorder(window)
    }

    private func beginDrag(_ tile: Tile?, slot: String?, at point: CGPoint) {
        clearHover()
        // Küçük ve imlecin altında: bırakılacak aralığı örtmesin.
        let size: CGSize
        if let tile {
            let width = min(tile.frame.width, 150)
            size = CGSize(width: width, height: width / max(tile.window.aspect, 0.2))
        } else {
            size = CGSize(width: 72, height: 72)
        }

        withoutActions {
            let ghost = plainLayer()
            ghost.bounds = CGRect(origin: .zero, size: size)
            ghost.position = ghostPosition(at: point, size: size)
            ghost.opacity = 0.92
            ghost.zPosition = 5000
            ghost.shadowColor = NSColor.black.cgColor
            ghost.shadowOpacity = 0.5
            ghost.shadowRadius = 18
            ghost.shadowOffset = CGSize(width: 0, height: 10)
            ghost.shadowPath = CGPath(roundedRect: ghost.bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)

            let image = plainLayer()
            image.frame = ghost.bounds
            image.cornerRadius = 8
            image.masksToBounds = true
            image.contentsGravity = .resize
            image.backgroundColor = tile == nil ? nil : NSColor(calibratedWhite: 0.9, alpha: 1).cgColor
            if let contents = tile?.image.contents {
                image.contents = contents
            } else if let app = content?.snapshot.app(tile?.window.appID ?? slot ?? "") {
                // Görüntü yoksa sürüklenen şey uygulama simgesidir.
                var rect = CGRect(x: 0, y: 0, width: 96 * scale, height: 96 * scale)
                image.contents = app.icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                image.contentsGravity = .resizeAspect
            }
            ghost.addSublayer(image)
            top.addSublayer(ghost)

            // Sıralanırken hücrenin tamamı soluklaşır, bırakılınca eski değerlerine döner.
            let layers = slot.flatMap { slotLayers[$0] } ?? tile.map { [$0.root] } ?? []
            let faded = layers.map { (layer: $0, opacity: $0.opacity) }
            for layer in layers { layer.opacity = 0.3 }
            drag = Drag(tile: tile, ghost: ghost, gap: nil, slot: slot, faded: faded)
            renderHint()
        }
    }

    private func ghostPosition(at point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x, y: point.y + size.height / 2 + 14)
    }

    private func updateDrag(at point: CGPoint) {
        guard var current = drag else { return }
        let gap = stripGap(at: point, for: current)
        let slotDrop = gap == nil ? slotDrop(at: point, for: current) : nil
        withoutActions {
            current.ghost.position = ghostPosition(at: point, size: current.ghost.bounds.size)
            if gap != current.gap || slotDrop != current.slotDrop {
                showInsertionMark(gap)
                if let slotDrop { showSlotMark(slotDrop) }
            }
        }
        current.gap = gap
        current.slotDrop = slotDrop
        drag = current
    }

    private func stripGap(at point: CGPoint, for drag: Drag) -> Int? {
        canDropOnStrip(drag) ? dropGap(at: point, moving: movingSpace(of: drag)) : nil
    }

    private func slotDrop(at point: CGPoint, for drag: Drag) -> SlotDrop? {
        guard let slot = drag.slot, viewport.contains(point) else { return nil }
        let local = CGPoint(x: point.x, y: point.y + scrollOffset)
        guard pinnedArea.insetBy(dx: -24, dy: -8).contains(local) else { return nil }
        return StageLayout.drop(at: local, moving: slot, in: pinnedSlots)
    }

    /// Yeri değişecek mevcut alan; masaüstü penceresi sürüklenirken yeni alan açılacağı için nil.
    private func movingSpace(of drag: Drag) -> UInt64? {
        guard let window = drag.tile?.window, isReorder(window) else { return nil }
        return window.spaceID
    }

    /// Şerit bandındaysa imlecin düştüğü aralık; alanın zaten bulunduğu yerin iki yanı hariç.
    private func dropGap(at point: CGPoint, moving: UInt64?) -> Int? {
        guard let first = spaceRects.first?.rect, let last = spaceRects.last?.rect else { return nil }
        let band = CGRect(
            x: first.minX - 70,
            y: 0,
            width: last.maxX - first.minX + 140,
            height: first.maxY + 28
        )
        guard band.contains(point) else { return nil }
        let gap = SpaceOrder.gapIndex(forX: point.x, midXs: spaceRects.map(\.rect.midX))
        if let moving, let index = spaceRects.firstIndex(where: { $0.id == moving }),
           gap == index || gap == index + 1 {
            return nil
        }
        return gap
    }

    private func showInsertionMark(_ gap: Int?) {
        insertionMark?.removeFromSuperlayer()
        insertionMark = nil
        guard let gap, let x = SpaceOrder.dropX(gap: gap, frames: spaceRects.map(\.rect), margin: 8),
              let first = spaceRects.first?.rect
        else { return }
        addInsertionMark(CGRect(x: x - 2, y: first.minY - 3, width: 4, height: first.height + 6))
    }

    private func showSlotMark(_ drop: SlotDrop) {
        insertionMark?.removeFromSuperlayer()
        addInsertionMark(CGRect(
            x: drop.markX - 2, y: drop.markMinY - scrollOffset, width: 4, height: drop.markMaxY - drop.markMinY
        ))
    }

    private func addInsertionMark(_ frame: CGRect) {
        let mark = plainLayer()
        mark.frame = frame
        mark.cornerRadius = 2
        mark.backgroundColor = NSColor.controlAccentColor.cgColor
        mark.shadowColor = NSColor.controlAccentColor.cgColor
        mark.shadowOpacity = 0.8
        mark.shadowRadius = 6
        mark.shadowOffset = .zero
        mark.zPosition = 6000
        top.addSublayer(mark)
        insertionMark = mark
    }

    private func finishDrag(at point: CGPoint) {
        guard let finished = drag else { return }
        let gap = stripGap(at: point, for: finished)
        let slotDrop = gap == nil ? slotDrop(at: point, for: finished) : nil
        withoutActions {
            finished.ghost.removeFromSuperlayer()
            for entry in finished.faded { entry.layer.opacity = entry.opacity }
            insertionMark?.removeFromSuperlayer()
            insertionMark = nil
            drag = nil
            renderHint()
        }
        if let slot = finished.slot, let slotDrop {
            delegate?.scene { $0.move(slot, toGap: slotDrop.gap) }
        }
        guard let gap else { return }
        let before = gap < spaceRects.count ? spaceRects[gap].id : nil
        if let window = finished.tile?.window {
            delegate?.scene(didDrop: window, before: before)
        }
    }

    private func activate(_ hit: Target?) {
        guard let content else { return }
        switch hit {
        case .window(let id):
            guard let tile = tile(for: id) else { return }
            delegate?.scene(didChoose: tile.window)
        case .action(let id, let action):
            guard let tile = tile(for: id) else { return }
            switch action {
            case .snap(let position): delegate?.scene(didSnap: tile.window, to: position)
            case .fullScreen(let entering): delegate?.scene(didToggleFullScreen: tile.window, entering: entering)
            case .minimize: delegate?.scene(didMinimize: tile.window)
            case .nextDisplay: delegate?.scene(didMoveToNextDisplay: tile.window)
            case .close: delegate?.scene(didClose: tile.window)
            }
        case .app(let id):
            if fanApp != nil { closeFan() }
            if let app = content.snapshot.app(id) { delegate?.scene(didChooseApp: app) }
        case .chip(let id):
            guard let app = content.snapshot.app(id) else { return }
            if app.windows.count == 1, let only = app.windows.first {
                delegate?.scene(didChoose: only)
            } else if fanApp == id {
                closeFan()
            } else {
                openFan(id)
            }
        case .overflow(let id):
            openFan(id)
        case .space(let id):
            if let space = content.snapshot.spaces.first(where: { $0.id == id }) {
                delegate?.scene(didChooseSpace: space)
            }
        case .permission:
            if !content.screenRecordingGranted {
                delegate?.sceneDidRequestScreenRecordingSettings()
            } else {
                delegate?.sceneDidRequestAccessibilitySettings()
            }
        case .search:
            if !searchFocused {
                searchFocused = true
                withoutActions { renderHint() }
            }
        case .fanBackground:
            break
        case .launch(let index):
            if index < appResults.count { delegate?.scene(didLaunchApp: appResults[index].url) }
        case nil:
            // Boşluğa tıklama: önce açık yelpaze, sonra kaplama kapanır.
            if fanApp != nil {
                closeFan()
            } else {
                delegate?.sceneDidRequestDismiss()
            }
        }
    }

    // MARK: Tüm pencereler paneli

    private func openFan(_ id: String) {
        guard fanApp != id, let content, let app = content.snapshot.app(id), !app.windows.isEmpty else { return }
        closeFan()
        fanApp = id
        clearTip()

        let columns = min(app.windows.count, 5)
        let rows = (app.windows.count + columns - 1) / columns
        let maxPanelWidth = content.usable.width - 80
        let padding: CGFloat = 18
        let gap: CGFloat = 16
        let cellWidth = min(230, (maxPanelWidth - 2 * padding - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let imageHeight = (cellWidth * 0.66).rounded()
        let captionHeight: CGFloat = 36
        let cellHeight = imageHeight + captionHeight
        let width = CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap + 2 * padding
        let maxHeight = content.usable.height - 40
        let height = min(CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gap + 2 * padding, maxHeight)

        // Çip kaydırılıp gittiyse panel uygulamanın hücresinden açılır.
        let chip = chipLayers[id]?.frame.offsetBy(dx: 0, dy: -scrollOffset)
        let visibleChip = chip.flatMap { viewport.intersects($0) ? $0 : nil }
        let anchor = visibleChip ?? slotFrames[id]?.offsetBy(dx: 0, dy: -scrollOffset) ?? bounds
        let x = min(max(anchor.midX - width / 2, content.usable.minX + 12), content.usable.maxX - width - 12)
        let preferredY = visibleChip != nil ? anchor.minY - height - 12 : anchor.midY - height / 2
        let y = min(max(preferredY, content.usable.minY + 12), content.usable.maxY - height - 12)
        let panelRect = CGRect(x: x, y: y, width: width, height: height)

        withoutActions {
            let panel = plainLayer()
            panel.frame = panelRect
            panel.cornerRadius = 18
            panel.cornerCurve = .continuous
            panel.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.82).cgColor
            panel.borderWidth = 0.5
            panel.borderColor = NSColor(calibratedWhite: 1, alpha: 0.2).cgColor
            panel.shadowColor = NSColor.black.cgColor
            panel.shadowOpacity = 0.45
            panel.shadowRadius = 26
            panel.shadowOffset = CGSize(width: 0, height: 12)
            panel.zPosition = 1000
            top.addSublayer(panel)
            fanLayer = panel

            for (index, window) in app.windows.enumerated() {
                let row = index / columns
                let column = index % columns
                let cellX = panelRect.minX + padding + CGFloat(column) * (cellWidth + gap)
                let cellY = panelRect.minY + padding + CGFloat(row) * (cellHeight + gap)
                guard cellY + cellHeight <= panelRect.maxY else { break }

                let area = CGRect(x: cellX, y: cellY, width: cellWidth, height: imageHeight)
                let fitted = PileLayout.frames(in: area, aspects: [window.aspect])[0]
                let tile = makeTile(window, frame: fitted, badge: false)
                tile.restZ = 1010
                tile.root.zPosition = 1010
                top.addSublayer(tile.root)
                fanTiles[window.id] = tile
                fanHits.append(Hit(rect: fitted, target: .window(window.id)))

                let title = text(window.displayName(appName: app.name, windowCount: app.windows.count), font: .systemFont(ofSize: 11, weight: .medium))
                let titleSize = title.preferredFrameSize()
                title.frame = CGRect(x: cellX, y: area.maxY + 5, width: cellWidth, height: titleSize.height)
                title.zPosition = 1010
                top.addSublayer(title)

                let place = text(window.badge, font: .systemFont(ofSize: 10), color: NSColor(calibratedWhite: 1, alpha: 0.62))
                let placeSize = place.preferredFrameSize()
                place.frame = CGRect(x: cellX, y: area.maxY + 5 + titleSize.height, width: cellWidth, height: placeSize.height)
                place.zPosition = 1010
                top.addSublayer(place)
            }
        }
    }

    private func clearTip() {
        tip?.removeFromSuperlayer()
        tip = nil
    }

    private func closeFan() {
        guard fanApp != nil else { return }
        let keepTip = tip
        withoutActions {
            top.sublayers?.filter { $0 !== keepTip }.forEach { $0.removeFromSuperlayer() }
        }
        if let id = windowID(of: hovered), fanTiles[id] != nil { hovered = nil }
        fanTiles = [:]
        fanHits = []
        fanApp = nil
        fanLayer = nil
    }

    // MARK: - Klavye

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘1…⌘9: şeritteki o alana geç.
        if flags.contains(.command), let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
            if let spaces = content?.snapshot.spaces, digit <= spaces.count {
                delegate?.scene(didChooseSpace: spaces[digit - 1])
            }
            return
        }
        if flags.contains(.command), event.charactersIgnoringModifiers == "v" {
            let pasted = (NSPasteboard.general.string(forType: .string) ?? "")
                .components(separatedBy: .newlines).joined(separator: " ")
            if !pasted.isEmpty { setQuery((selectAll ? "" : query) + pasted) }
            return
        }
        if flags.contains(.command), event.charactersIgnoringModifiers == "a" {
            if !query.isEmpty {
                selectAll = true
                withoutActions {
                    renderHint()
                    renderResults()
                }
            }
            return
        }
        switch Int(event.keyCode) {
        case 123, 124, 125, 126: // Oklar: seçimi en yakın önizlemeye taşır.
            if selectAll {
                selectAll = false
                withoutActions {
                    renderHint()
                    renderResults()
                }
            }
            moveSelection(keyCode: Int(event.keyCode))
        case 53: // Esc: arama, sonra panel, sonra kaplama
            if !query.isEmpty {
                setQuery("")
            } else if fanApp != nil {
                closeFan()
            } else {
                delegate?.sceneDidRequestDismiss()
            }
        case 36, 76: // Return: klavyeyle seçilen, yoksa ilk eşleşen
            if let id = windowID(of: hovered), let tile = tile(for: id) {
                delegate?.scene(didChoose: tile.window)
            } else if !query.isEmpty, let first = firstMatch() {
                delegate?.scene(didChoose: first)
            } else if !query.isEmpty, let app = firstAppMatch() {
                // Penceresi eşleşmeyen uygulama (kapalı sabit uygulama dahil): açılır.
                delegate?.scene(didChooseApp: app)
            } else if !query.isEmpty, let installed = appResults.first {
                // Sahnede hiç yoksa: kurulu ama açık olmayan uygulama.
                delegate?.scene(didLaunchApp: installed.url)
            }
        case 51: // ⌫ aramanın tümünü siler; kullanıcı baştan yazar.
            if !query.isEmpty { setQuery("") }
        default:
            guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
                  let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return }
            setQuery((selectAll ? "" : query) + characters)
        }
    }

    // ⌘V ve ⌘⌫ panelin menüsü olmadığı için burada yakalanır.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers ?? ""
        guard event.type == .keyDown, event.modifierFlags.contains(.command),
              key == "v" || key == "a" || Int(key) != nil || event.keyCode == 51
        else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    /// Okla seçim: önce eşleşen önizlemeler arasında, yön ekseninde en yakın olana geçer.
    /// Seçim fare üstüne gelmekle aynı görünür (büyür, çerçeve, başlık).
    private func moveSelection(keyCode: Int) {
        let pool = Array((fanApp != nil ? fanTiles : tiles).values)
            .filter { query.isEmpty || matches($0.window) }
        guard !pool.isEmpty else { return }
        let current = windowID(of: hovered).flatMap { id in pool.first { $0.window.id == id } }
        guard let current else {
            let start = query.isEmpty ? nil : firstMatch().flatMap { match in pool.first { $0.window.id == match.id } }
            let first = start ?? pool.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            if let first { select(first) }
            return
        }
        let from = CGPoint(x: current.frame.midX, y: current.frame.midY)
        let best = pool.filter { $0 !== current }.compactMap { tile -> (Tile, CGFloat)? in
            let dx = tile.frame.midX - from.x, dy = tile.frame.midY - from.y
            // Görünüm uzayı sol üst orijinli: aşağı +y.
            let (along, across): (CGFloat, CGFloat)
            switch keyCode {
            case 123: (along, across) = (-dx, dy)
            case 124: (along, across) = (dx, dy)
            case 125: (along, across) = (dy, dx)
            default: (along, across) = (-dy, dx)
            }
            guard along > 8 else { return nil }
            return (tile, along + abs(across) * 2)
        }.min { $0.1 < $1.1 }?.0
        if let best { select(best) }
    }

    private func select(_ tile: Tile) {
        scrollIntoView(tile)
        setHover(.window(tile.window.id))
    }

    #if DEBUG
    func debugSetQuery(_ next: String) { setQuery(next) }
    #endif

    private func setQuery(_ next: String) {
        query = next
        searchFocused = true
        selectAll = false
        if case .window? = hovered { clearHover() }
        withoutActions {
            renderHint()
            applyQuery()
            renderResults()
        }
        // En iyi eşleşme aşağıda kaldıysa ↩'un nereye gideceği görünsün.
        if !query.isEmpty, let best = firstMatch(), let tile = tiles[best.id] { scrollIntoView(tile) }
    }

    /// Yazınca arama kutusu, macOS'un Uygulamalar görünümü gibi tek bir panele dönüşür: üstte arama
    /// satırı, altında adı uyan uygulamaların simge ızgarası. Sahnenin yerleşimini değiştirmez; üstünde durur.
    private func renderResults() {
        resultsLayer?.removeFromSuperlayer()
        resultsLayer = nil
        hintContainer?.isHidden = false
        hits.removeAll { if case .launch = $0.target { return true } else { return false } }
        guard let content, !query.isEmpty, drag == nil else {
            appResults = []
            return
        }
        appResults = InstalledApps.shared.matching(query, excluding: [], limit: 14)
        guard !appResults.isEmpty else { return }

        // Sahnenin malzemesi: yarı saydam koyu cam, ince açık kenar, beyaz yazı (alttaki çipler gibi).
        let ink = NSColor.white
        let soft = NSColor(calibratedWhite: 1, alpha: 0.6)

        let columns = min(7, appResults.count), rows = (appResults.count + columns - 1) / columns
        let cell = CGSize(width: 104, height: 100), pad: CGFloat = 14, gridGap: CGFloat = 12
        let searchHeight = hintRect.height
        let width = max(hintRect.width, CGFloat(columns) * cell.width + pad * 2)
        let enterLaunches = firstMatch() == nil && firstAppMatch() == nil
        let panel = plainLayer()
        // Arama satırı kutunun tam yerinde: kutu aşağı doğru büyümüş gibi görünür.
        panel.frame = CGRect(x: content.usable.midX - width / 2, y: hintRect.minY,
                             width: width, height: searchHeight + gridGap * 2 + CGFloat(rows) * cell.height)
        panel.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.66).cgColor
        panel.cornerRadius = 18
        panel.cornerCurve = .continuous
        panel.borderWidth = 1
        panel.borderColor = NSColor(calibratedWhite: 1, alpha: 0.2).cgColor

        // Arama satırı: kutudakiyle aynı büyüteç, yazı ve imleç.
        if let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [soft]))) {
            let glass = iconLayer(symbol, size: 16)
            glass.frame = CGRect(x: 13, y: (searchHeight - 16) / 2, width: 16, height: 16)
            panel.addSublayer(glass)
        }
        let typed = text(query, font: .systemFont(ofSize: 14, weight: .medium), color: ink)
        let typedSize = typed.preferredFrameSize()
        typed.frame = CGRect(x: 37, y: (searchHeight - typedSize.height) / 2, width: min(typedSize.width, width - 37 - pad), height: typedSize.height)
        if selectAll {
            let selection = plainLayer()
            selection.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
            selection.cornerRadius = 3
            selection.frame = typed.frame.insetBy(dx: -2, dy: -1)
            panel.addSublayer(selection)
        } else {
            let caret = plainLayer()
            caret.backgroundColor = NSColor.white.cgColor
            caret.frame = CGRect(x: typed.frame.maxX + 1, y: (searchHeight - 18) / 2, width: 1.5, height: 18)
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1
            blink.toValue = 0
            blink.duration = 0.53
            blink.autoreverses = true
            blink.repeatCount = .infinity
            caret.add(blink, forKey: "blink")
            panel.addSublayer(caret)
        }
        panel.addSublayer(typed)
        let divider = plainLayer()
        divider.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        divider.frame = CGRect(x: pad, y: searchHeight, width: width - pad * 2, height: 1)
        panel.addSublayer(divider)

        let gridX = (width - CGFloat(columns) * cell.width) / 2
        for (index, app) in appResults.enumerated() {
            let column = index % columns, row = index / columns
            let origin = CGPoint(x: gridX + CGFloat(column) * cell.width, y: searchHeight + gridGap + CGFloat(row) * cell.height)
            if index == 0 && enterLaunches {
                // ↩ bunu açar.
                let mark = plainLayer()
                mark.frame = CGRect(origin: origin, size: cell).insetBy(dx: 5, dy: 0)
                mark.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
                mark.cornerRadius = 14
                mark.cornerCurve = .continuous
                panel.addSublayer(mark)
            }
            let icon = iconLayer(NSWorkspace.shared.icon(forFile: app.url.path), size: 52)
            icon.frame = CGRect(x: origin.x + (cell.width - 52) / 2, y: origin.y + 12, width: 52, height: 52)
            panel.addSublayer(icon)
            let name = text(app.name, font: .systemFont(ofSize: 11, weight: .medium), color: ink, shadow: true)
            name.alignmentMode = .center
            name.frame = CGRect(x: origin.x + 6, y: origin.y + 72, width: cell.width - 12, height: name.preferredFrameSize().height)
            panel.addSublayer(name)
            hits.append(Hit(rect: CGRect(x: panel.frame.minX + origin.x, y: panel.frame.minY + origin.y, width: cell.width, height: cell.height),
                            target: .launch(index)))
        }
        // Panelin arama satırı kutunun yerini alır.
        hintContainer?.isHidden = true
        // Önizlemelerin üstünde dursun.
        panel.zPosition = 7000
        self.top.addSublayer(panel)
        resultsLayer = panel
    }

    private func matches(_ window: SceneWindow) -> Bool {
        let appName = content?.snapshot.app(window.appID)?.name ?? ""
        return SearchMatcher.matches(query: query, in: [window.title, appName])
    }

    /// Yerleşim sırasında ilk eşleşen pencere: ↩ ona gider.
    private func firstMatch() -> SceneWindow? {
        guard let content else { return nil }
        for id in content.arrangement.pinned {
            if let match = content.snapshot.app(id)?.windows.first(where: matches) { return match }
        }
        for app in content.snapshot.otherApps(pinned: content.arrangement.pinned) {
            if let match = app.windows.first(where: matches) { return match }
        }
        return nil
    }

    /// Adı aramayla eşleşen ilk uygulama, yerleşim sırasıyla; kapalı sabit uygulamalar dahil.
    private func firstAppMatch() -> SceneApp? {
        guard let content else { return nil }
        let ordered = content.arrangement.pinned.compactMap { content.snapshot.app($0) }
            + content.snapshot.otherApps(pinned: content.arrangement.pinned)
        return ordered.first { SearchMatcher.matches(query: query, in: [$0.name]) }
    }

    private func applyQuery() {
        guard let content else { return }
        let best = query.isEmpty ? nil : firstMatch()?.id
        for tile in tiles.values {
            tile.root.opacity = query.isEmpty || matches(tile.window) ? 1 : 0.18
            if windowID(of: hovered) != tile.window.id {
                tile.ring.isHidden = tile.window.id != best
            }
        }
        for (id, layers) in slotLayers {
            let appMatches = query.isEmpty
                || (content.snapshot.app(id)?.windows.contains(where: matches) ?? false)
                || SearchMatcher.matches(query: query, in: [content.snapshot.app(id)?.name ?? ""])
            for layer in layers where !tiles.values.contains(where: { $0.root === layer }) {
                layer.opacity = appMatches ? (layer.opacity < 0.75 && query.isEmpty ? layer.opacity : 1) : 0.25
            }
        }
    }

    // MARK: - Sağ tık menüsü

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let content, let id = appID(at: point) else { return }
        let isPinned = content.arrangement.pinned.contains(id)
        let menu = NSMenu()

        if isPinned {
            let index = content.arrangement.pinned.firstIndex(of: id) ?? 0
            menu.addItem(item(tx("Sola taşı", "Move Left"), action: #selector(moveSlotLeft(_:)), id: id, enabled: index > 0))
            menu.addItem(item(tx("Sağa taşı", "Move Right"), action: #selector(moveSlotRight(_:)), id: id,
                              enabled: index < content.arrangement.pinned.count - 1))
            menu.addItem(.separator())

            let sizes: [(String, SlotSize)] = [(tx("Küçük", "Small"), .small), (tx("Orta", "Medium"), .medium), (tx("Büyük", "Large"), .large)]
            for (title, size) in sizes {
                let entry = item(title, action: #selector(changeSize(_:)), id: "\(size.rawValue)|\(id)")
                entry.state = content.arrangement.size(of: id) == size ? .on : .off
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(item(tx("Sabitlemeyi kaldır", "Unpin"), action: #selector(unpin(_:)), id: id))
        } else {
            menu.addItem(item(tx("Sabitle", "Pin"), action: #selector(pin(_:)), id: id))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func appID(at point: CGPoint) -> String? {
        if case .chip(let id)? = target(at: point) { return id }
        guard viewport.contains(point) else { return nil }
        let local = CGPoint(x: point.x, y: point.y + scrollOffset)
        return slotFrames.first { $0.value.contains(local) }?.key
    }

    private func item(_ title: String, action: Selector, id: String, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.isEnabled = enabled
        return item
    }

    @objc private func moveSlotLeft(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.scene { $0.move(id, by: -1) }
    }

    @objc private func moveSlotRight(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.scene { $0.move(id, by: 1) }
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let size = SlotSize(rawValue: parts[0]) else { return }
        delegate?.scene { $0.sizes[parts[1]] = size }
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.scene { $0.unpin(id) }
    }

    @objc private func pin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let count = content?.snapshot.app(id)?.windows.count ?? 1
        delegate?.scene { $0.pin(id, windowCount: count) }
    }
}

/// `CATextLayer` emoji içeren başlıkları hiç çizemiyor (şeritte boş etiket olarak görüldü).
/// Çizimi AppKit'e bırakınca sistemin metin motoru emoji ve kısaltmayı doğru yapıyor.
final class LabelLayer: CATextLayer {
    override func preferredFrameSize() -> CGSize {
        guard let string = string as? NSAttributedString else { return .zero }
        let size = string.size()
        return CGSize(width: ceil(size.width) + 1, height: ceil(size.height))
    }

    override func draw(in context: CGContext) {
        guard let string = string as? NSAttributedString, string.length > 0 else { return }
        let text = NSMutableAttributedString(attributedString: string)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        switch alignmentMode {
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: contentsAreFlipped())
        text.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension SceneViewDelegate {
    func scene(_ change: (inout Arrangement) -> Void) {
        scene(changeArrangement: change)
    }
}
