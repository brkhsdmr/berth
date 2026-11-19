import Foundation

/// Harici farede hız ve ivmenin ayrı ayarlanması: Windows'taki "İşaretçi hassasiyetini artır"
/// hissine yaklaşmak için.
///
/// macOS'un "İzleme hızı" kaydırıcısı ikisini tek değere bağlar: hızı artırmak eğriyi de dikleştirir
/// (kısa harekette durgun, hızlıda fırlayan imleç). Burada iki ayrı değer var:
/// - hız: temel çarpan. Fare olduğundan düşük DPI'lı gibi gösterilerek uygulanır
///   (`HIDPointerResolution` = 400 / hız DPI). Kısa mesafeyi belirler.
/// - ivme: macOS ivme eğrisi (`HIDMouseAcceleration`, sistem kaydırıcısıyla aynı ölçek: 0 düz,
///   3 sistemin en diki). Uzun ve hızlı hareketi belirler.
///
/// Değerler `hidutil property --matching … --set …` ile yalnız seçilen farenin servisine yazılır;
/// izin istemez, kalıcı değildir.
///
/// macOS 27'de Bluetooth LE fareler (DriverKit sürücüsü, `AppleUserHIDEventService`) yazılan
/// çözünürlüğü yok sayıyor: ivme filtresi çözünürlüğü sürücünün kendi özelliğinden okuyor. Çarpan
/// (`HIDPointerAccelerationMultiplier`) ve kullanıcı eğrileri (`HIDUserPointerAccelCurves`) de
/// bu farelerde etkisiz kaldı (Logi M240 ile denendi). İşleyen tek yol düz ölçek: ivme eğrisi kapanır,
/// hareket hız kadar büyütülür (`HIDUseLinearScalingMouseAcceleration`). Bu farelerde ivmeyi Berth hesaplar
/// (bkz. `PointerAccelerator`).
public enum MouseTune {
    public static let speedRange: ClosedRange<Double> = 0.5...4.0
    /// Sistem kaydırıcısı 3'te biter; üstü de kabul ediliyor, uzun mesafe için pay bırakıldı.
    public static let accelerationRange: ClosedRange<Double> = 0...5
    /// Berth'ün önerisi: Windows'ta EPP açık, hız 20/20 hissine yakın (HP Z3700 ile denendi).
    public static let defaultSpeed = 2.0
    public static let defaultAcceleration = 3.0

    /// macOS'un harici farelere varsaydığı çözünürlük.
    public static let defaultDPI = 400.0

    public static func clampSpeed(_ value: Double) -> Double { min(speedRange.upperBound, max(speedRange.lowerBound, value)) }
    public static func clampAcceleration(_ value: Double) -> Double {
        min(accelerationRange.upperBound, max(accelerationRange.lowerBound, value))
    }

    /// 16.16 sabit noktalı değer.
    public static func fixed(_ value: Double) -> Int { Int((value * 65536).rounded()) }

    /// Hız çarpanının `HIDPointerResolution` karşılığı (16.16, DPI).
    public static func resolution(forSpeed speed: Double) -> Int { fixed(defaultDPI / clampSpeed(speed)) }

    public static func propertiesJSON(speed: Double, acceleration: Double) -> String {
        propertiesJSON(resolution: resolution(forSpeed: speed), acceleration: fixed(clampAcceleration(acceleration)))
    }

    /// macOS'un kendi değerleri: varsayılan çözünürlük ve Sistem Ayarları'ndaki izleme hızı.
    public static func systemPropertiesJSON(scaling: Double) -> String {
        propertiesJSON(resolution: fixed(defaultDPI), acceleration: fixed(scaling))
    }

    /// Çözünürlüğü yok sayan fareler için düz ölçek: imleç hareketi `speed` kadar büyür, ivme yok.
    public static func flatPropertiesJSON(speed: Double) -> String {
        "{\"HIDUseLinearScalingMouseAcceleration\":1,\"HIDMouseAcceleration\":\(fixed(clampSpeed(speed)))}"
    }

    /// Düz ölçek kapalı yazılır: önceden düz ölçekte kaldıysa macOS'un eğrisi geri gelsin.
    static func propertiesJSON(resolution: Int, acceleration: Int) -> String {
        "{\"HIDUseLinearScalingMouseAcceleration\":0,\"HIDPointerResolution\":\(resolution),\"HIDMouseAcceleration\":\(acceleration)}"
    }

