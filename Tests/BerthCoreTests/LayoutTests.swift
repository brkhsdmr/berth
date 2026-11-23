import CoreGraphics
import XCTest
@testable import BerthCore

final class StageLayoutTests: XCTestCase {
    private let stage = CGRect(x: 40, y: 170, width: 1570, height: 800)
    private let specs: [SlotSpec] = [
        .init(id: "finder", size: .medium), .init(id: "chrome", size: .large),
        .init(id: "claude", size: .medium), .init(id: "terminal", size: .small),
        .init(id: "windows", size: .small), .init(id: "whatsapp", size: .small),
        .init(id: "github", size: .small), .init(id: "notes", size: .small),
        .init(id: "xcode", size: .small)
    ]

    func testEverySlotIsPlacedInOrderOnce() {
        XCTAssertEqual(StageLayout.place(specs, in: stage).map(\.id), specs.map(\.id))
    }

    func testSlotsStayInsideStage() {
        for slot in StageLayout.place(specs, in: stage) {
            XCTAssertTrue(stage.insetBy(dx: -0.5, dy: -0.5).contains(slot.frame), "\(slot.id): \(slot.frame)")
        }
    }

    func testSlotsNeverOverlap() {
        let placed = StageLayout.place(specs, in: stage)
        for (i, a) in placed.enumerated() {
            for b in placed[(i + 1)...] {
                XCTAssertFalse(a.frame.intersects(b.frame), "\(a.id) ve \(b.id) çakışıyor")
            }
        }
    }

    func testLargerSizeIsWider() {
        let placed = Dictionary(uniqueKeysWithValues: StageLayout.place(specs, in: stage).map { ($0.id, $0) })
        XCTAssertGreaterThan(placed["chrome"]!.frame.width, placed["finder"]!.frame.width)
        XCTAssertGreaterThan(placed["finder"]!.frame.width, placed["notes"]!.frame.width)
    }

    func testSameInputGivesSameFrames() {
        XCTAssertEqual(StageLayout.place(specs, in: stage), StageLayout.place(specs, in: stage))
    }

    func testWindowCountCannotMoveAnySlot() {
        // Boyut atandıktan sonra pencere sayısı değişse de düzen aynı kalmalı.
        var arrangement = Arrangement(pinned: ["a", "b", "c"])
        arrangement.assignInitialSizeIfNeeded(id: "a", windowCount: 1)
        arrangement.assignInitialSizeIfNeeded(id: "b", windowCount: 5)
        arrangement.assignInitialSizeIfNeeded(id: "c", windowCount: 2)
        let before = StageLayout.place(arrangement.specs, in: stage)

        XCTAssertFalse(arrangement.assignInitialSizeIfNeeded(id: "a", windowCount: 12))
        XCTAssertFalse(arrangement.assignInitialSizeIfNeeded(id: "b", windowCount: 1))
        XCTAssertEqual(StageLayout.place(arrangement.specs, in: stage), before)
    }

    func testEmptyInput() {
        XCTAssertTrue(StageLayout.place([], in: stage).isEmpty)
        XCTAssertTrue(StageLayout.place(specs, in: .zero).isEmpty)
    }

    func testPileHeightLeavesRoomForLabel() {
        let metrics = StageMetrics()
        for slot in StageLayout.place(specs, in: stage, metrics: metrics) {
            XCTAssertEqual(slot.frame.height - slot.pile.height, metrics.labelHeight, accuracy: 0.01)
        }
    }

    func testFewAppsDoNotStretchVertically() {
        let placed = StageLayout.place([.init(id: "a", size: .small)], in: stage)
        XCTAssertLessThan(placed[0].pile.height, placed[0].pile.width)
    }
}

final class PileLayoutTests: XCTestCase {
    private let rect = CGRect(x: 100, y: 50, width: 460, height: 300)

    func testSingleWindowKeepsAspect() {
        let frames = PileLayout.frames(in: rect, aspects: [1.6])
        XCTAssertEqual(frames[0].width / frames[0].height, 1.6, accuracy: 0.01)
        XCTAssertEqual(frames[0].midX, rect.midX, accuracy: 0.5)
    }

    func testAllFramesStayInside() {
        for count in 1...PileLayout.maxVisible {
            let aspects = (0..<count).map { CGFloat(0.5 + Double($0) * 0.3) }
            for frame in PileLayout.frames(in: rect, aspects: aspects) {
                XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(count): \(frame)")
            }
        }
    }

    func testAspectsArePreservedAcrossCounts() {
        let aspects: [CGFloat] = [1.6, 0.5, 2.0, 1.2]
        let frames = PileLayout.frames(in: rect, aspects: aspects)
        for (frame, aspect) in zip(frames, aspects) {
            XCTAssertEqual(frame.width / frame.height, aspect, accuracy: 0.01)
        }
    }

    func testPileSitsOnBottomOfRect() {
        let frames = PileLayout.frames(in: rect, aspects: [2.5])
        XCTAssertEqual(frames[0].maxY, rect.maxY, accuracy: 0.5)
    }

    func testBadAspectDoesNotCrash() {
        XCTAssertEqual(PileLayout.frames(in: rect, aspects: [0]).count, 1)
        XCTAssertTrue(PileLayout.frames(in: rect, aspects: []).isEmpty)
    }

    func testMoreWindowsMeansSmallerButUsable() {
        let one = PileLayout.frames(in: rect, aspects: [1.6])[0]
        let six = PileLayout.frames(in: rect, aspects: Array(repeating: 1.6, count: 6))[0]
        XCTAssertLessThan(six.width, one.width)
        XCTAssertGreaterThan(six.width, rect.width / 4)
    }
}

final class FlowingLayoutTests: XCTestCase {
    private func slots(_ count: Int) -> [SlotSpec] {
        (0..<count).map { SlotSpec(id: "app\($0)", size: .small) }
    }

    func testStartsAtTopAndKeepsOrder() {
        let placed = StageLayout.placeFlowing(slots(5), x: 40, width: 1600, top: 1000, viewportHeight: 800)
        XCTAssertEqual(placed.map(\.id), slots(5).map(\.id))
        XCTAssertEqual(placed.first?.frame.minY, 1000)
        XCTAssertTrue(placed.allSatisfy { $0.pile.minY == $0.frame.minY })
    }

    func testManyAppsMakeSectionLongerNotCellsTiny() {
        let few = StageLayout.placeFlowing(slots(12), x: 0, width: 1600, top: 0, viewportHeight: 800)
        let many = StageLayout.placeFlowing(slots(48), x: 0, width: 1600, top: 0, viewportHeight: 800)
        XCTAssertEqual(many.count, 48)
        XCTAssertGreaterThan(many.map(\.frame.maxY).max()!, 800)
        XCTAssertGreaterThan(many[0].frame.width, few[0].frame.width * 0.6)
    }

