import AppKit
import BerthCore

/// Trackpad'de 3 ve 4 parmakla dikey kaydırmayı hareket tablosuna (`TrackpadGestureMap`) göre işler.
///
/// İki kaynak birlikte çalışır. macOS o parmak sayısında dikey kaydırmayı açmışsa hareket Dock olayı
/// olarak gelir; tablodaki iş macOS'un zaten yapacağıysa (Mission Control, App Exposé) olay macOS'a
/// bırakılır, parmağı izleyen kendi animasyonu kalır. Değilse olay Dock'tan önce yutulur ve iş Berth'te
/// yapılır. macOS o parmak sayısını kapatmışsa Dock olayı hiç gelmez; o zaman `TrackpadTouches` ham
/// dokunmalardan tanır. Parmak sayısı ham dokunmalardan okunur; okunamazsa üç parmak sayılır.
///
/// Hareket Dock'a giden belgesiz bir olay olarak geliyor; CGEventTap onu Dock'tan önce görüp
/// yutabiliyor (ölçüldü, SIP gerekmiyor, Erişilebilirlik izni yeterli). Yalnızca dikey hareket
/// alınır, alan geçişleri (yatay) macOS'ta kalır. Sahne açıkken her dikey kaydırma Berth'ündür: aşağı
/// kapatır. Berth'ün bağlı olduğu bir Windows App oturumu öndeyken App Exposé'ye giden hareket alınır
/// ve o bilgisayara gider.
///
/// Geri çağrı ayrı bir iş parçacığında çalışır: ana iş parçacığı meşgulken olay beklerse macOS
/// tap'i kapatır. Uygulama çökerse tap kalkar ve hareketler kendiliğinden macOS'a döner.
final class TrackpadGestureTap: @unchecked Sendable {
    var onAction: (@MainActor (GestureAction) -> Void)?
    var onClose: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var overlayOpen = false
    private var remoteDown = false
    private var map = TrackpadGestureMap()
    private var system = SystemGestures(vertical: [:], missionControl: true, appExpose: true)
    private var isRunning = false
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Yalnızca tap iş parçacığında kullanılır.
    private var interpreter = SwipeGestureInterpreter()
    private var tap: CFMachPort?
    private var gestureFingers = 3
    /// Bu hareket için ham dokunmalar zaten tetikledi; Dock olayı yalnızca yutulur.
    private var rawAlreadyFired = false
    private let touches = TrackpadTouches()

    private static func field(_ raw: UInt32) -> CGEventField { unsafeBitCast(raw, to: CGEventField.self) }
    private static let dockControlType: UInt32 = 30
    private static let dockSwipeHID: Int64 = 23

    func setOverlayOpen(_ open: Bool) {
        lock.lock()
        overlayOpen = open
        lock.unlock()
    }

    /// App Exposé'ye giden hareket macOS'a bırakılmaz, Windows oturumuna gider. Ana iş parçacığı
    /// günceller; hareket sırasında soru sorulmaz (tap beklerse macOS onu kapatır).
    func setCapturesDown(_ value: Bool) {
        lock.lock()
        remoteDown = value
        lock.unlock()
    }

    /// Tablo ya da macOS'un ayarı değişince. Berth'ün hiçbir harekete karışması gerekmiyorsa durur.
    func configure(map: TrackpadGestureMap, system: SystemGestures) {
        lock.lock()
        self.map = map
        self.system = system
        lock.unlock()
        let needed = TrackpadGestureMap.fingerCounts.contains { fingers in
            SwipeDirection.allCases.contains { map[fingers, $0] != system.native(fingers: fingers, direction: $0) }
        } || map.contains(.appExpose)
        if needed { start() } else { stop() }
    }

    private struct Snapshot {
        var overlayOpen: Bool
        var remoteDown: Bool
        var map: TrackpadGestureMap
        var system: SystemGestures
    }

