import Foundation

/// Dock otomatik gizliyken önizleme açık kaldıkça Dock'u açık tutar.
///
/// macOS, imleç Dock'tan çıkınca Dock'u saklar; önizlemeye geçmek de çıkmak sayılır. Dock'u açık
/// tutmanın belgelenmiş yolu yok: önizleme açıkken otomatik gizleme geçici olarak kapatılır,
/// kapanınca geri açılır (DockDoor da böyle yapıyor). Belgelenmemiş `CoreDock` işlevleri çalışma
/// anında aranır; bulunamazsa hiçbir şey yapılmaz.
///
/// Ayar macOS'ta kalıcı olduğu için iki koruma var: pencereye geçmeden önce geri açılır (yoksa
/// büyütülen pencere Dock'un yerini boş bırakır) ve uygulama çökerse bir sonraki açılışta geri açılır.
enum DockAutoHide {
    private typealias Get = @convention(c) () -> Bool
    private typealias Set = @convention(c) (Bool) -> Void

    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
    private static let get: Get? = handle.flatMap { dlsym($0, "CoreDockGetAutoHideEnabled") }.map { unsafeBitCast($0, to: Get.self) }
    private static let set: Set? = handle.flatMap { dlsym($0, "CoreDockSetAutoHideEnabled") }.map { unsafeBitCast($0, to: Set.self) }

    /// Kapattığımız ve geri açmamız gereken otomatik gizleme.
    private static let pendingKey = "dockAutoHideToRestore"
    private static var holding = false

    /// Otomatik gizleme açıksa geçici olarak kapatır.
    static func hold() {
        guard !holding, let get, let set, get() else { return }
        UserDefaults.standard.set(true, forKey: pendingKey)
        set(false)
        holding = true
    }

    /// `hold` ile kapatılanı geri açar.
    static func release() {
        guard holding else { return }
        holding = false
        set?(true)
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    /// Önceki çalışma otomatik gizlemeyi kapalı bırakarak bittiyse geri açar.
    static func restoreAfterCrash() {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return }
        set?(true)
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }
}