    func testEmptyInput() {
        XCTAssertTrue(StageLayout.placeFlowing([], x: 0, width: 1600, top: 0, viewportHeight: 800).isEmpty)
    }
}

final class SlotDropTests: XCTestCase {
    /// İki satır: a b c / d e
    private let slots: [PlacedSlot] = {
        func slot(_ id: String, _ x: CGFloat, _ y: CGFloat) -> PlacedSlot {
            let frame = CGRect(x: x, y: y, width: 100, height: 100)
            return PlacedSlot(id: id, size: .small, frame: frame, pile: frame)
        }
        return [slot("a", 0, 0), slot("b", 120, 0), slot("c", 240, 0), slot("d", 0, 120), slot("e", 120, 120)]
    }()

    func testDropBetweenTwoCells() {
        XCTAssertEqual(StageLayout.drop(at: CGPoint(x: 200, y: 50), moving: "e", in: slots)?.gap, 2)
    }

    func testOwnSidesAreNotADrop() {
        XCTAssertNil(StageLayout.drop(at: CGPoint(x: 110, y: 50), moving: "b", in: slots))
        XCTAssertNil(StageLayout.drop(at: CGPoint(x: 200, y: 50), moving: "b", in: slots))
    }

    func testRowEndMarksAfterLastCell() {
        let drop = StageLayout.drop(at: CGPoint(x: 400, y: 50), moving: "a", in: slots)
        XCTAssertEqual(drop?.gap, 3)
        XCTAssertEqual(drop?.markX, 350)
    }

    func testNearestRowWinsOutsideCells() {
        XCTAssertEqual(StageLayout.drop(at: CGPoint(x: 10, y: 300), moving: "a", in: slots)?.gap, 3)
    }

    func testUnknownAppIsNotADrop() {
        XCTAssertNil(StageLayout.drop(at: .zero, moving: "z", in: slots))
    }

    func testGapMatchesArrangementMove() {
        var forward = Arrangement(pinned: ["a", "b", "c", "d", "e"])
        forward.move("a", toGap: 3)
        XCTAssertEqual(forward.pinned, ["b", "c", "a", "d", "e"])

        var backward = Arrangement(pinned: ["a", "b", "c", "d", "e"])
        backward.move("e", toGap: 2)
        XCTAssertEqual(backward.pinned, ["a", "b", "e", "c", "d"])

        var last = Arrangement(pinned: ["a", "b", "c"])
        last.move("a", toGap: 3)
        XCTAssertEqual(last.pinned, ["b", "c", "a"])
    }
}

final class ArrangementTests: XCTestCase {
    func testInitialSizeFromWindowCount() {
        XCTAssertEqual(SlotSize.initial(windowCount: 0), .small)
        XCTAssertEqual(SlotSize.initial(windowCount: 1), .small)
        XCTAssertEqual(SlotSize.initial(windowCount: 3), .medium)
        XCTAssertEqual(SlotSize.initial(windowCount: 4), .large)
    }

    func testMoveIsClamped() {
        var a = Arrangement(pinned: ["x", "y", "z"])
        a.move("z", by: -1)
        XCTAssertEqual(a.pinned, ["x", "z", "y"])
        a.move("x", by: -5)
        XCTAssertEqual(a.pinned, ["x", "z", "y"])
    }

    func testPinKeepsExistingSizeAfterUnpin() {
        var a = Arrangement()
        a.pin("x", windowCount: 5)
        a.unpin("x")
        a.pin("x", windowCount: 1)
        XCTAssertEqual(a.size(of: "x"), .large)
        XCTAssertEqual(a.pinned, ["x"])
    }

    func testRoundTrip() throws {
        let a = Arrangement(pinned: ["x"], sizes: ["x": .medium])
        XCTAssertEqual(try JSONDecoder().decode(Arrangement.self, from: JSONEncoder().encode(a)), a)
    }
}

final class SpaceNamingTests: XCTestCase {
    override func setUp() { L10n.english = false }
    override func tearDown() { L10n.english = L10n.resolve(.automatic) }

    func testEnglishLabels() {
        L10n.english = true
        let labels = SpaceNaming.labels([.init(isFullScreen: false, name: ""), .init(isFullScreen: true, name: ""), .init(isFullScreen: false, name: "")])
        XCTAssertEqual(labels, ["Desktop 1", "Full screen", "Desktop 2"])
    }

    func testSingleDesktopHasNoNumber() {
        // Bu makinede ölçülen yapı: tam ekran, masaüstü, tam ekran.
        let labels = SpaceNaming.labels([
            .init(isFullScreen: true, name: "Redis Eğitimi"),
            .init(isFullScreen: false, name: ""),
            .init(isFullScreen: true, name: "Home PC")
        ])
        XCTAssertEqual(labels, ["Redis Eğitimi", "Masaüstü", "Home PC"])
    }

    func testMultipleDesktopsAreNumbered() {
        let labels = SpaceNaming.labels([
            .init(isFullScreen: false, name: ""),
            .init(isFullScreen: true, name: ""),
            .init(isFullScreen: false, name: "")
        ])
        XCTAssertEqual(labels, ["Masaüstü 1", "Tam ekran", "Masaüstü 2"])
    }
}

final class WindowFilterTests: XCTestCase {
    private let big = CGSize(width: 1000, height: 700)

    private func keep(_ title: String, onScreen: Bool, space: Bool, size: CGSize? = nil, titles: Bool = true) -> Bool {
        WindowFilter.isUserWindow(title: title, isOnScreen: onScreen, hasSpace: space, size: size ?? big, canReadTitles: titles)
    }

    // Vakalar bu makinedeki ölçümden alındı.
    func testRealCases() {
        XCTAssertTrue(keep("Citywave", onScreen: true, space: true), "Chrome'un gerçek penceresi")
        XCTAssertFalse(keep("", onScreen: false, space: true), "Chrome'un çerçeve penceresi")
        XCTAssertFalse(keep("", onScreen: false, space: false), "hayalet 500x500 pencere")
        XCTAssertTrue(keep("", onScreen: true, space: true), "Tailscale'in başlıksız ana penceresi")
        XCTAssertTrue(keep("Home PC", onScreen: false, space: true), "başka masaüstündeki tam ekran")
        XCTAssertTrue(keep("Rapor", onScreen: false, space: false), "küçültülmüş pencere")
    }

    func testChromeFullScreenToolbarStripsAreNotWindows() {
        XCTAssertFalse(keep("", onScreen: true, space: true, size: CGSize(width: 1710, height: 149)))
        XCTAssertFalse(keep("", onScreen: true, space: true, size: CGSize(width: 1710, height: 81)))
        XCTAssertTrue(keep("", onScreen: true, space: true, size: CGSize(width: 890, height: 566)))
    }

