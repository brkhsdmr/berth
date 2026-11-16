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
public enum MouseTune {
    public static let speedRange: ClosedRange<Double> = 0.5...4.0
    /// Sistem kaydırıcısı 3'te biter; üstü de kabul ediliyor, uzun mesafe için pay bırakıldı.
    public static let accelerationRange: ClosedRange<Double> = 0...5
    /// Varsayılanlar: Windows'ta EPP açık, hız 20/20 hissine yakın (HP Z3700 ile denendi).
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

    static func propertiesJSON(resolution: Int, acceleration: Int) -> String {
        "{\"HIDPointerResolution\":\(resolution),\"HIDMouseAcceleration\":\(acceleration)}"
    }

    /// Fare ürün adıyla eşlenir: bazı fareler (HP Z3700) üretici ve ürün kimliğini ters bildiriyor.
    public static func matchingJSON(mouseName: String) -> String {
        let escaped = mouseName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"Product\":\"\(escaped)\",\"PrimaryUsagePage\":1,\"PrimaryUsage\":2}"
    }
}
