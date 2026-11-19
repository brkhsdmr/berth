import AppKit
import BerthCore

/// İmleç ekranın sol ya da sağ dış kenarına (dikeyde ortadaki bantta) değince bir masaüstü sola ya
/// da sağa geçer (`EdgeSwitch`). Varsayılan kapalı.
///
/// - Anlık dokunma yeter. Tetikledikten sonra imleç kenardan ayrılmadan yeniden tetiklenmez.
/// - Basılı tutulacak niteleme tuşları seçildiyse yalnızca onlar basılıyken geçer; tuşa kenarda
///   beklerken basmak da geçirir.
/// - Fare düğmesi basılıyken tetiklenmez: pencere sürükleme, kenara yaslama ve boyutlandırma kenarı
///   kullanır. Sürükleme kenarda bitse bile imleç kenardan ayrılıp yeniden gelene kadar beklenir.
/// - İmleç ekranın kenarına dayanınca konumu değişmez ve fare hareketi olayı güvenilir gelmez;
///   bu yüzden imleç saniyede 30 kez yoklanır (yalnızca açıkken).
///
/// Geçiş, Dock'a yapay bir dört parmak yatay kaydırma olayı gönderilerek yapılır: yapay ^← / ^→
/// kısayolunu Dock masaüstü değiştirme olarak kabul etmiyor, uzak masaüstü öndeyken klavye de
/// oraya gider. macOS 27'den beri olaya ham IOHID verisi de eklenmeli. Olay alanları belgesizdir
/// (yöntem InstantSpaceSwitcher'dan, MIT); bir macOS güncellemesi bozabilir. Olay göndermek
/// Erişilebilirlik izni ister.
@MainActor
final class EdgeSwitchMonitor {
    /// `true` döndükçe tetiklenmez (sahne açıkken).
    var isBlocked: () -> Bool = { false }

    private var enabled = false
    private var band = EdgeSwitch.defaultBand
    private var hold = EdgeSwitch.HoldKeys()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Başlangıçta kapalı: imleç zaten kenardaysa açılır açılmaz tetiklemesin.
    private var isArmed = false
    private var lastSwitch = Date.distantPast

    private static let pollInterval: TimeInterval = 1.0 / 30.0
    /// Kayma animasyonu sürerken ikinci geçiş gönderilmesin.
    private static let minimumInterval: TimeInterval = 0.6
    /// Kenara bu kadar nokta yaklaşınca dokunmuş sayılır.
    private static let touchMargin: CGFloat = 1
    /// Yeniden kurulmak için kenardan bu kadar uzaklaşmalı.
    private static let rearmMargin: CGFloat = 6

    func configure(enabled: Bool, band: Double, hold: EdgeSwitch.HoldKeys) {
        self.enabled = enabled
        self.band = band
        self.hold = hold
        isArmed = false
        if enabled { installObservers() } else { removeObservers() }
        syncTimer()
    }

    private func syncTimer() {
        if enabled {
            guard timer == nil else { return }
            let created = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            created.tolerance = Self.pollInterval * 0.5
            RunLoop.main.add(created, forMode: .common)
            timer = created
        } else {
            timer?.invalidate()
            timer = nil
            isArmed = false
        }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let screens = NSScreen.screens.map(\.frame)
        guard let side = EdgeSwitch.side(at: point, screens: screens, band: band, margin: Self.touchMargin) else {
            if !isArmed, EdgeSwitch.side(at: point, screens: screens, band: band, margin: Self.rearmMargin) == nil {
                isArmed = true
            }
            return
        }
        guard isArmed else { return }
        // Tuş seçildiyse basılana kadar kenarda beklenir: önce kenara gelip sonra basmak da geçirir.
        guard hold.isHeld(in: Self.pressedKeys) else { return }
        // Tetiklesin ya da tetiklemesin: yeni geçiş için kenardan ayrılmak gerekir.
        isArmed = false
        guard NSEvent.pressedMouseButtons == 0, !isBlocked(),
              Date().timeIntervalSince(lastSwitch) >= Self.minimumInterval,
              WindowActivator.isTrusted
        else { return }
        lastSwitch = Date()
        Self.switchSpace(side)
    }

    /// Şu an basılı niteleme tuşları (olay izni gerekmez).
    static var pressedKeys: EdgeSwitch.HoldKeys {
        let flags = NSEvent.modifierFlags
        var keys = EdgeSwitch.HoldKeys()
        if flags.contains(.control) { keys.insert(.control) }
        if flags.contains(.option) { keys.insert(.option) }
        if flags.contains(.shift) { keys.insert(.shift) }
        if flags.contains(.command) { keys.insert(.command) }
        if flags.contains(.function) { keys.insert(.function) }
        return keys
    }

    // MARK: Geçiş

    static func switchSpace(_ side: EdgeSwitch.Side) {
        SpaceSwitcher.move(by: side == .right ? 1 : -1)
    }

    // MARK: Uyku

    /// Uykuda yoklama durur; uyanınca imleç kenardaysa hemen tetiklemesin.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer?.invalidate()
                self?.timer = nil
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isArmed = false
                self?.syncTimer()
            }
        })
    }

    private func removeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}