    func testTooSmall() {
        XCTAssertFalse(keep("x", onScreen: true, space: true, size: CGSize(width: 50, height: 500)))
    }

    func testWithoutTitlePermission() {
        XCTAssertTrue(keep("", onScreen: false, space: true, titles: false))
        XCTAssertFalse(keep("", onScreen: false, space: false, titles: false))
        XCTAssertFalse(keep("", onScreen: true, space: true, size: CGSize(width: 1000, height: 89), titles: false))
    }

    func testParkedWindow() {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        XCTAssertTrue(WindowFilter.isParked(CGRect(x: 135, y: -129, width: 1181, height: 139), screens: [screen]))
        XCTAssertFalse(WindowFilter.isParked(CGRect(x: 0, y: 34, width: 1643, height: 1073), screens: [screen]))
        XCTAssertTrue(WindowFilter.isParked(CGRect(x: 5000, y: 100, width: 500, height: 500), screens: [screen]))
    }
}

final class SnapPositionTests: XCTestCase {
    // Dock sağda: çalışma alanı ekrandan dar ve menü çubuğunun altında.
    private let area = CGRect(x: 0, y: 34, width: 1643, height: 1073)

    func testHalvesMeetExactlyAndCoverArea() {
        let left = SnapPosition.leftHalf.frame(in: area)
        let right = SnapPosition.rightHalf.frame(in: area)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.minX, area.minX)
        XCTAssertEqual(right.maxX, area.maxX)
        XCTAssertEqual(left.minY, area.minY)
        XCTAssertEqual(right.height, area.height)
    }

    func testFillIsWorkArea() {
        XCTAssertEqual(SnapPosition.fill.frame(in: area), area)
    }

    func testSecondDisplayOrigin() {
        let second = CGRect(x: 1710, y: -200, width: 1000, height: 800)
        XCTAssertEqual(SnapPosition.rightHalf.frame(in: second).maxX, second.maxX)
        XCTAssertEqual(SnapPosition.leftHalf.frame(in: second).minX, second.minX)
    }

    func testEmptyArea() {
        XCTAssertEqual(SnapPosition.fill.frame(in: .zero), .zero)
    }
}

final class SpaceOrderTests: XCTestCase {
    // Bu makinede ölçülen sıra: tam ekran, masaüstü, tam ekran, yeni tam ekran.
    private let order: [UInt64] = [210, 3, 198, 500]

    func testGapIndex() {
        let mids: [CGFloat] = [100, 200, 300]
        XCTAssertEqual(SpaceOrder.gapIndex(forX: 50, midXs: mids), 0)
        XCTAssertEqual(SpaceOrder.gapIndex(forX: 150, midXs: mids), 1)
        XCTAssertEqual(SpaceOrder.gapIndex(forX: 350, midXs: mids), 3)
    }

    func testIsPlaced() {
        XCTAssertTrue(SpaceOrder.isPlaced(order: order, moving: 500, before: nil))
        XCTAssertFalse(SpaceOrder.isPlaced(order: order, moving: 500, before: 198))
        XCTAssertTrue(SpaceOrder.isPlaced(order: [210, 3, 500, 198], moving: 500, before: 198))
        XCTAssertFalse(SpaceOrder.isPlaced(order: order, moving: 999, before: nil))
    }

    func testDestinationGap() {
        XCTAssertEqual(SpaceOrder.destinationGap(order: order, moving: 500, before: 198), 2)
        XCTAssertEqual(SpaceOrder.destinationGap(order: order, moving: 500, before: 210), 0)
        XCTAssertEqual(SpaceOrder.destinationGap(order: order, moving: 210, before: nil), 4)
    }

    func testDroppingAtFarRightNeedsNoMissionControl() {
        // Yeni tam ekran zaten en sağa gelir.
        XCTAssertNil(SpaceOrder.destinationGap(order: order, moving: 500, before: nil))
    }

    func testDroppingNextToItselfIsNoOp() {
        XCTAssertNil(SpaceOrder.destinationGap(order: order, moving: 198, before: 500))
    }

    func testPlanForInteriorIsSingleMove() {
        XCTAssertEqual(SpaceOrder.plan(order: order, moving: 500, before: 198), [.init(space: 500, before: 198)])
    }

    func testPlanForAlreadyPlacedIsEmpty() {
        XCTAssertTrue(SpaceOrder.plan(order: order, moving: 500, before: nil).isEmpty)
    }

    func testPlanNeverDropsLeftOfFirst() {
        let moves = SpaceOrder.plan(order: order, moving: 500, before: 210)
        XCTAssertEqual(SpaceOrder.applying(moves, to: order), [500, 210, 3, 198])
        for (index, move) in moves.enumerated() {
            let current = SpaceOrder.applying(Array(moves[..<index]), to: order)
            XCTAssertNotEqual(move.before, current.first, "ilk alanın soluna bırakılmamalı")
        }
    }

    func testPlanWhenMovingIsAlreadySecond() {
        XCTAssertEqual(SpaceOrder.plan(order: [210, 3, 198], moving: 3, before: 210), [.init(space: 210, before: 198)])
        XCTAssertEqual(SpaceOrder.plan(order: [210, 3], moving: 3, before: 210), [.init(space: 210, before: nil)])
    }

    func testPlanKeepsOtherSpacesRelativeOrder() {
        let moves = SpaceOrder.plan(order: order, moving: 500, before: 210)
        let others = SpaceOrder.applying(moves, to: order).filter { $0 != 500 }
        XCTAssertEqual(others, [210, 3, 198])
    }

    func testDropX() {
        let frames = [CGRect(x: 100, y: 0, width: 50, height: 30), CGRect(x: 170, y: 0, width: 50, height: 30)]
        XCTAssertEqual(SpaceOrder.dropX(gap: 0, frames: frames), 86)
        XCTAssertEqual(SpaceOrder.dropX(gap: 1, frames: frames), 160)
        XCTAssertEqual(SpaceOrder.dropX(gap: 2, frames: frames), 234)
        XCTAssertNil(SpaceOrder.dropX(gap: 3, frames: frames))
        XCTAssertNil(SpaceOrder.dropX(gap: 0, frames: []))
    }
}

final class SearchMatcherTests: XCTestCase {
    func testTurkishFolding() {
        XCTAssertTrue(SearchMatcher.matches(query: "masaustu", in: ["Masaüstü"]))
        XCTAssertTrue(SearchMatcher.matches(query: "ISIK", in: ["ışık"]))
        XCTAssertFalse(SearchMatcher.matches(query: "chrome", in: ["Finder"]))
        XCTAssertTrue(SearchMatcher.matches(query: "  ", in: ["Finder"]))
    }

