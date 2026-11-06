import AppKit
import CoreImage
import OSLog
import ScreenCaptureKit

/// Pencerelerin anlık görüntüleri.
///
/// Canlı yayın değil: pencere başına `SCStream` gün boyu açık duran bir ajanda kabul
/// edilemez bir enerji maliyeti olurdu. Eski görüntü elde tutulur, kaplama anında dolar,
/// yenisi geldikçe yerine geçer.
@MainActor
final class ThumbnailStore {
    private static let log = Logger(subsystem: "io.github.brkhsdmr.berth", category: "Thumbnails")

    /// Sınırsız paralellik pencere sunucusunu tıkıyor; V1'de ölçülen denge 5.
    private static let concurrency = 5
    /// Pencere boyutuna göre yakalama ölçeği. Uçuş başında önizleme gerçek boyutuna yakın
    /// görünür; bulanık kalmaması için küçük önizlemelerden daha çok piksel gerekir.
    private nonisolated static let scale: CGFloat = 0.7

    private(set) var images: [CGWindowID: CGImage] = [:]
    var onImage: ((CGWindowID, CGImage) -> Void)?
    /// Önizlemeler kapalıyken ya da izin yokken hiç yakalama yapılmaz.
    var isEnabled: () -> Bool = { false }

    private var task: Task<Void, Never>?
    /// ScreenCaptureKit'ten gelen görüntüler. Yedek yolun beyaz video yüzeyi bunların
    /// üstüne yazılmaz: o alana bir kez gidildiyse gerçek görüntü korunur.
    private var fromPrimary: Set<CGWindowID> = []

    func image(for id: CGWindowID) -> CGImage? { images[id] }

    /// - Parameter keepingOthers: Yalnızca bir uygulamanın pencereleri tazelenirken diğerlerinin
    ///   görüntüleri silinmesin (Dock önizlemesi).
    func refresh(windowIDs: [CGWindowID], keepingOthers: Bool = false) {
        guard isEnabled(), !windowIDs.isEmpty else { return }
        task?.cancel()

        let wanted = Set(windowIDs)
        if !keepingOthers {
            images = images.filter { wanted.contains($0.key) }
            fromPrimary = fromPrimary.intersection(wanted)
        }

        task = Task { [weak self] in
            var windows: [SCWindow] = []
            do {
                // onScreenWindowsOnly false: başka masaüstündeki pencereler de gerekli.
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                windows = content.windows.filter { wanted.contains($0.windowID) }
            } catch {
                Self.log.error("Paylaşılabilir içerik alınamadı: \(error.localizedDescription, privacy: .public)")
            }
            var failed = wanted.subtracting(windows.map(\.windowID))

            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                var next = 0
                func addNext() {
                    guard next < windows.count else { return }
                    let window = windows[next]
                    next += 1
                    group.addTask { (window.windowID, await Self.capture(window)) }
                }
                for _ in 0..<min(Self.concurrency, windows.count) { addNext() }

                for await (id, image) in group {
                    guard !Task.isCancelled else { return }
                    if var image, let self {
                        #if DEBUG
                        if DemoMode.mosaic { image = DemoMode.mosaic(image) }
                        #endif
                        self.images[id] = image
                        self.fromPrimary.insert(id)
                        self.onImage?(id, image)
                    } else {
                        failed.insert(id)
                    }
                    addNext()
                }
            }

            guard !Task.isCancelled, let self else { return }
            for id in failed where !self.fromPrimary.contains(id) {
                if var image = SkyLight.captureWindow(id) {
                    #if DEBUG
                    if DemoMode.mosaic { image = DemoMode.mosaic(image) }
                    #endif
                    self.images[id] = image
                    self.onImage?(id, image)
                }
            }
        }
    }

    func clear() {
        task?.cancel()
        images = [:]
        fromPrimary = []
    }

    private nonisolated static func capture(_ window: SCWindow) async -> CGImage? {
        let width = Int((window.frame.width * scale).rounded())
        let height = Int((window.frame.height * scale).rounded())
        guard width > 8, height > 8 else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // Gölgeyi ve köşeleri kendimiz çiziyoruz.
        configuration.ignoreShadowsSingleWindow = true

        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        )
    }
}

/// Duvar kağıdı: masaüstü küçük resimleri için ham, zemin için bulanık.
@MainActor
final class WallpaperStore {
    struct Entry {
        var raw: CGImage
        var blurred: CGImage
    }

