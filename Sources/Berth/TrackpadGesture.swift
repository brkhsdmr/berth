import AppKit
import BerthCore

/// Seçilen parmak sayısıyla yukarı kaydırmayı Mission Control'e ulaşmadan yakalar, sahneyi açar.
///
/// İki kaynak birlikte çalışır. macOS o parmak sayısını Mission Control'e atamışsa hareket Dock
/// olayı olarak gelir ve burada yutulur (akıcı, ilerlemesi belli). Atamamışsa Dock olayı hiç
/// gelmez; o zaman `TrackpadTouches` ham dokunmalardan tanır. Dock olayı geldiğinde parmak sayısı
/// seçilenden farklıysa olay macOS'a bırakılır: 3 parmak seçildiyse 4 parmak Mission Control'ü açar.
///
/// Hareket Dock'a giden belgesiz bir olay olarak geliyor; CGEventTap onu Dock'tan önce görüp
/// yutabiliyor (ölçüldü, SIP gerekmiyor, Erişilebilirlik izni yeterli). Yalnızca dikey hareket
/// alınır: alan geçişleri (yatay) ve App Exposé (aşağı) macOS'ta kalır.
///
/// Geri çağrı ayrı bir iş parçacığında çalışır: ana iş parçacığı meşgulken olay beklerse macOS
/// tap'i kapatır. Uygulama çökerse ya da seçenek kapatılırsa tap kalkar ve Mission Control kendiliğinden
/// eski hâline döner.
final class TrackpadGestureTap: @unchecked Sendable {
    var onOpen: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var overlayOpen = false
    private var isRunning = false
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Yalnızca tap iş parçacığında kullanılır.
    private var interpreter = SwipeGestureInterpreter()
    private var tap: CFMachPort?
    /// Parmak sayısı tutmadığı için macOS'a bırakılan Dock hareketi sürüyor.
    private var passingOtherFingers = false
    private let touches = TrackpadTouches()
    private var fingers = 3

    private static func field(_ raw: UInt32) -> CGEventField { unsafeBitCast(raw, to: CGEventField.self) }
    private static let dockControlType: UInt32 = 30
    private static let dockSwipeHID: Int64 = 23

    func setOverlayOpen(_ open: Bool) {
        lock.lock()
        overlayOpen = open
        lock.unlock()
    }

    /// 0 kapatır.
    func setFingers(_ count: Int) {
        lock.lock()
        fingers = count
        lock.unlock()
        touches.setFingers(count)
        if count > 0 { start() } else { stop() }
    }

    private var chosenFingers: Int {
        lock.lock()
        defer { lock.unlock() }
        return fingers
    }

    private var overlayIsOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overlayOpen
    }

    func start() {
        touches.overlayIsOpen = { [weak self] in self?.overlayIsOpen ?? false }
        touches.onOpen = { [weak self] in self?.onOpen?() }
        touches.onClose = { [weak self] in self?.onClose?() }
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

    func stop() {
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
        if axis == SwipeGestureInterpreter.verticalAxis {
            if phase == 1 {
                // Dokunma bilgisi yoksa (0) eski davranış: hareket bizimdir.
                let count = touches.sessionFingers
                passingOtherFingers = count > 0 && count != chosenFingers
                if !passingOtherFingers { touches.markDockHandled() }
            }
            if passingOtherFingers {
                if phase != 1 && phase != 2 { passingOtherFingers = false }
                return Unmanaged.passUnretained(event)
            }
        }

        let (decision, action) = interpreter.handle(
            axis: axis,
            phase: phase,
            progress: event.getDoubleValueField(Self.field(124)),
            velocity: event.getDoubleValueField(Self.field(129)),
            overlayOpen: overlayIsOpen
        )

        switch action {
        case .none:
            break
        case .open:
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onOpen?() } }
        case .close:
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onClose?() } }
        }
        return decision == .swallow ? nil : Unmanaged.passUnretained(event)
    }
}


/// Trackpad'in ham dokunmaları (belgesiz MultitouchSupport). İzin gerektirmez; macOS 26.2'de ölçüldü.
///
/// Sembol bulunamazsa hiçbir şey yapmaz: parmak sayısı 0 kalır ve Dock hareketi eskisi gibi
/// her parmak sayısında yakalanır.
final class TrackpadTouches: @unchecked Sendable {
    var onOpen: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?
    var overlayIsOpen: (() -> Bool)?

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
    private var recognizer = MultiFingerSwipe(fingers: 3)
    private var dockHandled = false
    private var devices: [AnyObject] = []
    private var sessionStart: Double?

    func setFingers(_ count: Int) {
        lock.lock()
        recognizer.fingers = count
        lock.unlock()
    }

    var sessionFingers: Int {
        lock.lock()
        defer { lock.unlock() }
        return recognizer.sessionFingers
    }

    /// Bu oturumu Dock olayı işliyor; ham dokunmadan ikinci kez tetiklenmesin.
    func markDockHandled() {
        lock.lock()
        dockHandled = true
        lock.unlock()
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
        let open = overlayIsOpen?() ?? false

        lock.lock()
        let fingersBefore = recognizer.sessionFingers
        let action = recognizer.handle(points, overlayOpen: open)
        let handledByDock = dockHandled
        if points.isEmpty {
            if fingersBefore >= 3, let start = sessionStart {
                let summary = "dokunma oturumu: \(fingersBefore) parmak, dock=\(handledByDock), \(Int((timestamp - start) * 1000)) ms"
                DispatchQueue.main.async { DockTrace.log(summary) }
            }
            dockHandled = false
            sessionStart = nil
        } else if sessionStart == nil {
            sessionStart = timestamp
        }
        lock.unlock()

        guard !handledByDock else { return }
        switch action {
        case .none: break
        case .open:
            DispatchQueue.main.async { [weak self] in
                DockTrace.log("ham dokunmayla acildi")
                MainActor.assumeIsolated { self?.onOpen?() }
            }
        case .close:
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onClose?() } }
        }
    }
}