    func testRankPrefersStartOfNameThenWord() {
        XCTAssertEqual(SearchMatcher.rank(query: "hes", name: "Hesap Makinesi"), 0)
        XCTAssertEqual(SearchMatcher.rank(query: "mak", name: "Hesap Makinesi"), 1)
        XCTAssertEqual(SearchMatcher.rank(query: "kine", name: "Hesap Makinesi"), 2)
        XCTAssertEqual(SearchMatcher.rank(query: "studio", name: "Visual Studio Code"), 1)
        XCTAssertNil(SearchMatcher.rank(query: "xcode", name: "Finder"))
        XCTAssertNil(SearchMatcher.rank(query: " ", name: "Finder"))
        XCTAssertEqual(SearchMatcher.rank(query: "onizl", name: "Önizleme"), 0)
    }
}

final class ShortcutFormatTests: XCTestCase {
    func testOrderFollowsAppleMenus() {
        XCTAssertEqual(ShortcutFormat.display(control: true, option: true, shift: true, command: true, key: "K"), "⌃⌥⇧⌘K")
        XCTAssertEqual(ShortcutFormat.display(control: false, option: true, shift: true, command: false, key: "Space"), "⌥⇧Space")
    }

    func testPlainOrShiftOnlyIsRejected() {
        XCTAssertFalse(ShortcutFormat.isAcceptable(control: false, option: false, shift: false, command: false))
        XCTAssertFalse(ShortcutFormat.isAcceptable(control: false, option: false, shift: true, command: false))
        XCTAssertTrue(ShortcutFormat.isAcceptable(control: false, option: true, shift: false, command: false))
    }
}

final class DockEdgeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)

    func testOrientationFallsBackToBottom() {
        XCTAssertEqual(DockEdge(orientation: "right"), .right)
        XCTAssertEqual(DockEdge(orientation: nil), .bottom)
        XCTAssertEqual(DockEdge(orientation: "x"), .bottom)
    }

    func testRightEdgeTouch() {
        XCTAssertTrue(DockEdge.right.isTouched(by: CGPoint(x: 1709, y: 500), screen: screen))
        XCTAssertFalse(DockEdge.right.isTouched(by: CGPoint(x: 1600, y: 500), screen: screen))
    }

    func testCornersDoNotTrigger() {
        XCTAssertFalse(DockEdge.right.isTouched(by: CGPoint(x: 1709, y: 10), screen: screen))
        XCTAssertFalse(DockEdge.bottom.isTouched(by: CGPoint(x: 1700, y: 0), screen: screen))
    }

    func testOtherEdgesDoNotTrigger() {
        XCTAssertFalse(DockEdge.left.isTouched(by: CGPoint(x: 1709, y: 500), screen: screen))
        XCTAssertTrue(DockEdge.bottom.isTouched(by: CGPoint(x: 800, y: 0), screen: screen))
    }

    func testStripStaysOnScreen() {
        for edge in [DockEdge.left, .right, .bottom] {
            let frame = edge.stripFrame(length: 5000, thickness: 60, screen: screen)
            XCTAssertTrue(screen.contains(frame), "\(edge): \(frame)")
        }
    }

    func testHiddenFrameIsOffScreen() {
        for edge in [DockEdge.left, .right, .bottom] {
            let frame = edge.stripFrame(length: 600, thickness: 60, screen: screen)
            XCTAssertFalse(edge.hiddenFrame(from: frame, screen: screen).intersects(screen), "\(edge)")
        }
    }
}

final class WindowNamingTests: XCTestCase {
    override func setUp() { L10n.english = false }
    override func tearDown() { L10n.english = L10n.resolve(.automatic) }

    func testEnglishDisplay() {
        L10n.english = true
        XCTAssertEqual(WindowNaming.display(title: "", appName: "Chrome", index: 1, windowCount: 3), "Chrome · Window 2")
    }

    func testDisplay() {
        XCTAssertEqual(WindowNaming.display(title: "Rapor", appName: "Chrome", index: 1, windowCount: 3), "Rapor")
        XCTAssertEqual(WindowNaming.display(title: "", appName: "Chrome", index: 1, windowCount: 3), "Chrome · Pencere 2")
        XCTAssertEqual(WindowNaming.display(title: "", appName: "Notlar", index: 0, windowCount: 1), "Notlar")
    }

    func testUniqueMatch() {
        let a = CGRect(x: 0, y: 34, width: 800, height: 600)
        let b = CGRect(x: 100, y: 100, width: 500, height: 400)
        let list: [(element: String, frame: CGRect)] = [("A", a), ("B", b)]
        XCTAssertEqual(WindowNaming.uniqueMatch(frame: a.offsetBy(dx: 3, dy: -2), candidates: list), "A")
        XCTAssertNil(WindowNaming.uniqueMatch(frame: CGRect(x: 900, y: 0, width: 10, height: 10), candidates: list))
    }

    func testAmbiguousFrameGivesNoTitle() {
        let frame = CGRect(x: 0, y: 34, width: 1710, height: 1073)
        XCTAssertNil(WindowNaming.uniqueMatch(frame: frame, candidates: [("A", frame), ("B", frame)]))
    }
}

final class SwipeGestureTests: XCTestCase {
    private func run(_ steps: [(Int64, Double, Double)], axis: Int64 = 2,
                     capture: (SwipeDirection) -> Bool = { $0 == .up }) -> (decisions: [SwipeGestureInterpreter.Decision], fired: [SwipeDirection]) {
        var interpreter = SwipeGestureInterpreter()
        var decisions: [SwipeGestureInterpreter.Decision] = []
        var fired: [SwipeDirection] = []
        for (phase, progress, velocity) in steps {
            let (decision, direction) = interpreter.handle(axis: axis, phase: phase, progress: progress, velocity: velocity, capture: capture)
            decisions.append(decision)
            if let direction { fired.append(direction) }
        }
        return (decisions, fired)
    }

    // Ölçülen hareketler.
    private let up: [(Int64, Double, Double)] = [(1, 0.016, 0), (2, 0.035, 0), (2, 0.2, 0), (2, 0.49, 0), (4, 0.64, 6.13)]
    private let down: [(Int64, Double, Double)] = [(1, -0.016, 0), (2, -0.2, 0), (2, -0.5, 0), (4, -0.598, -9.13)]

    func testCapturedSwipeFiresOnceAndIsSwallowed() {
        let result = run(up)
        XCTAssertEqual(result.fired, [.up])
        XCTAssertTrue(result.decisions.allSatisfy { $0 == .swallow })
        XCTAssertEqual(run(down, capture: { _ in true }).fired, [.down])
    }

