// Kullanıcı ayarları ve ayarlar penceresi. Dosya: %APPDATA%\Berth\settings.ini
#pragma once
#include <windows.h>
#include <functional>
#include <string>
#include <vector>

enum class HotCorner { None = 0, TopLeft, TopRight, BottomLeft, BottomRight };

struct Settings {
    bool shortcutEnabled = true;
    UINT shortcutMods = MOD_ALT | MOD_SHIFT;  // MOD_* değerleri
    UINT shortcutKey = VK_SPACE;
    HotCorner corner = HotCorner::None;
    int cornerDelayMs = 0;
    bool taskbarPreview = true;
    /// Sahnede aşağı kaydırınca sabit olmayan uygulamaların pencereleri kendi hücrelerinde görünür.
    bool otherAppsScroll = false;
    /// Dokunmatik yüzeyde üç parmak hareketlerini Berth tanır (Windows'un hareketinden bağımsız):
    /// yukarı sahne, aşağı öndeki uygulamanın pencereleri.
    bool touchpadGestures = true;
    /// Mac'teki uygulamanın adı (Tailscale ya da yerel ağ) ve eşleştirme kodu; boşsa bağlanılmaz.
    std::wstring remoteHost, remoteToken;
    /// Ayarlardan "Bağlantıyı kes" denince false; "Bağlan" ile yeniden açılır.
    bool remoteEnabled = true;
    /// Arayüz dili; text::Language. Yeniden başlatınca geçerli olur.
    int language = 0;

    static Settings load();
    void save() const;
};

/// "Alt+Shift+Space" gibi.
std::wstring shortcutText(UINT mods, UINT key);

/// İmlecin bulunduğu köşe; ekran kenarına birkaç piksellik pay verilir.
HotCorner cornerAt(POINT p, const RECT& monitor);

/// Oturum açılınca başlatma. Kurulumla gelen sürümde Run kayıt anahtarı, Store (MSIX) sürümünde
/// paket bildirimindeki başlangıç görevi.
namespace launch {
bool packaged();
bool enabled();
/// Store sürümünde kullanıcı Görev Yöneticisi'nden kapattıysa uygulama yeniden açamaz.
bool blockedByUser();
bool set(bool on);
}

class SettingsWindow {
public:
    struct Callbacks {
        /// Ayar değişti; kaydetme ve uygulama burada.
        std::function<void(const Settings&)> changed;
        /// Kısayol alınabildiyse true.
        std::function<bool(UINT mods, UINT key)> tryShortcut;

        // Sabit uygulamalar. Boyut: 0 küçük, 1 orta, 2 büyük.
        struct PinRow { std::wstring name; int size = 0; };
        enum class PinEdit { MoveUp, MoveDown, SetSize, Remove, Add };
        std::function<std::vector<PinRow>()> pins;
        /// Çalışan ama sabitlenmemiş uygulamaların adları.
        std::function<std::vector<std::wstring>()> addable;
        /// `value`: SetSize'da boyut, Add'de `addable` sırası.
        std::function<void(PinEdit edit, int index, int value)> editPin;

        // Çalışma düzenleri.
        struct LayoutRow { std::wstring name; UINT mods = 0, key = 0; size_t windows = 0; };
        enum class LayoutEdit { SaveNew, Rename, Remove, Restore, SetHotkey, ClearHotkey };
        std::function<std::vector<LayoutRow>()> layouts;
        /// Kısayol alınamadıysa (başkası kullanıyor) false.
        std::function<bool(LayoutEdit edit, int index, const std::wstring& name, UINT mods, UINT key)> editLayout;
        /// Mac bağlantısının durumu.
        std::function<std::wstring()> remoteStatus;
    };

    void show(HINSTANCE instance, const Settings& current, Callbacks callbacks);
    LRESULT handle(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);

private:
    /// Sayfada çizilen kart: solda simge, başlık ve açıklama; denetimler sağına yerleşir.
    /// `reserve`: sağda denetimlere ayrılan genişlik (DIP); açıklama ondan önce kırılır.
    struct Card { RECT r{}; wchar_t glyph = 0; std::wstring title, desc; int reserve = 0; bool danger = false; };
    /// Kart dışındaki açıklama metni.
    struct Note { RECT r{}; std::wstring text; bool danger = false; };
    enum class ButtonKind { Normal, Accent, Toggle, Segment, Recorder };

    void create();
    void applyTheme();
    void buildPage();
    void sync();
    void command(int id, int code);
    void click(POINT p);
    void paint(HDC dc, const RECT& area);
    void drawItem(const DRAWITEMSTRUCT* d);
    HWND addControl(const wchar_t* cls, const wchar_t* text, DWORD style, int id, int x, int y, int w, int h);
    HWND addButton(int id, const wchar_t* text, ButtonKind kind, int x, int y, int w, int h = 32);
    int px(int v) const;
    void syncPins(int select);
    void editPin(Callbacks::PinEdit edit, int value = 0);
    void syncLayouts(int select);
    void editLayout(Callbacks::LayoutEdit edit);
    void refreshStatus();
    bool remoteConnected() const;
    HWND addField(int id, DWORD style, int x, int y, int w, int h = 32);
    void recordKey(int id, UINT vk);
    void applyShortcut(UINT mods, UINT key);
    static LRESULT CALLBACK recorderProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR data);

    HINSTANCE instance_ = nullptr;
    HWND hwnd_ = nullptr;
    HFONT font_ = nullptr;
    HBRUSH cardBrush_ = nullptr, controlBrush_ = nullptr;
    UINT dpi_ = 96;
    bool dark_ = false;
    int page_ = 0, hoverNav_ = -1;
    Settings settings_;
    Callbacks callbacks_;
    std::wstring shortcutError_, layoutMessage_, remoteStatus_;
    bool syncingLayouts_ = false;
    std::vector<Card> cards_;
    std::vector<Note> notes_;
    std::vector<Callbacks::PinRow> pinRows_;
    int selectedPin_ = -1;
    RECT navRects_[5]{}, cornerDots_[4]{}, cornerScreen_{}, pinStrip_{}, listFrame_{};
    int statusCard_ = -1, shortcutCard_ = -1;
    std::vector<std::pair<int, ButtonKind>> buttons_;
    std::vector<std::pair<int, bool>> toggles_;
    /// Çerçevesini kendimiz çizdiğimiz yazı kutuları.
    std::vector<RECT> fields_;
    /// Kısayol kaydedicisi: tuş bekleyen düğmenin kimliği, yoksa 0.
    int recording_ = 0;
    UINT layoutMods_ = 0, layoutKey_ = 0;
};
