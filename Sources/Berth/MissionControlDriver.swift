import AppKit
import BerthCore

/// Tam ekran alanlarının sırasını Mission Control'ün kendi şeridinde sürükleyerek değiştirir.
///
/// macOS sırayı değiştirecek bir API sunmuyor; bunu doğrudan yapan araçlar (yabai) SIP'in
/// kapatılmasını istiyor. Mission Control'ün şeridi ise Erişilebilirlik ağacında duruyor,
/// kullanıcının yapacağı sürükleme taklit edilebiliyor. Bedeli: Mission Control birkaç saniye
/// görünür, imleç bu sırada kullanılır. Ağacın yapısı belgesiz olduğu için bir macOS güncellemesi
/// bozabilir; o yüzden sonuç her seferinde macOS'tan geri okunur.
@MainActor
enum MissionControlDriver {

    enum Failure: Error {
        case accessibilityDenied
        case didNotOpen
        case unexpectedLayout
        case notMoved
    }

    private static let appURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    private static let attempts = 2

    /// `spaceID`'yi `before` alanının hemen soluna taşır; `before` nil ise en sağa.
    static func moveSpace(_ spaceID: UInt64, before: UInt64?, on screen: NSScreen) async throws {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityDenied }
        let order = currentOrder(on: screen)
        guard order.contains(spaceID) else { throw Failure.unexpectedLayout }
        let moves = SpaceOrder.plan(order: order, moving: spaceID, before: before)
        guard !moves.isEmpty else { return }