    func testUncapturedSwipeIsLeftToMacOS() {
        let result = run(down)
        XCTAssertTrue(result.fired.isEmpty)
        XCTAssertTrue(result.decisions.allSatisfy { $0 == .pass })
    }

    func testCaptureIsAskedWithFirstDirection() {
        var asked: [SwipeDirection] = []
        _ = run(down, capture: { asked.append($0); return false })
        _ = run(up, capture: { asked.append($0); return false })
        XCTAssertEqual(asked, [.down, .up])
    }

    func testTinyTouchDoesNotFire() {
        XCTAssertTrue(run([(1, 0.01, 0), (2, 0.03, 0), (4, 0.05, 0.1)]).fired.isEmpty)
    }

    func testFlickFires() {
        XCTAssertEqual(run([(1, 0.01, 0), (2, 0.05, 0), (4, 0.08, 4)]).fired, [.up])
    }

    func testHorizontalSwipesAreUntouched() {
        let result = run(up, axis: 1, capture: { _ in true })
        XCTAssertTrue(result.fired.isEmpty)
        XCTAssertTrue(result.decisions.allSatisfy { $0 == .pass })
    }

    func testEventsWithoutBeginPass() {
        XCTAssertEqual(run([(2, 0.5, 0)]).decisions, [.pass])
    }

    func testCancelledGestureDoesNotFireLater() {
        let result = run([(1, 0.01, 0), (8, 0.05, 0), (2, 0.5, 0)])
        XCTAssertTrue(result.fired.isEmpty)
        XCTAssertEqual(result.decisions.last, .pass)
    }

    func testGesturesAreIndependent() {
        XCTAssertEqual(run(up + up).fired, [.up, .up])
    }
}

final class TrackpadGestureMapTests: XCTestCase {
    // Burak'ın Mac'i: 3 ve 4 parmak dikey açık, Mission Control ve App Exposé açık, sahne 3 parmak.
    private let system = SystemGestures(vertical: [3: true, 4: true], missionControl: true, appExpose: true)

    func testMigrationKeepsMacOSAndPutsSceneOnChosenFingers() {
        let map = TrackpadGestureMap.migrated(sceneFingers: 3, system: system)
        XCTAssertEqual(map[3, .up], .scene)
        XCTAssertEqual(map[3, .down], .appExpose)
        XCTAssertEqual(map[4, .up], .missionControl)
        XCTAssertEqual(map[4, .down], .appExpose)
        let off = TrackpadGestureMap.migrated(sceneFingers: 0, system: SystemGestures(vertical: [3: true], missionControl: true, appExpose: false))
        XCTAssertEqual(off[3, .up], .missionControl)
        XCTAssertEqual(off[3, .down], .nothing)
        XCTAssertEqual(off[4, .up], .nothing)
    }

    func testNativeActionsPassAndOthersAreCaptured() {
        let map = TrackpadGestureMap.migrated(sceneFingers: 3, system: system)
        func captures(_ fingers: Int, _ direction: SwipeDirection, open: Bool = false, remote: Bool = false) -> Bool {
            GestureRouting.captures(fingers: fingers, direction: direction, map: map, system: system, overlayOpen: open, remoteDown: remote)
        }
        XCTAssertTrue(captures(3, .up))
        XCTAssertFalse(captures(3, .down))
        XCTAssertFalse(captures(4, .up))
        XCTAssertTrue(captures(3, .down, remote: true), "App Exposé Windows oturumuna gider")
        XCTAssertTrue(captures(4, .up, open: true), "sahne açıkken her hareket Berth'ün")
        var quiet = map
        quiet[4, .down] = .nothing
        XCTAssertTrue(GestureRouting.captures(fingers: 4, direction: .down, map: quiet, system: system, overlayOpen: false, remoteDown: false),
                      "macOS'un yapacağı iş istenmiyorsa hareket yutulur")
    }

    func testMacOSDoingSomethingElseIsOverridden() {
        let missionControlOff = SystemGestures(vertical: [3: true, 4: true], missionControl: false, appExpose: true)
        var map = TrackpadGestureMap()
        map[4, .up] = .missionControl
        XCTAssertTrue(GestureRouting.captures(fingers: 4, direction: .up, map: map, system: missionControlOff, overlayOpen: false, remoteDown: false))
        XCTAssertEqual(GestureRouting.outcome(fingers: 4, direction: .up, map: map, overlayOpen: false), .perform(.missionControl))
    }

    func testOutcomeWhenOpen() {
        let map = TrackpadGestureMap.migrated(sceneFingers: 3, system: system)
        XCTAssertEqual(GestureRouting.outcome(fingers: 4, direction: .down, map: map, overlayOpen: true), .close)
        XCTAssertEqual(GestureRouting.outcome(fingers: 3, direction: .up, map: map, overlayOpen: true), .none)
        XCTAssertEqual(GestureRouting.outcome(fingers: 3, direction: .up, map: map, overlayOpen: false), .perform(.scene))
        XCTAssertEqual(GestureRouting.fingers(0), 3)
    }

    func testSystemEquivalent() {
        var map = TrackpadGestureMap()
        map[3, .up] = .scene
        map[3, .down] = .appExpose
        map[4, .up] = .missionControl
        XCTAssertEqual(map.systemEquivalent, SystemGestures(vertical: [3: true, 4: true], missionControl: true, appExpose: true))
        var none = TrackpadGestureMap()
        none[4, .down] = .appExpose
        XCTAssertEqual(none.systemEquivalent, SystemGestures(vertical: [3: false, 4: true], missionControl: false, appExpose: true))
    }

    func testRoundTripsThroughDictionary() {
        let map = TrackpadGestureMap.migrated(sceneFingers: 4, system: system)
        XCTAssertEqual(TrackpadGestureMap(dictionary: map.dictionary), map)
        XCTAssertEqual(TrackpadGestureMap(dictionary: ["3-up": "bogus"]), TrackpadGestureMap())
    }
}