    /// Fare ürün adıyla eşlenir: bazı fareler (HP Z3700) üretici ve ürün kimliğini ters bildiriyor.
    public static func matchingJSON(mouseName: String) -> String {
        let escaped = mouseName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"Product\":\"\(escaped)\",\"PrimaryUsagePage\":1,\"PrimaryUsage\":2}"
    }
}

/// Bir farenin ayarı. Fareler ürün adıyla ayrı saklanır.
public struct MouseProfile: Equatable, Sendable {
    /// Kapalıyken fare macOS'un kendi ayarıyla çalışır.
    public var enabled: Bool
    public var speed: Double
    public var acceleration: Double

    public init(enabled: Bool = true, speed: Double = MouseTune.defaultSpeed, acceleration: Double = MouseTune.defaultAcceleration) {
        self.enabled = enabled
        self.speed = MouseTune.clampSpeed(speed)
        self.acceleration = MouseTune.clampAcceleration(acceleration)
    }

    /// Berth'ün önerdiği değerler.
    public static let suggested = MouseProfile()

    /// macOS'un bu fareye kendi uyguladığının karşılığı: temel hız ve Sistem Ayarları'ndaki
    /// izleme hızı (`com.apple.mouse.scaling`) ivme olarak.
    public static func system(scaling: Double) -> MouseProfile {
        MouseProfile(speed: 1, acceleration: scaling)
    }

    /// `UserDefaults` için.
    public var dictionary: [String: Any] { ["enabled": enabled, "speed": speed, "acceleration": acceleration] }

    public init(dictionary: [String: Any]) {
        self.init(enabled: dictionary["enabled"] as? Bool ?? true,
                  speed: (dictionary["speed"] as? NSNumber)?.doubleValue ?? MouseTune.defaultSpeed,
                  acceleration: (dictionary["acceleration"] as? NSNumber)?.doubleValue ?? MouseTune.defaultAcceleration)
    }
}

/// Eğrisi değiştirilemeyen farelerde (bkz. `MouseTune`) ivmeyi Berth hesaplar: imleç hareketinin
/// hızı izlenir, macOS'un kabul ettiği düz çarpan anlık güncellenir. Yavaş harekette çarpan hızın
/// kendisi, hızlandıkça büyür; fare durunca hıza döner.
///
/// Eğri Pebble M350s ile denendi (2026-11-20): ivme 3 (öneri) iken en hızlı harekette çarpan hızın
/// 3,25 katı.
public struct PointerAccelerator: Equatable, Sendable {
    /// Çarpanın tam büyüdüğü ham hız (fare sayımı / sn) ve büyümenin tavanı (bu hızın katı).
    static let referenceVelocity = 1500.0
    static let velocityCap = 1.5
    /// Hızın yumuşatıldığı süre (sn).
    static let smoothing = 0.03
    /// Çarpan bu orandan az değişirse yazılmaz.
    static let threshold = 0.04

    public let speed: Double
    public let acceleration: Double
    public private(set) var factor: Double
    private var velocity = 0.0

    public init(speed: Double, acceleration: Double) {
        self.speed = MouseTune.clampSpeed(speed)
        self.acceleration = MouseTune.clampAcceleration(acceleration)
        factor = self.speed
    }

    /// Ham hıza göre çarpan.
    public func factor(forVelocity velocity: Double) -> Double {
        speed * (1 + acceleration / 2 * min(max(velocity, 0) / Self.referenceVelocity, Self.velocityCap))
    }

    /// İmleç `distance` piksel gitti (çarpan uygulanmış), önceki hareketten `interval` sn sonra.
    /// Çarpan yazılacak kadar değiştiyse yenisini döndürür.
    public mutating func move(distance: Double, interval: TimeInterval) -> Double? {
        let dt = max(interval, 0.001)
        let instant = distance / factor / min(dt, 0.05)
        velocity += (instant - velocity) * min(1, dt / Self.smoothing)
        return update(factor(forVelocity: velocity))
    }

    /// Fare durdu: çarpan hıza döner.
    public mutating func rest() -> Double? {
        velocity = 0
        return update(speed)
    }

    private mutating func update(_ next: Double) -> Double? {
        guard next != factor, next == speed || abs(next - factor) / factor > Self.threshold else { return nil }
        factor = next
        return next
    }
}
