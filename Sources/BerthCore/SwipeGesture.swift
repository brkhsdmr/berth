/// Trackpad'in dikey Dock hareketini yorumlar.
///
/// Değerler gerçek hareketten ölçüldü: eksen 2 dikeydir, faz 1 başlangıç, 2 değişim, 4 bitiş;
/// ilerleme yukarı kaydırmada artı, aşağı kaydırmada eksidir ve işareti ilk olaydan bellidir.
/// Hareketin alınıp alınmayacağına (yutulur) ilk olayda karar verilir; alınan hareket eşiği
/// geçince bir kez yönüyle tetiklenir.
public struct SwipeGestureInterpreter: Sendable {
    public enum Decision: Equatable, Sendable { case pass, swallow }

    public static let verticalAxis: Int64 = 2
    /// Parmak yolunun yaklaşık üçte biri: kazara dokunmalarda tetiklenmez, geç de kalmaz.
    public static let commitProgress = 0.12
    /// Kısa ama hızlı kaydırma da geçerlidir.
    public static let flickVelocity = 2.0

    private enum State { case idle, capturing, passing }
    private var state = State.idle
    private var fired = false

    public init() {}

    /// - Parameter capture: İlk olayda hareketin yönüyle sorulur; `true` dönerse hareket macOS'a
    ///   gitmez, Berth'ündür.
    /// - Returns: Karar ve alınan hareket tetiklendiyse yönü (hareket sırasında yön değişmiş olabilir).
    public mutating func handle(axis: Int64, phase: Int64, progress: Double, velocity: Double,
                                capture: (SwipeDirection) -> Bool) -> (Decision, SwipeDirection?) {
        guard axis == Self.verticalAxis else { return (.pass, nil) }

        if phase == 1 {
            fired = false
            state = capture(progress < 0 ? .down : .up) ? .capturing : .passing
            return (state == .capturing ? .swallow : .pass, nil)
        }

        switch state {
        case .idle:
            return (.pass, nil)
        case .passing:
            if phase != 2 { state = .idle }
            return (.pass, nil)
        case .capturing:
            var result: SwipeDirection?
            if !fired, phase == 2 || phase == 4 {
                let committed = abs(progress) >= Self.commitProgress || (phase == 4 && abs(velocity) >= Self.flickVelocity)
                if committed, progress != 0 {
                    result = progress > 0 ? .up : .down
                    fired = true
                }
            }
            if phase != 2 { state = .idle }
            return (.swallow, result)
        }
    }
}