final class OpenTriggerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testCorners() {
        XCTAssertEqual(ScreenCorner.corner(of: CGPoint(x: 0, y: 981), in: screen), .topLeft)
        XCTAssertEqual(ScreenCorner.corner(of: CGPoint(x: 1511, y: 981), in: screen), .topRight)
        XCTAssertEqual(ScreenCorner.corner(of: CGPoint(x: 1, y: 0), in: screen), .bottomLeft)
        XCTAssertEqual(ScreenCorner.corner(of: CGPoint(x: 1511, y: 2), in: screen), .bottomRight)
        XCTAssertEqual(ScreenCorner.corner(of: CGPoint(x: 0, y: 500), in: screen), .none)
        XCTAssertEqual(ScreenCorner.corner(of: CGPoint(x: 700, y: 981), in: screen), .none)
        // İkinci ekran: köşeler kendi çerçevesine göre.
        let second = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(ScreenCorner.corner(of: CGPoint(x: 3431, y: -200), in: second), .bottomRight)
    }

    private func swipe(count: Int, dy: CGFloat, dx: CGFloat = 0) -> [MultiFingerSwipe.Swipe] {
        var recognizer = MultiFingerSwipe()
        var result: [MultiFingerSwipe.Swipe] = []
        for step in 0...10 {
            let t = CGFloat(step) / 10
            let points = (0..<count).map { CGPoint(x: 0.4 + CGFloat($0) * 0.08 + dx * t, y: 0.3 + dy * t) }
            if let swipe = recognizer.handle(points) { result.append(swipe) }
        }
        _ = recognizer.handle([])
        return result
    }

    func testRecognizesThreeAndFourFingersBothWays() {
        XCTAssertEqual(swipe(count: 3, dy: 0.3), [.init(fingers: 3, direction: .up)])
        XCTAssertEqual(swipe(count: 4, dy: -0.3), [.init(fingers: 4, direction: .down)])
    }

    func testIgnoresOtherCountsShortAndHorizontal() {
        XCTAssertEqual(swipe(count: 2, dy: 0.3), [])
        XCTAssertEqual(swipe(count: 5, dy: 0.3), [])
        XCTAssertEqual(swipe(count: 3, dy: 0.08), [])
        XCTAssertEqual(swipe(count: 3, dy: 0.2, dx: 0.4), [])
    }

    func testAddedFingerChangesTheCount() {
        var recognizer = MultiFingerSwipe()
        let three = { (y: CGFloat) in (0..<3).map { CGPoint(x: 0.4 + CGFloat($0) * 0.1, y: y) } }
        _ = recognizer.handle(three(0.3))
        _ = recognizer.handle(three(0.3) + [CGPoint(x: 0.9, y: 0.3)])
        XCTAssertNil(recognizer.handle(three(0.6)), "dört parmaklık oturumda üç parmak tetiklemez")
        XCTAssertEqual(recognizer.sessionFingers, 4)
        _ = recognizer.handle([])
        _ = recognizer.handle(three(0.3))
        XCTAssertEqual(recognizer.handle(three(0.6)), .init(fingers: 3, direction: .up))
    }
}

final class WorkspaceLayoutTests: XCTestCase {
    private func saved(_ app: String, _ title: String) -> WorkspaceLayout.Window {
        .init(appID: app, title: title, frame: .zero, minimized: false)
    }

    func testExactTitleWinsThenOrder() {
        let s = [saved("chrome", "Gmail"), saved("chrome", "GitHub"), saved("notes", "A")]
        let c: [LayoutMatcher.Candidate] = [.init(appID: "chrome", title: "Yeni sekme"), .init(appID: "chrome", title: "Gmail"), .init(appID: "notes", title: "B")]
        let pairs = LayoutMatcher.match(saved: s, current: c)
        XCTAssertEqual(pairs.map(\.saved), [0, 1, 2])
        XCTAssertEqual(pairs.map(\.current), [1, 0, 2])
    }

    func testMissingAppIsSkippedAndWindowsUsedOnce() {
        let s = [saved("mail", "x"), saved("chrome", "a"), saved("chrome", "b")]
        let c: [LayoutMatcher.Candidate] = [.init(appID: "chrome", title: "a")]
        let pairs = LayoutMatcher.match(saved: s, current: c)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.saved, 1)
    }

    func testSameWindowBeatsSameTitle() {
        var a = saved("charmap", "Character Map"); a.windowID = 20
        var b = saved("charmap", "Character Map"); b.windowID = 10
        let c: [LayoutMatcher.Candidate] = [.init(appID: "charmap", title: "Character Map", windowID: 10),
                                            .init(appID: "charmap", title: "Character Map", windowID: 20)]
        let pairs = LayoutMatcher.match(saved: [a, b], current: c)
        XCTAssertEqual(pairs.map(\.current), [1, 0])
    }

    func testNextName() {
        L10n.english = false
        defer { L10n.english = L10n.resolve(.automatic) }
        XCTAssertEqual(LayoutMatcher.nextName(existing: []), "Düzen 1")
        XCTAssertEqual(LayoutMatcher.nextName(existing: ["Düzen 1", "Düzen 3"]), "Düzen 2")
        L10n.english = true
        XCTAssertEqual(LayoutMatcher.nextName(existing: ["Layout 1"]), "Layout 2")
    }

    func testCodableRoundTrip() throws {
        let layout = WorkspaceLayout(name: "İş", savedAt: Date(timeIntervalSince1970: 0), windows: [
            .init(appID: "com.apple.Safari", title: "Başlık", frame: CGRect(x: 1, y: 2, width: 300, height: 400), minimized: true),
        ])
        let data = try JSONEncoder().encode([layout])
        XCTAssertEqual(try JSONDecoder().decode([WorkspaceLayout].self, from: data), [layout])
    }
}

final class RemoteSessionMatcherTests: XCTestCase {
    func testMatchesComputerNameInsideSessionTitle() {
        XCTAssertEqual(RemoteSessionMatcher.match(title: "Office PC Tailscale", computers: ["OFFICEPC"]), "OFFICEPC")
        XCTAssertEqual(RemoteSessionMatcher.match(title: "office-pc", computers: ["OFIS", "OFFICEPC"]), "OFFICEPC")
    }

    func testOtherSessionsDoNotMatch() {
        XCTAssertNil(RemoteSessionMatcher.match(title: "Home PC", computers: ["OFFICEPC"]))
        XCTAssertNil(RemoteSessionMatcher.match(title: "Home PC", computers: []))
        XCTAssertNil(RemoteSessionMatcher.match(title: "Home PC", computers: [""]))
    }

    func testSessionAliasMatchesWhenTitleLacksComputerName() {
        let computers = ["DESKTOP-7Q2", "BURAKMAIN"]
        let aliases = ["desktop-7q2": "Work PC"]
        XCTAssertEqual(RemoteSessionMatcher.match(title: "Work PC", computers: computers, aliases: aliases), "DESKTOP-7Q2")
        XCTAssertEqual(RemoteSessionMatcher.match(title: "burakmain", computers: computers, aliases: aliases), "BURAKMAIN")
        XCTAssertNil(RemoteSessionMatcher.match(title: "Home PC", computers: computers, aliases: aliases))
        XCTAssertNil(RemoteSessionMatcher.match(title: "Work PC", computers: computers, aliases: ["desktop-7q2": "  "]))
    }
}