    private var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(overlayOpen: overlayOpen, remoteDown: remoteDown, map: map, system: system)
    }

    private func start() {
        touches.onSwipe = { [weak self] swipe in self?.rawSwipe(swipe) ?? false }
        touches.start()
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        isRunning = true
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "berth.trackpad-gesture"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func stop() {
        touches.stop()
        lock.lock()
        isRunning = false
        let loop = runLoop
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }

    private var shouldRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private func run() {
        // İzin sonradan verilebilir: tap kurulana kadar dener.
        while shouldRun {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1) << CGEventMask(Self.dockControlType),
                callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<TrackpadGestureTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                },
                userInfo: context
            )
            guard let created else {
                Thread.sleep(forTimeInterval: 3)
                continue
            }
            tap = created
            let source = CFMachPortCreateRunLoopSource(nil, created, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)

            lock.lock()
            runLoop = CFRunLoopGetCurrent()
            lock.unlock()

            CFRunLoopRun()

            CGEvent.tapEnable(tap: created, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(created)
            tap = nil
            lock.lock()
            runLoop = nil
            lock.unlock()
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(Self.field(110)) == Self.dockSwipeHID else {
            return Unmanaged.passUnretained(event)
        }

        let axis = event.getIntegerValueField(Self.field(123))
        let phase = event.getIntegerValueField(Self.field(132))
        let state = snapshot
        if axis == SwipeGestureInterpreter.verticalAxis, phase == 1 {
            gestureFingers = GestureRouting.fingers(touches.sessionFingers)
            rawAlreadyFired = touches.markDockHandled()
        }
        let fingers = gestureFingers
        let (decision, direction) = interpreter.handle(
            axis: axis,
            phase: phase,
            progress: event.getDoubleValueField(Self.field(124)),
            velocity: event.getDoubleValueField(Self.field(129)),
            capture: { direction in
                GestureRouting.captures(fingers: fingers, direction: direction, map: state.map, system: state.system,
                                        overlayOpen: state.overlayOpen, remoteDown: state.remoteDown)
            }
        )
        if let direction, !rawAlreadyFired {
            perform(GestureRouting.outcome(fingers: fingers, direction: direction, map: state.map, overlayOpen: state.overlayOpen))
        }
        return decision == .swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Dock olayı gelmeden ham dokunmalardan tanınan hareket. macOS bu parmak sayısında dikey kaydırmayı
    /// açmışsa Dock olayı gelecek demektir: iş macOS'unsa dokunulmaz. Tetiklendiyse `true`.
    private func rawSwipe(_ swipe: MultiFingerSwipe.Swipe) -> Bool {
        let state = snapshot
        let macOSHandles = state.system.vertical[swipe.fingers] == true
            && !GestureRouting.captures(fingers: swipe.fingers, direction: swipe.direction, map: state.map, system: state.system,
                                        overlayOpen: state.overlayOpen, remoteDown: state.remoteDown)
        guard !macOSHandles else { return false }
        let outcome = GestureRouting.outcome(fingers: swipe.fingers, direction: swipe.direction, map: state.map, overlayOpen: state.overlayOpen)
        guard outcome != .none else { return false }
        perform(outcome)
        return true
    }

    private func perform(_ outcome: GestureRouting.Outcome) {
        switch outcome {
        case .none:
            break
        case .close:
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onClose?() } }
        case .perform(let action):
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onAction?(action) } }
        }
    }
}