    private nonisolated static let log = Logger(subsystem: "io.github.brkhsdmr.berth", category: "Wallpaper")

    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var inFlight: Set<CGDirectDisplayID> = []
    private var sourceFiles: [CGDirectDisplayID: URL] = [:]
    var onUpdate: ((CGDirectDisplayID) -> Void)?

    func entry(for screen: NSScreen) -> Entry? { entries[screen.displayID] }

    func invalidate() {
        entries.removeAll()
        sourceFiles.removeAll()
    }

    /// Duvar kağıdını dosyasından okur: izin istemez, macOS'un kayıt göstergesini tetiklemez.
    /// Dosya okunamazsa (izin ve `canCapture` varsa) ekrandan yakalar.
    ///
    /// - Parameter canCapture: Tam ekran alanında `false` olmalı: orada duvar kağıdı yoktur,
    ///   tüm pencereler dışlanınca kare simsiyah gelir.
    func prepare(for screen: NSScreen, canCapture: Bool) {
        let id = screen.displayID
        guard !inFlight.contains(id) else { return }
        let fileURL = NSWorkspace.shared.desktopImageURL(for: screen)
        // Aynı dosya zaten hazırsa yeniden okumaya gerek yok.
        if entries[id] != nil, let fileURL, sourceFiles[id] == fileURL { return }
        inFlight.insert(id)

        let authorized = canCapture
        let scale = screen.backingScaleFactor

        Task { [weak self] in
            var raw = await Task.detached(priority: .userInitiated) {
                fileURL.flatMap(Self.loadImage).map(ImageBox.init)
            }.value?.image
            if raw == nil, authorized { raw = await Self.captureDesktop(displayID: id) }

            var entry: Entry?
            if let raw {
                let box = ImageBox(raw)
                // Zemin bulanık olduğu için küçük görüntüden üretilir: katman büyütür, fark görünmez.
                // Tam boyutta iki ekran için ~30 MB tutuyordu, böyle 1 MB'ın altında (ölçüldü).
                let small = Self.downscale(box.image, maxPixels: Self.blurPixels).map(ImageBox.init) ?? box
                let ratio = CGFloat(small.image.width) / (CGFloat(raw.width) / scale) // nokta başına piksel
                let blurred = await Task.detached(priority: .userInitiated) {
                    Self.blur(small.image, radius: 11 * ratio).map(ImageBox.init)
                }.value
                // Ham görüntü yalnızca şeritteki küçük masaüstü resimlerinde kullanılıyor.
                let thumb = Self.downscale(raw, maxPixels: Self.rawPixels) ?? raw
                if let blurred { entry = Entry(raw: thumb, blurred: blurred.image) }
            }

            guard let self else { return }
            self.inFlight.remove(id)
            if let entry {
                self.entries[id] = entry
                self.sourceFiles[id] = fileURL
                self.onUpdate?(id)
            } else {
                Self.log.error("Duvar kağıdı alınamadı")
            }
        }
    }

    private final class ImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private nonisolated static let blurPixels = 480
    private nonisolated static let rawPixels = 512

    /// En uzun kenarı `maxPixels` olacak şekilde küçültür; zaten küçükse nil.
    private nonisolated static func downscale(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixels else { return nil }
        let factor = CGFloat(maxPixels) / CGFloat(longest)
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private nonisolated static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Tüm pencereler hariç tutulunca karede duvar kağıdı kalır.
    private nonisolated static func captureDesktop(displayID: CGDirectDisplayID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: content.windows)
            if #available(macOS 14.2, *) { filter.includeMenuBar = false }

            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(filter.contentRect.width))
            configuration.height = max(1, Int(filter.contentRect.height))
            configuration.showsCursor = false
            configuration.shouldBeOpaque = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            log.error("Duvar kağıdı yakalanamadı: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func blur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: input.clampedToExtent(),
            kCIInputRadiusKey: radius
        ])?.outputImage,
        let toned = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: blurred.cropped(to: extent),
            kCIInputSaturationKey: 1.2
        ])?.outputImage
        else { return nil }
        // Küçük görüntü: işlemcide çizmek GPU önbelleği ve IOSurface ayırmaz.
        return CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]).createCGImage(toned, from: extent)
    }
}