final class MouseTuneTests: XCTestCase {
    func testSpeedLowersReportedResolution() {
        XCTAssertEqual(MouseTune.resolution(forSpeed: 1), 400 * 65536)
        XCTAssertEqual(MouseTune.resolution(forSpeed: 2), 200 * 65536)
        XCTAssertEqual(MouseTune.resolution(forSpeed: 100), 100 * 65536, "hız 4'te sınırlanır")
    }

    func testPropertiesUseFixedPointAndClamp() {
        XCTAssertEqual(MouseTune.propertiesJSON(speed: 2, acceleration: 3),
                       "{\"HIDUseLinearScalingMouseAcceleration\":0,\"HIDPointerResolution\":13107200,\"HIDMouseAcceleration\":196608}")
        XCTAssertEqual(MouseTune.propertiesJSON(speed: 2, acceleration: -1),
                       "{\"HIDUseLinearScalingMouseAcceleration\":0,\"HIDPointerResolution\":13107200,\"HIDMouseAcceleration\":0}")
        XCTAssertEqual(MouseTune.systemPropertiesJSON(scaling: 0.6875),
                       "{\"HIDUseLinearScalingMouseAcceleration\":0,\"HIDPointerResolution\":26214400,\"HIDMouseAcceleration\":45056}")
    }

    func testFlatScaleUsesSpeedAsFactor() {
        XCTAssertEqual(MouseTune.flatPropertiesJSON(speed: 4),
                       "{\"HIDUseLinearScalingMouseAcceleration\":1,\"HIDMouseAcceleration\":262144}")
        XCTAssertEqual(MouseTune.flatPropertiesJSON(speed: 100),
                       "{\"HIDUseLinearScalingMouseAcceleration\":1,\"HIDMouseAcceleration\":262144}", "hız 4'te sınırlanır")
    }

    func testMatchingEscapesName() {
        XCTAssertEqual(MouseTune.matchingJSON(mouseName: "HP \"Z\" \\ Mouse"),
                       "{\"Product\":\"HP \\\"Z\\\" \\\\ Mouse\",\"PrimaryUsagePage\":1,\"PrimaryUsage\":2}")
    }
}

final class PointerAcceleratorTests: XCTestCase {
    func testStartsAtSpeedAndGrowsWithVelocity() {
        let accelerator = PointerAccelerator(speed: 2, acceleration: 3)
        XCTAssertEqual(accelerator.factor, 2)
        XCTAssertEqual(accelerator.factor(forVelocity: 0), 2)
        XCTAssertEqual(accelerator.factor(forVelocity: 1500), 5)
        XCTAssertEqual(accelerator.factor(forVelocity: 100_000), 6.5, "tavan")
        XCTAssertEqual(PointerAccelerator(speed: 2, acceleration: 0).factor(forVelocity: 3000), 2, "ivme 0 düz")
    }

    func testFastMovementRaisesFactorAndRestReturnsToSpeed() {
        var accelerator = PointerAccelerator(speed: 2, acceleration: 3)
        XCTAssertNil(accelerator.move(distance: 1, interval: 0.008), "yavaş harekette değişmez")
        var last: Double?
        for _ in 0..<20 { last = accelerator.move(distance: 60, interval: 0.008) ?? last }
        XCTAssertGreaterThan(last ?? 0, 4)
        XCTAssertEqual(accelerator.rest(), 2)
        XCTAssertNil(accelerator.rest())
    }
}

final class ScrollWheelTests: XCTestCase {
    func testEveryNotchBecomesFixedLinesKeepingDirection() {
        XCTAssertEqual(ScrollWheel.flattened(lines: 1, fixed: 0.3, to: 3), .init(lines: 3, fixed: 3, points: 30))
        XCTAssertEqual(ScrollWheel.flattened(lines: -7, fixed: -7.2, to: 3), .init(lines: -3, fixed: -3, points: -30))
        XCTAssertEqual(ScrollWheel.flattened(lines: 0, fixed: -0.1, to: 2), .init(lines: -2, fixed: -2, points: -20),
                       "satır 0 ama yön var")
        XCTAssertNil(ScrollWheel.flattened(lines: 0, fixed: 0, to: 3))
        XCTAssertEqual(ScrollWheel.flattened(lines: 1, fixed: 1, to: 50)?.lines, 10, "sınır")
    }
}

final class SmoothScrollTests: XCTestCase {
    func testNotchIsSentInFullOverDecreasingSteps() {
        var scroll = SmoothScroll()
        scroll.add(vertical: 1, horizontal: 0, lines: 3)
        var steps: [Int32] = []
        while !scroll.isIdle { steps.append(scroll.step().y) }
        XCTAssertEqual(steps.reduce(0, +), 120)
        XCTAssertGreaterThan(steps.first ?? 0, steps.last ?? 0)
        XCTAssertLessThan(steps.count, 25)
    }

    func testFastSpinsGoFurther() {
        XCTAssertEqual(SmoothScroll.boost(interval: 0.5), 1, "tek tek")
        XCTAssertEqual(SmoothScroll.boost(interval: 0.05), 2, accuracy: 0.001)
        XCTAssertEqual(SmoothScroll.boost(interval: 0.005), SmoothScroll.maxBoost, "tavan")
        var scroll = SmoothScroll()
        scroll.add(vertical: -1, horizontal: 0, lines: 3, boost: 2)
        XCTAssertEqual(scroll.remainingY, -240)
    }

    func testReversingDropsTheRest() {
        var scroll = SmoothScroll()
        scroll.add(vertical: 1, horizontal: 0, lines: 3)
        _ = scroll.step()
        scroll.add(vertical: -1, horizontal: 0, lines: 3)
        XCTAssertEqual(scroll.remainingY, -120)
    }
}

final class MouseProfileTests: XCTestCase {
    func testRoundTripsThroughDictionary() {
        let profile = MouseProfile(enabled: false, speed: 3.1, acceleration: 2.5)
        XCTAssertEqual(MouseProfile(dictionary: profile.dictionary), profile)
    }

    func testMissingOrWrongValuesFallBackAndClamp() {
        XCTAssertEqual(MouseProfile(dictionary: [:]), .suggested)
        XCTAssertEqual(MouseProfile(dictionary: ["speed": 9, "acceleration": -2]), MouseProfile(speed: 4, acceleration: 0))
    }

    func testSystemProfileMatchesMacOSValues() {
        let system = MouseProfile.system(scaling: 0.6875)
        XCTAssertEqual(MouseTune.propertiesJSON(speed: system.speed, acceleration: system.acceleration),
                       MouseTune.systemPropertiesJSON(scaling: 0.6875))
    }
}