/// Trackpad'in ham dokunmaları (belgesiz MultitouchSupport). İzin gerektirmez; macOS 26.2'de ölçüldü.
///
/// Sembol bulunamazsa hiçbir şey yapmaz: parmak sayısı 0 kalır ve Dock hareketi eskisi gibi
/// her parmak sayısında yakalanır.
final class TrackpadTouches: @unchecked Sendable {
    /// Dock olayı gelmemiş bir oturumda tanınan kaydırma; tetiklendiyse `true` döner.
    var onSwipe: ((MultiFingerSwipe.Swipe) -> Bool)?

    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, FrameCallback) -> Void
    private typealias Control = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private static let createList = symbol("MTDeviceCreateList", as: CreateList.self)

    /// Çerçeve ve gerekli işlevler bulunuyor mu (uyumluluk denetimi için)?
    static var isAvailable: Bool { createList != nil && register != nil && startDevice != nil }
    private static let register = symbol("MTRegisterContactFrameCallback", as: Register.self)
    private static let unregister = symbol("MTUnregisterContactFrameCallback", as: Register.self)
    private static let startDevice = symbol("MTDeviceStart", as: Control.self)
    private static let stopDevice = symbol("MTDeviceStop", as: Stop.self)

    /// C geri çağrısı bağlam taşımıyor; tek örnek buradan bulunur.
    private nonisolated(unsafe) static weak var active: TrackpadTouches?

    // Dokunma yapısı (MTTouch): 96 bayt; durum 20'de, 0...1 konum 32'de.
    private static let stride = 96
    private static let stateOffset = 20
    private static let positionOffset = 32

    private let lock = NSLock()
    private var recognizer = MultiFingerSwipe()
    private var dockHandled = false
    private var firedInSession = false
    private var devices: [AnyObject] = []
    private var sessionStart: Double?

    var sessionFingers: Int {
        lock.lock()
        defer { lock.unlock() }
        return recognizer.sessionFingers
    }

    /// Bu oturumu Dock olayı işliyor; ham dokunmadan ikinci kez tetiklenmesin. Ham dokunmalar zaten
    /// tetiklediyse `true`.
    func markDockHandled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        dockHandled = true
        return firedInSession
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard devices.isEmpty, let createList = Self.createList, let register = Self.register,
              let startDevice = Self.startDevice,
              let list = createList()?.takeRetainedValue() as? [AnyObject]
        else { return }
        Self.active = self
        for device in list {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            register(pointer, Self.callback)
            _ = startDevice(pointer, 0)
        }
        devices = list
        DockTrace.log("trackpad dokunma kaynagi: \(list.count) aygit")
    }

    func stop() {
        lock.lock()
        let list = devices
        devices = []
        lock.unlock()
        for device in list {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            Self.unregister?(pointer, Self.callback)
            _ = Self.stopDevice?(pointer)
        }
    }

    private static let callback: FrameCallback = { _, touches, count, timestamp, _ in
        active?.frame(touches, count: Int(count), timestamp: timestamp)
        return 0
    }

    private func frame(_ touches: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        var points: [CGPoint] = []
        if let touches {
            for index in 0..<count {
                let base = touches + index * Self.stride
                let state = base.load(fromByteOffset: Self.stateOffset, as: Int32.self)
                // 3: değmeye başladı, 4: değiyor. Kalkan ve havada süzülen parmaklar sayılmaz.
                guard state == 3 || state == 4 else { continue }
                let x = base.load(fromByteOffset: Self.positionOffset, as: Float.self)
                let y = base.load(fromByteOffset: Self.positionOffset + 4, as: Float.self)
                points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }
        lock.lock()
        let fingersBefore = recognizer.sessionFingers
        let swipe = recognizer.handle(points)
        let handledByDock = dockHandled
        if points.isEmpty {
            if fingersBefore >= 3, let start = sessionStart {
                let summary = "dokunma oturumu: \(fingersBefore) parmak, dock=\(handledByDock), \(Int((timestamp - start) * 1000)) ms"
                DispatchQueue.main.async { DockTrace.log(summary) }
            }
            dockHandled = false
            firedInSession = false
            sessionStart = nil
        } else if sessionStart == nil {
            sessionStart = timestamp
        }
        lock.unlock()

        guard !handledByDock, let swipe, onSwipe?(swipe) == true else { return }
        lock.lock()
        firedInSession = true
        lock.unlock()
        DispatchQueue.main.async { DockTrace.log("ham dokunmayla: \(swipe.fingers) parmak \(swipe.direction.rawValue)") }
    }
}
