import AppKit
import BerthCore

/// Fare tekerleğini Windows gibi kaydırır (bkz. `ScrollWheel`, `SmoothScroll`): satırlı tekerlek
/// olayları yutulur, her çentik sabit satır kadar piksele çevrilip kısa sürede yumuşak, sürekli
/// olaylar olarak gönderilir. Trackpad ve Magic Mouse (sürekli olaylar, bizimkiler de) değişmez.
/// Windows App öndeyken olaylara dokunulmaz: uzak bilgisayar tekerleği kendi ayarıyla yorumlar.
/// Erişilebilirlik izni gerekir.
///
/// Olay musluğu ve adımlar kendi iş parçacığında: ana iş parçacığı meşgulken tekerlek takılmasın.
@MainActor
final class ScrollWheelTuner {
    private static let windowsAppID = "com.microsoft.rdc.macos"

    private var worker: WheelWorker?
    private var observer: NSObjectProtocol?

    func configure(enabled: Bool, lines: Int) {
        guard enabled else {
            stop()
            return
        }
        if worker == nil {
            let worker = WheelWorker()
            guard worker.start() else {
                DockTrace.log("tekerlek: olay musluğu kurulamadı (Erişilebilirlik izni?)")
                return
            }
            self.worker = worker
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFront() }
            }
            updateFront()
        }
        worker?.lines = lines
    }

    func shutdown() { stop() }

    private func stop() {
        worker?.stop()
        worker = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private func updateFront() {
        worker?.passThrough = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.windowsAppID
    }
}

/// Kendi iş parçacığında çalışan musluk ve yumuşak kaydırma. `lines` ve `passThrough` ana iş
/// parçacığından yazılır.
private final class WheelWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines = ScrollWheel.defaultLines
    private var _passThrough = false
    var lines: Int {
        get { lock.withLock { _lines } }
        set { lock.withLock { _lines = newValue } }
    }
    var passThrough: Bool {
        get { lock.withLock { _passThrough } }
        set { lock.withLock { _passThrough = newValue } }
    }

    // Yalnızca iş parçacığında.
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var timer: Timer?
    private var scroll = SmoothScroll()
    private var lastNotch = 0.0
    private var lastDirection: Int64 = 0
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Musluk kurulamazsa `false`.
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let thread = Thread { [self] in
            ok = installTap()
            runLoop = CFRunLoopGetCurrent()
            ready.signal()
            if ok { CFRunLoopRun() }
        }
        thread.name = "berth.scroll-wheel"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        return ok
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            timer?.invalidate()
            timer = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            tap = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.runLoop = nil
    }

    private func installTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let worker = Unmanaged<WheelWorker>.fromOpaque(context).takeUnretainedValue()
            return worker.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel, !passThrough,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
        else { return Unmanaged.passUnretained(event) }
        let vertical = ScrollWheel.flattened(lines: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                                             fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), to: 1)
        let horizontal = ScrollWheel.flattened(lines: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                                               fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), to: 1)
        guard vertical != nil || horizontal != nil else { return Unmanaged.passUnretained(event) }
        // Aynı yönde art arda gelen çentikler sıklaştıkça daha uzağa gider.
        let now = CFAbsoluteTimeGetCurrent()
        let direction = (vertical?.lines ?? 0) * 2 + (horizontal?.lines ?? 0)
        let boost = direction == lastDirection ? SmoothScroll.boost(interval: now - lastNotch) : 1
        lastNotch = now
        lastDirection = direction
        scroll.add(vertical: vertical?.lines ?? 0, horizontal: horizontal?.lines ?? 0, lines: lines, boost: boost)
        startTimer()
        return nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let (y, x) = scroll.step()
        if y != 0 || x != 0,
           let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) {
            event.post(tap: .cgSessionEventTap)
        }
        if scroll.isIdle {
            timer?.invalidate()
            timer = nil
        }
    }
}