final class EdgeSwitchTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testOuterEdgesInsideBand() {
        XCTAssertEqual(EdgeSwitch.side(at: CGPoint(x: 0, y: 491), screens: [main], band: 0.5, margin: 1), .left)
        XCTAssertEqual(EdgeSwitch.side(at: CGPoint(x: 1511, y: 491), screens: [main], band: 0.5, margin: 1), .right)
        XCTAssertNil(EdgeSwitch.side(at: CGPoint(x: 700, y: 491), screens: [main], band: 0.5, margin: 1))
    }

    func testTopAndBottomOutsideBandAreIgnored() {
        XCTAssertNil(EdgeSwitch.side(at: CGPoint(x: 0, y: 900), screens: [main], band: 0.5, margin: 1))
        XCTAssertNil(EdgeSwitch.side(at: CGPoint(x: 0, y: 50), screens: [main], band: 0.5, margin: 1))
        XCTAssertEqual(EdgeSwitch.side(at: CGPoint(x: 0, y: 900), screens: [main], band: 1, margin: 1), .left)
    }

    func testEdgeNextToAnotherScreenIsIgnored() {
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let screens = [main, external]
        XCTAssertNil(EdgeSwitch.side(at: CGPoint(x: 1511, y: 491), screens: screens, band: 0.5, margin: 1))
        XCTAssertEqual(EdgeSwitch.side(at: CGPoint(x: 0, y: 491), screens: screens, band: 0.5, margin: 1), .left)
        XCTAssertEqual(EdgeSwitch.side(at: CGPoint(x: 3431, y: 540), screens: screens, band: 0.5, margin: 1), .right)
    }
}

final class ModifierMappingTests: XCTestCase {
    func testMacPresetMatchesWhatSystemSettingsWrote() {
        // Burak'ın Mac'inde Sistem Ayarları'nın yazdığı (sayısal değerler `defaults` çıktısından).
        let written = [
            ModifierPair(30064771299, 30064771296), ModifierPair(1095216660483, 30064771303),
            ModifierPair(30064771302, 30064771302), ModifierPair(280379760050179, 30064771299),
            ModifierPair(30064771303, 30064771300), ModifierPair(30064771300, 1095216660483),
            ModifierPair(30064771298, 30064771298), ModifierPair(30064771296, 1095216660483),
        ]
        XCTAssertEqual(ModifierPreset.effective(written), ModifierPreset.macWindowsLike)
    }

    /// macOS eşlemeyi bağlanırken uyguladıysa Berth üstüne yazmaz; Windows App için tersini yazar.
    func testUserKeyMappingCompensatesSystemMapping() {
        let windows = ModifierPreset.windowsKeyboard
        XCTAssertEqual(ModifierPreset.userKeyMapping(desired: windows, active: []), windows)
        XCTAssertTrue(ModifierPreset.userKeyMapping(desired: windows, active: windows).isEmpty)
        let inverse = ModifierPreset.userKeyMapping(desired: [], active: windows)
        XCTAssertEqual(inverse, Set(windows.map { ModifierPair($0.destination, $0.source) }))
        // Her tuş: önce macOS'un çifti, sonra Berth'ün yazdığı → istenen.
        let active = Dictionary(uniqueKeysWithValues: windows.map { ($0.source, $0.destination) })
        let added = Dictionary(uniqueKeysWithValues: inverse.map { ($0.source, $0.destination) })
        for key in active.keys {
            let middle = active[key] ?? key
            XCTAssertEqual(added[middle] ?? middle, key)
        }
        XCTAssertTrue(ModifierPreset.userKeyMapping(desired: [], active: []).isEmpty)
    }

    func testKeysAndJSON() {
        XCTAssertEqual(ModifierPreset.preferenceKey(vendor: 1118, product: 2098), "com.apple.keyboard.modifiermapping.1118-2098-0")
        XCTAssertEqual(ModifierPreset.propertyJSON([]), "{\"HIDKeyboardModifierMappingPairs\":[]}")
        XCTAssertEqual(ModifierPreset.externalPropertyJSON([ModifierPair(ModifierKey.leftControl, ModifierKey.leftCommand)]),
                       "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(ModifierKey.leftControl),\"HIDKeyboardModifierMappingDst\":\(ModifierKey.leftCommand)}]}")
        XCTAssertEqual(ModifierPreset.externalPropertyJSON([]), "{\"UserKeyMapping\":[]}")
        XCTAssertEqual(ModifierPreset.propertyJSON([ModifierPair(ModifierKey.leftControl, ModifierKey.leftCommand)]),
                       "{\"HIDKeyboardModifierMappingPairs\":[{\"HIDKeyboardModifierMappingSrc\":30064771296,\"HIDKeyboardModifierMappingDst\":30064771299}]}")
        XCTAssertTrue(ModifierPreset.effective([ModifierPair(1, 1)]).isEmpty)
    }
}

final class EdgeSwitchHoldKeysTests: XCTestCase {
    func testHeldAndDisplay() {
        let hold: EdgeSwitch.HoldKeys = [.option, .command]
        XCTAssertTrue(hold.isHeld(in: [.option, .command]))
        XCTAssertTrue(hold.isHeld(in: [.option, .command, .shift]))
        XCTAssertFalse(hold.isHeld(in: [.option]))
        XCTAssertTrue(EdgeSwitch.HoldKeys().isHeld(in: []), "tuş seçilmediyse kenar yeter")
        XCTAssertEqual(EdgeSwitch.HoldKeys([.command, .control, .function]).display, "fn ⌃⌘")
    }
}

final class DockEdgeGuardTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    func testBottomEdgeIsKeptAway() {
        XCTAssertEqual(DockEdge.bottom.guarded(CGPoint(x: 500, y: 1199.5), display: display, displays: [display]), CGPoint(x: 500, y: 1198))
        XCTAssertNil(DockEdge.bottom.guarded(CGPoint(x: 500, y: 1197), display: display, displays: [display]))
    }

    func testSideEdges() {
        XCTAssertEqual(DockEdge.left.guarded(CGPoint(x: 0, y: 600), display: display, displays: [display]), CGPoint(x: 1, y: 600))
        XCTAssertEqual(DockEdge.right.guarded(CGPoint(x: 1919.8, y: 600), display: display, displays: [display]), CGPoint(x: 1918, y: 600))
        XCTAssertNil(DockEdge.right.guarded(CGPoint(x: 1000, y: 600), display: display, displays: [display]))
    }

    /// Kenarın ötesinde başka ekran varsa imleç oraya geçebilmeli.
    func testSharedEdgeIsLeftAlone() {
        let below = CGRect(x: 0, y: 1200, width: 1920, height: 1080)
        XCTAssertNil(DockEdge.bottom.guarded(CGPoint(x: 500, y: 1199.5), display: display, displays: [display, below]))
    }
}