        let cursor = CGEvent(source: nil)?.location
        defer {
            if let cursor { post(.mouseMoved, at: cursor) }
        }
        for move in moves {
            try await perform(move.space, before: move.before, on: screen)
            try? await pause(0.4)
        }
    }

    private static func perform(_ spaceID: UInt64, before: UInt64?, on screen: NSScreen) async throws {
        var lastError = Failure.notMoved
        for attempt in 0..<attempts {
            do {
                try await performDrag(spaceID, before: before, on: screen)
                await closeIfOpen(on: screen)
                try? await pause(0.5)
                if SpaceOrder.isPlaced(order: currentOrder(on: screen), moving: spaceID, before: before) { return }
                lastError = .notMoved
            } catch let failure as Failure {
                lastError = failure
                await closeIfOpen(on: screen)
            }
            if attempt + 1 < attempts { try? await pause(0.7) }
        }
        throw lastError
    }

    // MARK: - Sürükleme

    private static func performDrag(_ spaceID: UInt64, before: UInt64?, on screen: NSScreen) async throws {
        guard let list = try await openAndFindList(on: screen) else { throw Failure.didNotOpen }

        let frames = try await expandedFrames(of: list, on: screen)

        let order = currentOrder(on: screen)
        let buttons = children(of: list)
        // Yanlış alanı sürüklemek kullanıcının düzenini bozar: şerit beklenen alanları
        // aynı sırada göstermiyorsa hiç dokunulmaz.
        guard frames.count == order.count, buttons.count == order.count,
              titlesMatch(buttons, order: order, on: screen),
              let sourceIndex = order.firstIndex(of: spaceID),
              let gap = SpaceOrder.destinationGap(order: order, moving: spaceID, before: before),
              gap > 0, // İlk alanın solu bırakma alanı değil; bkz. SpaceOrder.plan.
              let targetX = SpaceOrder.dropX(gap: gap, frames: frames)
        else {
            trace("abort: order=\(order) buttons=\(buttons.compactMap { attribute($0, kAXTitleAttribute) as? String })")
            throw Failure.unexpectedLayout
        }

        trace("order=\(order) moving=\(spaceID) before=\(String(describing: before)) gap=\(gap) x=\(targetX) frames=\(frames.map { "\(Int($0.minX))+\(Int($0.width))@\(Int($0.minY))" })")
        let source = frames[sourceIndex]
        let start = CGPoint(x: source.midX, y: source.midY)
        // Alan tutulunca diğer küçük resimler kayıyor (ölçüldü). Önceden hesaplanan nokta komşu
        // alanın üstüne düşer ve iki tam ekran yan yana birleşir. Bu yüzden hedef, iki komşunun
        // o anki konumundan canlı hesaplanır. Öğeler sürükleme boyunca geçerli kalır.
        let left = gap > 0 ? buttons[gap - 1] : nil
        let right = gap < buttons.count ? buttons[gap] : nil
        func liveTargetX() -> CGFloat {
            let leftFrame = left.flatMap(frame)
            let rightFrame = right.flatMap(frame)
            switch (leftFrame, rightFrame) {
            case let (l?, r?): return (l.maxX + r.minX) / 2
            case let (l?, nil): return l.maxX + 14
            case let (nil, r?): return r.minX - 14
            default: return targetX
            }
        }
        var current = start

        post(.mouseMoved, at: start)
        try await pause(0.25)
        post(.leftMouseDown, at: start)
        // Her durumda bırak: basılı kalan tuş kullanıcının faresini kilitlerdi.
        var released = false
        defer { if !released { post(.leftMouseUp, at: current) } }

        try await pause(0.35)
        // Hedefe doğru yaklaş; her adımda hedefi yeniden oku.
        for step in 1...20 {
            let remaining = CGFloat(21 - step)
            current.x += (liveTargetX() - current.x) / remaining
            post(.leftMouseDragged, at: current)
            try await pause(0.04)
        }
        // Küçük resimler yerine oturana kadar son konuma yerleş.
        for _ in 0..<8 {
            try await pause(0.07)
            current.x = liveTargetX()
            post(.leftMouseDragged, at: current)
        }
        try await pause(0.2)
        current.x = liveTargetX()
        post(.leftMouseDragged, at: current)
        try await pause(0.12)
        trace("birakma x=\(current.x) sol=\(left.flatMap(frame).map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "-") sag=\(right.flatMap(frame).map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "-")")
        post(.leftMouseUp, at: current)
        released = true
        try await pause(0.5)
        trace("after drop: order=\(currentOrder(on: screen)) mcOpen=\(spacesList(on: screen) != nil) titles=\(children(of: list).compactMap { attribute($0, kAXTitleAttribute) as? String })")
    }

    private static func openAndFindList(on screen: NSScreen) async throws -> AXUIElement? {
        if let list = spacesList(on: screen), !children(of: list).isEmpty { return list }
        NSWorkspace.shared.open(appURL)
        for index in 0..<80 {
            if let list = spacesList(on: screen), !children(of: list).isEmpty { return list }
            // Alan geçişine denk gelirse açılış yutuluyor (ölçüldü).
            if index == 40 { NSWorkspace.shared.open(appURL) }
            try await pause(0.05)
        }
        return nil
    }

    /// Küçük resimler kapalıyken ekranın üstünde durur (ölçüldü: y = -32) ve yalnızca imleç
    /// şeride gelince açılır. Açılış animasyonu sırasındaki imleç hareketi yok sayıldığı için
    /// şerit gerçekten açılana kadar imleç kıpırdatılır, sonra konumların oturması beklenir.
    private static func expandedFrames(of list: AXUIElement, on screen: NSScreen) async throws -> [CGRect] {
        let bounds = CGDisplayBounds(screen.displayID)
        var frames: [CGRect] = []
        var stable = 0
        for step in 0..<60 {
            post(.mouseMoved, at: CGPoint(x: bounds.midX, y: bounds.minY + (step % 2 == 0 ? 30 : 60)))
            try await pause(0.08)
            let next = children(of: list).compactMap(frame)
            let expanded = !next.isEmpty && next.allSatisfy { $0.minY >= bounds.minY && $0.height > 40 }
            if expanded, next == frames {
                stable += 1
                if stable >= 4 { return next }
            } else {
                stable = 0
            }
            frames = next
        }
        throw Failure.unexpectedLayout
    }

    private static func closeIfOpen(on screen: NSScreen) async {
        guard spacesList(on: screen) != nil else { return }
        NSWorkspace.shared.open(appURL)
        for _ in 0..<30 {
            if spacesList(on: screen) == nil { return }
            try? await pause(0.05)
        }
    }

    // MARK: - Okuma

    /// Tam ekran alanlarında şerit başlığı uygulamanın ya da (aynı uygulamanın birden çok tam ekranı
    /// varsa) pencerenin adıdır (ölçüldü: "Windows App" ve "Home PC"). İkisi de kabul edilir.
    /// Ekran Kaydı izni yokken başlıklar okunamaz; o zaman yalnızca alan sayısı denetlenir ve
    /// sonuç sürüklemeden sonra geri okunur.
    private static func titlesMatch(_ buttons: [AXUIElement], order: [UInt64], on screen: NSScreen) -> Bool {
        guard let display = SceneSource.managedDisplay(for: screen) else { return false }
        let canReadTitles = Permissions.screenRecording
        let fullScreen = Set(display.spaces.filter(\.isFullScreen).map(\.id))
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        var owners: [UInt64: Set<String>] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let owner = info[kCGWindowOwnerName as String] as? String
            else { continue }
            for space in SkyLight.spaces(forWindow: number) where fullScreen.contains(space) {
                owners[space, default: []].insert(normalize(owner))
                if let title = info[kCGWindowName as String] as? String, !title.isEmpty {
                    owners[space, default: []].insert(normalize(title))
                }
            }
        }

        guard canReadTitles else { return true }
        for (button, space) in zip(buttons, order) where fullScreen.contains(space) {
            // Yan yana (Split View) alanda başlık iki adı birden taşır: "Google Chrome ve TextEdit".
            guard let title = (attribute(button, kAXTitleAttribute) as? String).map(normalize),
                  owners[space]?.contains(where: { title.contains($0) }) == true
            else { return false }
        }
        return true
    }

    /// Bazı uygulama adları görünmez yön işaretiyle başlar.
    private static func normalize(_ name: String) -> String {
        name.unicodeScalars
            .filter { !["\u{200E}", "\u{200F}"].contains(String($0)) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    private static func currentOrder(on screen: NSScreen) -> [UInt64] {
        SceneSource.managedDisplay(for: screen)?.spaces.map(\.id) ?? []
    }

    private static func spacesList(on screen: NSScreen) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.5)

        guard let root = children(of: application).first(where: { identifier(of: $0) == "mc" }) else { return nil }
        let displays = children(of: root).filter { identifier(of: $0) == "mc.display" }
        let bounds = CGDisplayBounds(screen.displayID)
        let display = displays.first { frame($0).map { $0.intersects(bounds) } ?? false } ?? displays.first
        guard let display,
              let group = children(of: display).first(where: { identifier(of: $0) == "mc.spaces" })
        else { return nil }
        return children(of: group).first { identifier(of: $0) == "mc.spaces.list" }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func identifier(of element: AXUIElement) -> String? {
        attribute(element, "AXIdentifier") as? String
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func trace(_ line: String) {
        #if DEBUG
        let path = NSTemporaryDirectory() + "berth-mc-trace.txt"
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }

    // MARK: - Olay

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
