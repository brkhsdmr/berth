/// Trackpad'in dikey Dock hareketini yorumlar.
///
/// Değerler gerçek hareketten ölçüldü: eksen 2 dikeydir, faz 1 başlangıç, 2 değişim, 4 bitiş;
/// ilerleme yukarı kaydırmada artı, aşağı kaydırmada eksidir ve işareti ilk olaydan bellidir.
public struct SwipeGestureInterpreter: Sendable {
    public enum Decision: Equatable, Sendable { case pass, swallow }
    /// `down`: sahne kapalıyken aşağı kaydırma (yalnızca `capturesDown` ile; uzak masaüstüne gider).
    public enum Action: Equatable, Sendable { case none, open, close, down }

    public static let verticalAxis: Int64 = 2
    /// Parmak yolunun yaklaşık üçte biri: kazara dokunmalarda tetiklenmez, geç de kalmaz.
    public static let commitProgress = 0.12
    /// Kısa ama hızlı kaydırma da geçerlidir.
    public static let flickVelocity = 2.0

    private enum State { case idle, capturing, passing }
    private var state = State.idle
    private var fired = false
    private var opensOnUp = true
    private var takesDown = false

    public init() {}

    /// - Parameter overlayOpen: Sahne açık mı. Kapalıyken aşağı kaydırma macOS'a bırakılır
    ///   (App Exposé); açıkken aşağı kaydırma sahneyi kapatır.
    /// - Parameter capturesDown: Sahne kapalıyken aşağı kaydırma da alınır ve `down` olur
    ///   (Windows App oturumu öndeyken o bilgisayarın uygulama pencereleri).
    public mutating func handle(axis: Int64, phase: Int64, progress: Double, velocity: Double, overlayOpen: Bool,
                                capturesDown: Bool = false) -> (Decision, Action) {
        guard axis == Self.verticalAxis else { return (.pass, .none) }

        if phase == 1 {
            fired = false
            opensOnUp = !overlayOpen
            takesDown = capturesDown && !overlayOpen
            state = (progress < 0 && !overlayOpen && !takesDown) ? .passing : .capturing
            return (state == .capturing ? .swallow : .pass, .none)
        }

        switch state {
        case .idle:
            return (.pass, .none)
        case .passing:
            if phase != 2 { state = .idle }
            return (.pass, .none)
        case .capturing:
            var result = Action.none
            if !fired {
                let committed = abs(progress) >= Self.commitProgress
                    || (phase == 4 && abs(velocity) >= Self.flickVelocity)
                if committed, phase == 2 || phase == 4 {
                    result = action(forProgress: progress)
                    fired = result != .none
                }
            }
            if phase != 2 { state = .idle }
            return (.swallow, result)
        }
    }

    private func action(forProgress progress: Double) -> Action {
        if opensOnUp { return progress > 0 ? .open : (progress < 0 && takesDown ? .down : .none) }
        return progress < 0 ? .close : .none
    }
}
