// Berth, Windows. Sabit yerli yığınlarla Görev Görünümü yerine geçen sahne.
//
// İki pencere var: arka pencere zemini ve etiketleri çizer, DWM önizlemeleri onun üstüne biner.
// Önizlemelerin üstünde kalması gerekenler (rozet, vurgu, başlık) ve fare olayları ön pencerededir.
// Görev çubuğu örtülmez: sahne çalışma alanını kaplar, Mac'teki Dock gibi yerinde kalır.
#define NOMINMAX
#include <windows.h>
#include <d2d1_1.h>
#include <d2d1effects.h>
#include <dwmapi.h>
#include <dwrite.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <atomic>
#include <map>
#include <mutex>
#include <thread>
#include <set>
#include <string>
#include <vector>
#include "../core/layout.h"
#include "demo.h"
#include "icon.h"
#include "layouts.h"
#include "remote.h"
#include "settings.h"
#include "source.h"
#include "taskbar.h"
#include "text.h"
#include "vdesktop.h"

#pragma comment(lib, "d2d1")
#pragma comment(lib, "dwrite")
#pragma comment(lib, "dwmapi")
#pragma comment(lib, "windowscodecs")
#pragma comment(lib, "ole32")
#pragma comment(lib, "shell32")
#pragma comment(lib, "user32")
#pragma comment(lib, "gdi32")
#pragma comment(lib, "version")
#pragma comment(lib, "runtimeobject")
#pragma comment(lib, "dxguid")
// Ayarlar penceresi Windows 11 görünümlü denetimler kullansın (ComCtl32 v6).
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kToggleMessage = WM_APP + 2;
constexpr UINT kTrayOpen = 1, kTrayQuit = 2, kTraySettings = 3, kTraySaveLayout = 4;
constexpr UINT kTrayRestoreBase = 100, kTrayDeleteBase = 200;
constexpr int kHotKeyId = 1;
/// Mac'teki uygulama, RDP oturumunda üç parmak hareketini bu kısayolla iletir. Mac'in kendi
/// kısayoluyla (⌥⇧Space) çakışmasın diye Ctrl de eklidir.
constexpr int kRemoteHotKeyId = 2;
constexpr UINT_PTR kAnimationTimer = 1;
constexpr UINT_PTR kCloseTimer = 2;
constexpr UINT_PTR kTaskbarTimer = 3;
constexpr UINT_PTR kMinimizeTimer = 4;
constexpr UINT_PTR kLayoutRetryTimer = 5;
constexpr UINT_PTR kScrollTimer = 6;
/// Çalışma düzeni kısayolları bu kimlikten başlar.
constexpr int kLayoutHotKeyBase = 100;
constexpr int kActionCount = 5; // Sola, sağa, ekranı kapla, küçült, kapat.
constexpr int kCloseAction = kActionCount - 1;
constexpr int kAnimationMs = 220;

const wchar_t* kToggleEvent = L"Local\\Berth.Toggle";
const wchar_t* kQuitEvent = L"Local\\Berth.Quit";
const wchar_t* kSettingsEvent = L"Local\\Berth.Settings";

D2D1_RECT_F toD2D(const Rect& r) {
    return D2D1::RectF(float(r.x), float(r.y), float(r.right()), float(r.bottom()));
}

// MARK: Düzen kaydı

struct Pin {
    std::string id;
    std::wstring path;
    std::wstring name;
    SlotSize size = SlotSize::Small;
};

std::wstring storePath() {
    wchar_t* base = nullptr;
    std::wstring path;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) {
        path = std::wstring(base) + L"\\Berth";
        CoTaskMemFree(base);
        CreateDirectoryW(path.c_str(), nullptr);
        path += L"\\arrangement.txt";
    }
    return path;
}

std::vector<Pin> loadPins() {
    std::vector<Pin> pins;
    std::ifstream file(storePath());
    std::string line;
    bool first = true;
    while (std::getline(file, line)) {
        // Elle düzenlenmiş dosya bayt işaretiyle ya da Windows satır sonuyla gelebilir.
        // Bozuk satır atlanır: kayıt dosyası yüzünden uygulama düşmemeli.
        if (first && line.rfind("\xEF\xBB\xBF", 0) == 0) line.erase(0, 3);
        first = false;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto a = line.find('\t');
        auto b = a == std::string::npos ? a : line.find('\t', a + 1);
        if (b == std::string::npos || a != 1 || line[0] < '0' || line[0] > '2') continue;
        Pin pin;
        pin.size = static_cast<SlotSize>(line[0] - '0');
        pin.path = fromUtf8(line.substr(a + 1, b - a - 1));
        pin.name = fromUtf8(line.substr(b + 1));
        std::wstring lower = pin.path;
        std::transform(lower.begin(), lower.end(), lower.begin(), [](wchar_t c) { return wchar_t(towlower(c)); });
        pin.id = toUtf8(stableAppPath(lower));
        pins.push_back(pin);
    }
    return pins;
}

void savePins(const std::vector<Pin>& pins) {
    std::ofstream file(storePath(), std::ios::trunc);
    for (const auto& p : pins) file << int(p.size) << '\t' << toUtf8(p.path) << '\t' << toUtf8(p.name) << '\n';
}

// MARK: Uygulama

enum class HitKind { Window, Space, NewDesktop, EmptySlot, Chip, Hint, Launch };
enum class DragKind { None, Tile, Space, Slot };

struct Hit {
    Rect rect;
    HitKind kind;
    size_t index = 0;   // Pencere, masaüstü ya da uygulama sırası.
    bool scrolls = false;   // Sayfayla kayar: `rect`, `page`ten türer.
    Rect page;          // Sayfa uzayındaki yer.
};

struct Tile {
    SceneWindow window;
    Rect page;      // Sayfa uzayındaki yer.
    Rect target;    // Görünen yer: `page`, kaydırma kadar yukarıda.
    Rect start;
    bool flies = false;
    HTHUMBNAIL thumb = nullptr;
    SIZE source{};
};

class App {
public:
    bool start(HINSTANCE instance);
    void toggle();
    void openSettings() { showSettings(); }
    void notify(const std::wstring& text);
    void refreshPinPaths();
    void restoreSaved(const SavedLayout& layout);
    void layoutRetryTick();
    void registerLayoutHotkeys();
    SavedLayout pendingLayout_;
    RemoteLink remote_;
    int pendingRetries_ = 0;
    LRESULT handle(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
    HWND controlWindow() const { return control_; }
    void activateWindow(const SceneWindow& window) { activate(window); }

private:
    void open();
    void close();
    void layout();
    void registerThumbnails();
    void clearStripThumbnails();
    std::vector<HTHUMBNAIL> stripThumbs_;
    void placeThumbnail(Tile& tile, const Rect& rect, BYTE opacity, bool clip = true);
    Rect clipRect() const;
    Rect shifted(Rect rect) const { rect.y -= scrollOffset_; return rect; }
    void applyScroll();
    void scrollChanged();
    void scrollTo(double value);
    void stepScroll();
    void scrollIntoView(const Tile& tile);
    int pinAt(int x, int y) const;
    bool onHoveredTile(int x, int y) const;
    void reorderPin(size_t pin, size_t gap);
    void stepAnimation();
    void renderBack();
    void renderFront();
    void drawText(ID2D1RenderTarget* rt, const std::wstring& text, const Rect& rect, IDWriteTextFormat* format,
                  ID2D1Brush* brush, bool shadow);
    ID2D1Bitmap* iconFor(ID2D1RenderTarget* rt, const std::wstring& path, std::map<std::wstring, ComPtr<ID2D1Bitmap>>& cache);
    void loadWallpaper();
    const Hit* hitAt(int x, int y) const;
    void click(int x, int y);
    void mouseDown(int x, int y);
    void mouseMoved(int x, int y, bool buttonDown);
    void mouseUp(int x, int y);
    void updateDrop(int x, int y);
    void finishDrag(int x, int y);
    void rightClick(int x, int y);
    void refreshScene();
    Rect actionRect(const Tile& tile, int action) const;
    void snapWindow(const SceneWindow& window, SnapPosition position);
    void closeWindowAction(const SceneWindow& window);
    void minimizeWindowAction(const SceneWindow& window);
    void closeTimerTick();
    bool matches(const SceneWindow& window) const;
    bool containsQuery(const std::wstring& text) const;
    void applyQuery();
    void character(wchar_t ch);
    void writeLayoutTrace() const;
    void activate(const SceneWindow& window);
    void showTray(bool add);
    void trayMenu();

    HINSTANCE instance_ = nullptr;
    HWND control_ = nullptr, back_ = nullptr, front_ = nullptr;
    VirtualDesktops desktops_;
    bool isOpen_ = false;
    Snapshot snapshot_;
    std::vector<Pin> pins_;
    std::vector<Tile> tiles_;
    std::vector<Hit> hits_;
    std::vector<std::pair<Rect, DesktopInfo>> strip_;
    std::vector<std::string> otherApps_;
    std::map<std::string, PlacedSlot> placed_;
    std::vector<PlacedSlot> pinnedSlots_;
    Rect pinnedArea_;
    int hover_ = -1;
    int hoverAction_ = -1;

    // Kaydırma
    double scrollOffset_ = 0, scrollTarget_ = 0, maxScroll_ = 0;
    /// Sayfanın göründüğü alan; kaydırılacak bir şey yoksa tüm sahne.
    Rect viewport_;

    // Sürükleme
    DragKind drag_ = DragKind::None;
    int pressHit_ = -1;
    int pressX_ = 0, pressY_ = 0;
    int dragX_ = 0, dragY_ = 0;
    int dropDesktop_ = -1;   // Şeritteki hedef masaüstü.
    int dropGap_ = -1;       // Masaüstü sürüklenirken aralık.
    int pressPin_ = -1;      // Basılan sabit hücre.
    int dragPin_ = -1;       // Sürüklenen sabit hücre; bırakılan yer sırayı değiştirebilir.
    std::optional<SlotDrop> slotDrop_;
    bool dropNew_ = false;   // "+" üzerine bırakma.
    size_t dragTile_ = 0, dragSpace_ = 0;
    Rect newDesktopRect_;

    // Pencere kapatma: kaydet sorusu çıkarsa pencereye gidilir.
    HWND closing_ = nullptr;
    SceneWindow closingWindow_;
    int closeTicks_ = 0;

    std::wstring query_;
    /// Ctrl+A ile aramadaki yazının tümü seçili: Backspace siler, yazmak yerine koyar.
    bool selectAll_ = false;
    /// Uygulamalar klasöründeki (shell:AppsFolder) uygulamalar: arama açık olmayanları da bulsun.
    struct InstalledApp { std::wstring name, parsing; };
    std::vector<InstalledApp> installed_;
    std::mutex installedLock_;
    std::atomic<bool> scanning_{false};
    /// Aramaya uyan, sahnede olmayan uygulamalar (en çok 5).
    std::vector<InstalledApp> appResults_;
    std::map<std::wstring, ComPtr<IWICBitmapSource>> appIcons_;
    void scanInstalled();
    void updateAppResults();
    void launchInstalled(size_t index);
    IWICBitmapSource* installedIcon(const std::wstring& parsing);
    bool searchFocused_ = false;
    HMONITOR sceneMonitor_ = nullptr;
    ULONGLONG closedByDeactivationAt_ = 0;
    Rect hintRect_;
    void keyDown(WPARAM vk);
    void moveSelection(WPARAM vk);
    double scale_ = 1;
    int width_ = 0, height_ = 0;
    RECT area_{};
    ULONGLONG animationStart_ = 0;

    ComPtr<ID2D1Factory1> d2d_;
    ComPtr<IDWriteFactory> dwrite_;
    ComPtr<IWICImagingFactory> wic_;
    ComPtr<ID2D1HwndRenderTarget> backTarget_;
    ComPtr<IDWriteTextFormat> labelFormat_, smallFormat_, hintFormat_;
    ComPtr<IWICFormatConverter> wallpaperSource_;
    std::map<std::wstring, ComPtr<ID2D1Bitmap>> backIcons_;
    ComPtr<ID2D1Bitmap> wallpaperBitmap_;
    /// Bulanıklaştırma her karede yapılmaz: kaydırma akıcı kalır.
    ComPtr<ID2D1Bitmap> blurredBackdrop_;
#ifdef DEBUG
    std::map<HWND, ComPtr<ID2D1Bitmap>> skeletons_;
    ID2D1Bitmap* skeletonFor(ID2D1RenderTarget* rt, HWND hwnd);
#endif
    NOTIFYICONDATAW tray_{};
    TaskbarPreview preview_;

    // Ayarlar
    Settings settings_;
    SettingsWindow settingsWindow_;
    std::vector<Pin> addable_;
    bool applyShortcut(UINT mods, UINT key);
    void showSettings();
    void hotCornerTick();
    HotCorner cornerInside_ = HotCorner::None;
    ULONGLONG cornerSince_ = 0;
    bool cornerFired_ = false;
};

App* g_app = nullptr;

LRESULT CALLBACK windowProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    return g_app ? g_app->handle(hwnd, msg, wp, lp) : DefWindowProcW(hwnd, msg, wp, lp);
}

bool App::start(HINSTANCE instance) {
    instance_ = instance;
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d_.GetAddressOf()))) return false;
    DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(dwrite_.GetAddressOf()));
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic_));
    desktops_.init();
    pins_ = loadPins();

    WNDCLASSW wc{};
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"Berth";
    RegisterClassW(&wc);

    control_ = CreateWindowExW(0, wc.lpszClassName, L"Berth", WS_POPUP, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance, nullptr);
    DWORD tool = WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
    back_ = CreateWindowExW(tool | WS_EX_NOACTIVATE, wc.lpszClassName, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, instance, nullptr);
    front_ = CreateWindowExW(tool | WS_EX_LAYERED, wc.lpszClassName, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, instance, nullptr);

    // Varsayılan Alt+Shift+Space: Alt+Space Windows'ta sistem menüsü; Mac'teki kısayolun aynısı.
    settings_ = Settings::load();
    if (settings_.shortcutEnabled && !applyShortcut(settings_.shortcutMods, settings_.shortcutKey)) {
        settings_.shortcutEnabled = false; // Başkası almış; ayarlarda kapalı görünür, kullanıcı başka tuş seçer.
    }
    RegisterHotKey(control_, kRemoteHotKeyId, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, VK_SPACE);
    showTray(true);
    registerLayoutHotkeys();
    remote_.configure(settings_.remoteEnabled ? settings_.remoteHost : std::wstring(), settings_.remoteToken, control_, kToggleMessage);

    preview_.init(instance, d2d_.Get(), dwrite_.Get(), wic_.Get(), &desktops_,
                  {[this](const SceneWindow& w) { activate(w); }, [this] { return isOpen_; }});
    // Görev çubuğu izleme: imleç görev çubuğunda değilken her turda yalnızca bir konum okuması.
    SetTimer(control_, kTaskbarTimer, 60, nullptr);
    return true;
}

void App::showTray(bool add) {
    tray_.cbSize = sizeof tray_;
    tray_.hWnd = control_;
    tray_.uID = 1;
    tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    tray_.uCallbackMessage = kTrayMessage;
    // Görev çubuğu açık/koyu temasına göre çizilir; tepsi küçük simge boyutunu ister.
    if (tray_.hIcon && add) DestroyIcon(tray_.hIcon);
    tray_.hIcon = add ? makeAppIcon(GetSystemMetrics(SM_CXSMICON), true) : tray_.hIcon;
    std::wstring tip = L"Berth";
    if (settings_.shortcutEnabled) tip += L" (" + shortcutText(settings_.shortcutMods, settings_.shortcutKey) + L")";
    wcsncpy_s(tray_.szTip, tip.c_str(), _TRUNCATE);
    Shell_NotifyIconW(add ? NIM_ADD : NIM_DELETE, &tray_);
}

/// Tepsi simgesinden kısa bildirim (Mac'teki Toast'un karşılığı).
void App::notify(const std::wstring& text) {
    NOTIFYICONDATAW data = tray_;
    data.uFlags = NIF_INFO;
    data.dwInfoFlags = NIIF_NONE | NIIF_NOSOUND;
    wcsncpy_s(data.szInfoTitle, L"Berth", _TRUNCATE);
    wcsncpy_s(data.szInfo, text.c_str(), _TRUNCATE);
    Shell_NotifyIconW(NIM_MODIFY, &data);
}

/// Düzeni yükler. Kapalı uygulamalar başlatılır; pencereleri açıldıkça birkaç kez daha yerleştirilir.
void App::restoreSaved(const SavedLayout& layout) {
    Snapshot snapshot = readSnapshot(desktops_);
    int launched = launchMissingApps(layout, snapshot);
    int moved = restoreLayout(layout, snapshot, desktops_);
    if (launched > 0) {
        pendingLayout_ = layout;
        pendingRetries_ = 4;
        SetTimer(control_, kLayoutRetryTimer, 2500, nullptr);
        notify(layout.name + tx(L" y\u00FCkleniyor; ", L" is restoring; opening ") + text::apps(size_t(launched)) + tx(L" a\u00E7\u0131l\u0131yor.", L"."));
        return;
    }
    int missing = int(layout.windows.size()) - moved;
    notify(layout.name + tx(L" y\u00FCklendi", L" restored") + (missing > 0 ? L"; " + text::windows(size_t(missing)) + tx(L" bulunamad\u0131 ya da ta\u015F\u0131namad\u0131.", L" could not be found or moved.") : std::wstring(L".")));
}

void App::layoutRetryTick() {
    int moved = restoreLayout(pendingLayout_, readSnapshot(desktops_), desktops_);
    int missing = int(pendingLayout_.windows.size()) - moved;
    if (missing == 0 || --pendingRetries_ <= 0) {
        KillTimer(control_, kLayoutRetryTimer);
        notify(pendingLayout_.name + tx(L" y\u00FCklendi", L" restored") + (missing > 0 ? L"; " + text::windows(size_t(missing)) + tx(L" bulunamad\u0131.", L" not found.") : std::wstring(L".")));
    }
}

void App::registerLayoutHotkeys() {
    for (int i = 0; i < 100; ++i) UnregisterHotKey(control_, kLayoutHotKeyBase + i);
    auto layouts = loadLayouts();
    for (size_t i = 0; i < layouts.size() && i < 100; ++i)
        if (layouts[i].hotkeyKey) RegisterHotKey(control_, kLayoutHotKeyBase + int(i), layouts[i].hotkeyMods | MOD_NOREPEAT, layouts[i].hotkeyKey);
}

void App::trayMenu() {
    HMENU menu = CreatePopupMenu();
    std::wstring openLabel = tx(L"A\u00E7", L"Open");
    if (settings_.shortcutEnabled) openLabel += L"\t" + shortcutText(settings_.shortcutMods, settings_.shortcutKey);
    AppendMenuW(menu, MF_STRING, kTrayOpen, openLabel.c_str());
    AppendMenuW(menu, MF_STRING, kTraySettings, tx(L"Ayarlar\u2026", L"Settings\u2026"));
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    // Çalışma düzenleri
    std::vector<SavedLayout> layouts = loadLayouts();
    AppendMenuW(menu, MF_STRING, kTraySaveLayout, tx(L"\u00C7al\u0131\u015Fma d\u00FCzenini kaydet", L"Save workspace layout"));
    if (!layouts.empty()) {
        HMENU restore = CreatePopupMenu(), remove = CreatePopupMenu();
        for (size_t i = 0; i < layouts.size() && i < 90; ++i) {
            std::wstring label = layouts[i].name + L"\t" + text::windows(layouts[i].windows.size());
            AppendMenuW(restore, MF_STRING, kTrayRestoreBase + i, label.c_str());
            AppendMenuW(remove, MF_STRING, kTrayDeleteBase + i, layouts[i].name.c_str());
        }
        AppendMenuW(menu, MF_POPUP, UINT_PTR(restore), tx(L"\u00C7al\u0131\u015Fma d\u00FCzenini y\u00FCkle", L"Restore workspace layout"));
        AppendMenuW(menu, MF_POPUP, UINT_PTR(remove), tx(L"\u00C7al\u0131\u015Fma d\u00FCzenini sil", L"Delete workspace layout"));
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kTrayQuit, tx(L"Berth'ten \u00C7\u0131k", L"Quit Berth"));
    POINT p;
    GetCursorPos(&p);
    SetForegroundWindow(front_);
    int choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, p.x, p.y, 0, front_, nullptr);
    DestroyMenu(menu);
    if (choice == kTrayOpen) toggle();
    if (choice == kTraySettings) showSettings();
    if (choice == kTraySaveLayout) {
        if (isOpen_) close();
        SavedLayout layout = captureLayout(readSnapshot(desktops_), nextLayoutName(layouts));
        layouts.push_back(layout);
        saveLayouts(layouts);
        notify(layout.name + tx(L" kaydedildi: ", L" saved: ") + text::windows(layout.windows.size()) + L".");
    }
    if (choice >= int(kTrayRestoreBase) && choice < int(kTrayRestoreBase) + int(layouts.size())) {
        if (isOpen_) close();
        restoreSaved(layouts[choice - kTrayRestoreBase]);
    }
    if (choice >= int(kTrayDeleteBase) && choice < int(kTrayDeleteBase) + int(layouts.size())) {
        std::wstring name = layouts[choice - kTrayDeleteBase].name;
        layouts.erase(layouts.begin() + (choice - kTrayDeleteBase));
        saveLayouts(layouts);
        registerLayoutHotkeys();
        notify(name + tx(L" silindi.", L" deleted."));
    }
    if (choice == kTrayQuit) {
        showTray(false);
        PostQuitMessage(0);
    }
}

bool App::applyShortcut(UINT mods, UINT key) {
    UnregisterHotKey(control_, kHotKeyId);
    if (RegisterHotKey(control_, kHotKeyId, mods | MOD_NOREPEAT, key)) return true;
    // Alınamadıysa öncekini geri al.
    if (settings_.shortcutEnabled) RegisterHotKey(control_, kHotKeyId, settings_.shortcutMods | MOD_NOREPEAT, settings_.shortcutKey);
    return false;
}

void App::showSettings() {
    settingsWindow_.show(instance_, settings_, {
        [this](const Settings& next) {
            bool shortcutChanged = next.shortcutEnabled != settings_.shortcutEnabled;
            settings_ = next;
            if (shortcutChanged) {
                if (settings_.shortcutEnabled) applyShortcut(settings_.shortcutMods, settings_.shortcutKey);
                else UnregisterHotKey(control_, kHotKeyId);
            }
            if (!settings_.taskbarPreview) preview_.hide();
            cornerInside_ = HotCorner::None;
            settings_.save();
            remote_.configure(settings_.remoteEnabled ? settings_.remoteHost : std::wstring(), settings_.remoteToken, control_, kToggleMessage);
            showTray(false); // İpucundaki kısayol yenilensin.
            showTray(true);
        },
        [this](UINT mods, UINT key) { return applyShortcut(mods, key); },
        [this] {
            std::vector<SettingsWindow::Callbacks::PinRow> rows;
            for (const auto& pin : pins_) rows.push_back({pin.name, int(pin.size)});
            return rows;
        },
        [this] {
            addable_.clear();
            Snapshot current = readSnapshot(desktops_);
            std::vector<std::wstring> names;
            for (const auto& [id, app] : current.apps) {
                if (std::any_of(pins_.begin(), pins_.end(), [&](const Pin& p) { return p.id == id; })) continue;
                addable_.push_back({id, app.path, app.name, initialSlotSize(int(app.windows.size()))});
            }
            std::sort(addable_.begin(), addable_.end(), [](const Pin& a, const Pin& b) { return a.name < b.name; });
            for (const auto& pin : addable_) names.push_back(pin.name);
            return names;
        },
        [this](SettingsWindow::Callbacks::PinEdit edit, int index, int value) {
            using E = SettingsWindow::Callbacks::PinEdit;
            int count = int(pins_.size());
            switch (edit) {
            case E::MoveUp: if (index > 0 && index < count) std::swap(pins_[index], pins_[index - 1]); break;
            case E::MoveDown: if (index >= 0 && index + 1 < count) std::swap(pins_[index], pins_[index + 1]); break;
            case E::SetSize: if (index >= 0 && index < count && value >= 0 && value <= 2) pins_[index].size = SlotSize(value); break;
            case E::Remove: if (index >= 0 && index < count) pins_.erase(pins_.begin() + index); break;
            case E::Add: if (value >= 0 && value < int(addable_.size())) pins_.push_back(addable_[value]); break;
            }
            savePins(pins_);
            if (isOpen_) refreshScene();
        },
        [] {
            std::vector<SettingsWindow::Callbacks::LayoutRow> rows;
            for (const auto& l : loadLayouts()) rows.push_back({l.name, l.hotkeyMods, l.hotkeyKey, l.windows.size()});
            return rows;
        },
        [this](SettingsWindow::Callbacks::LayoutEdit edit, int index, const std::wstring& name, UINT mods, UINT key) {
            using E = SettingsWindow::Callbacks::LayoutEdit;
            auto layouts = loadLayouts();
            if (edit == E::SaveNew) {
                SavedLayout layout = captureLayout(readSnapshot(desktops_), nextLayoutName(layouts));
                layouts.push_back(layout);
                saveLayouts(layouts);
                notify(layout.name + tx(L" kaydedildi: ", L" saved: ") + text::windows(layout.windows.size()) + L".");
                return true;
            }
            if (index < 0 || index >= int(layouts.size())) return false;
            bool ok = true;
            switch (edit) {
            case E::Rename: if (!name.empty()) layouts[index].name = name; break;
            case E::Remove: layouts.erase(layouts.begin() + index); break;
            case E::Restore: restoreSaved(layouts[index]); return true;
            case E::ClearHotkey: layouts[index].hotkeyMods = layouts[index].hotkeyKey = 0; break;
            case E::SetHotkey:
                // Önce dene: başkası kullanıyorsa kaydedilmez.
                UnregisterHotKey(control_, kLayoutHotKeyBase + index);
                ok = RegisterHotKey(control_, kLayoutHotKeyBase + index, mods | MOD_NOREPEAT, key) != FALSE;
                UnregisterHotKey(control_, kLayoutHotKeyBase + index);
                if (ok) {
                    layouts[index].hotkeyMods = mods;
                    layouts[index].hotkeyKey = key;
                }
                break;
            default: break;
            }
            saveLayouts(layouts);
            registerLayoutHotkeys();
            return ok;
        },
        [this] { return remote_.status(); },
    });
}

// Görev çubuğu zamanlayıcısıyla (60 ms) çalışır; köşe seçilmemişse hiçbir şey okunmaz.
void App::hotCornerTick() {
    if (settings_.corner == HotCorner::None) return;
    POINT p;
    GetCursorPos(&p);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST), &info);
    HotCorner now = cornerAt(p, info.rcMonitor);
    ULONGLONG tick = GetTickCount64();
    if (now != cornerInside_) {
        cornerInside_ = now;
        cornerSince_ = tick;
        cornerFired_ = false;
    }
    if (now != settings_.corner || cornerFired_) return;
    bool pressed = (GetAsyncKeyState(VK_LBUTTON) | GetAsyncKeyState(VK_RBUTTON)) & 0x8000;
    if (pressed || tick - cornerSince_ < ULONGLONG(settings_.cornerDelayMs)) return;
    cornerFired_ = true;
    toggle();
}

/// Güncellenen mağaza uygulamasının eski yolu artık yok: çalışan uygulamanın yolu kaydedilir,
/// böylece kapalıyken hücreye tıklamak yine açar.
void App::refreshPinPaths() {
    bool changed = false;
    for (auto& pin : pins_) {
        auto app = snapshot_.apps.find(pin.id);
        if (app != snapshot_.apps.end() && !app->second.path.empty() && app->second.path != pin.path) {
            pin.path = app->second.path;
            changed = true;
        }
    }
    if (changed) savePins(pins_);
}

void App::toggle() {
    // Görev çubuğundaki ya da tepsideki simgeye tıklamak önce sahneyi etkin olmaktan çıkarır ve
    // kapatır, ardından açma isteği gelir. Hemen arkasından gelen istek, kapatmanın parçasıdır.
    if (!isOpen_ && GetTickCount64() - closedByDeactivationAt_ < 700) {
        closedByDeactivationAt_ = 0;
        return;
    }
    if (isOpen_) close();
    else open();
}

void App::open() {
    preview_.hide();
    POINT cursor;
    GetCursorPos(&cursor);
    HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY);
    sceneMonitor_ = monitor;
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    area_ = info.rcWork;
    width_ = area_.right - area_.left;
    height_ = area_.bottom - area_.top;
    UINT dpi = GetDpiForWindow(back_);
    UINT dpiX = 0, dpiY = 0;
    typedef HRESULT(WINAPI * GetDpi)(HMONITOR, int, UINT*, UINT*);
    if (HMODULE shcore = LoadLibraryW(L"shcore.dll")) {
        if (auto fn = reinterpret_cast<GetDpi>(GetProcAddress(shcore, "GetDpiForMonitor"))) {
            if (SUCCEEDED(fn(monitor, 0, &dpiX, &dpiY))) dpi = dpiX;
        }
    }
    scale_ = dpi / 96.0;

    snapshot_ = readSnapshot(desktops_);
    refreshPinPaths();

    // İlk açılış: açık uygulamaların ilk on tanesi sabitlenir, sonra yerleri korunur.
    if (pins_.empty()) {
        std::vector<const SceneApp*> apps;
        for (const auto& [id, app] : snapshot_.apps) apps.push_back(&app);
        std::sort(apps.begin(), apps.end(), [](const SceneApp* a, const SceneApp* b) { return a->name < b->name; });
        for (size_t i = 0; i < apps.size() && i < 10; ++i)
            pins_.push_back({apps[i]->id, apps[i]->path, apps[i]->name, initialSlotSize(int(apps[i]->windows.size()))});
        savePins(pins_);
    }

    SetWindowPos(back_, HWND_TOPMOST, area_.left, area_.top, width_, height_, SWP_NOACTIVATE);
    SetWindowPos(front_, HWND_TOPMOST, area_.left, area_.top, width_, height_, SWP_NOACTIVATE);

    backTarget_.Reset();
    backIcons_.clear();
    wallpaperBitmap_.Reset();
    blurredBackdrop_.Reset();
    d2d_->CreateHwndRenderTarget(
        D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96),
        D2D1::HwndRenderTargetProperties(back_, D2D1::SizeU(width_, height_)), backTarget_.GetAddressOf());

    float base = float(scale_);
    dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 13 * base, text::locale(), labelFormat_.ReleaseAndGetAddressOf());
    dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_MEDIUM, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 11 * base, text::locale(), smallFormat_.ReleaseAndGetAddressOf());
    dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 14 * base, text::locale(), hintFormat_.ReleaseAndGetAddressOf());
    for (auto* format : {labelFormat_.Get(), smallFormat_.Get(), hintFormat_.Get()}) {
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        ComPtr<IDWriteInlineObject> ellipsis;
        dwrite_->CreateEllipsisTrimmingSign(format, ellipsis.GetAddressOf());
        format->SetTrimming(&trim, ellipsis.Get());
    }

    loadWallpaper();
    query_.clear();
    selectAll_ = false;
    appResults_.clear();
    scanInstalled();
    // Açılınca arama odaklı: yazmaya başlamak uygulamayı bulur, Enter açar.
    searchFocused_ = true;
    drag_ = DragKind::None;
    scrollOffset_ = scrollTarget_ = 0;
    layout();
    hover_ = -1;
    hoverAction_ = -1;
    isOpen_ = true;
    ShowWindow(back_, SW_SHOWNOACTIVATE);
    registerThumbnails();
    renderBack();
    renderFront();
    writeLayoutTrace();
    ShowWindow(front_, SW_SHOW);
    SetForegroundWindow(front_);
    if (GetForegroundWindow() != front_) {
        // Sıcak köşe gibi kullanıcı girdisi olmadan açılınca Windows öne almayı engeller. Boş bir
        // fare girdisi son girdiyi bu sürece yazar ve izni verir (PowerToys'un yolu).
        INPUT empty{};
        empty.type = INPUT_MOUSE;
        SendInput(1, &empty, sizeof empty);
        SetForegroundWindow(front_);
    }
    SetFocus(front_);
    animationStart_ = GetTickCount64();
    SetTimer(control_, kAnimationTimer, 15, nullptr);
    stepAnimation();
}

void App::close() {
    if (!isOpen_) return;
    isOpen_ = false;
    KillTimer(control_, kAnimationTimer);
    KillTimer(control_, kCloseTimer);
    KillTimer(control_, kScrollTimer);
    closing_ = nullptr;
    if (GetCapture() == front_) ReleaseCapture();
    drag_ = DragKind::None;
    clearStripThumbnails();
    for (auto& tile : tiles_) {
        if (tile.thumb) DwmUnregisterThumbnail(tile.thumb);
    }
    tiles_.clear();
    ShowWindow(front_, SW_HIDE);
    ShowWindow(back_, SW_HIDE);

    // Gün boyu arka planda duran uygulama: kapalıyken ekran boyutlu görüntüleri tutmaz.
    // Ön pencerenin katmanı da boş bir kareye indirilir, yoksa pencere sistemi onu saklar.
    backIcons_.clear();
    wallpaperBitmap_.Reset();
    blurredBackdrop_.Reset();
#ifdef DEBUG
    skeletons_.clear();
#endif
    backTarget_.Reset();
    wallpaperSource_.Reset();
    snapshot_ = {};
    hits_.clear();
    strip_.clear();
    placed_.clear();
    SetWindowPos(back_, nullptr, 0, 0, 1, 1, SWP_NOACTIVATE | SWP_NOZORDER);
    SetWindowPos(front_, nullptr, 0, 0, 1, 1, SWP_NOACTIVATE | SWP_NOZORDER);
    SetProcessWorkingSetSize(GetCurrentProcess(), SIZE_T(-1), SIZE_T(-1));
}

void App::layout() {
    tiles_.clear();
    hits_.clear();
    strip_.clear();
    placed_.clear();
    otherApps_.clear();
    pinnedSlots_.clear();
    const double s = scale_;

    // Masaüstü şeridi
    double y = 10 * s;
    const double thumbHeight = 72 * s, gapS = 16 * s;
    if (!snapshot_.desktops.empty()) {
        double count = double(snapshot_.desktops.size());
        const double plusWidth = 44 * s;
        double thumbWidth = std::min(124 * s, (width_ - 80 * s - plusWidth - count * gapS) / count);
        double x = width_ / 2.0 - (count * thumbWidth + count * gapS + plusWidth) / 2;
        for (size_t i = 0; i < snapshot_.desktops.size(); ++i) {
            Rect rect{x, y, thumbWidth, thumbHeight};
            strip_.push_back({rect, snapshot_.desktops[i]});
            hits_.push_back({rect, HitKind::Space, i});
            x += thumbWidth + gapS;
        }
        newDesktopRect_ = {x, y, plusWidth, thumbHeight};
        hits_.push_back({newDesktopRect_, HitKind::NewDesktop, 0});
    }
    // Arama kutusu: tıklanınca odaklanır, boşluğa tıklama sayılmaz.
    double stripBottom = y + thumbHeight + 20 * s;
    hintRect_ = {width_ / 2.0 - 200 * s, stripBottom + 4 * s, 400 * s, 34 * s};
    hits_.push_back({hintRect_, HitKind::Hint, 0});
    double hintBottom = hintRect_.bottom();

    const double chipHeight = 32 * s;
    double chipsY = height_ - chipHeight - 12 * s;
    double separatorY = chipsY - 14 * s;
    Rect stage{36 * s, hintBottom + 8 * s, width_ - 72 * s, separatorY - 10 * s - (hintBottom + 8 * s)};

    std::vector<SlotSpec> specs;
    std::set<std::string> pinnedIds;
    for (const auto& pin : pins_) {
        specs.push_back({pin.id, pin.size});
        pinnedIds.insert(pin.id);
    }
    StageMetrics metrics;
    metrics.gap *= s;
    metrics.rowGap *= s;
    metrics.labelHeight *= s;

    const RECT origin = area_;
    auto addPile = [&](const PlacedSlot& slot, const std::vector<SceneWindow>& windows) {
        std::vector<double> aspects;
        size_t visible = std::min<size_t>(windows.size(), kMaxVisiblePile);
        for (size_t i = 0; i < visible; ++i) aspects.push_back(windows[i].aspect());
        Rect pile{slot.pile.x + 2 * s, slot.pile.y + 2 * s, slot.pile.w - 4 * s, slot.pile.h - 4 * s};
        auto frames = pileFrames(pile, aspects);
        for (size_t i = 0; i < visible; ++i) {
            Tile tile;
            tile.window = windows[i];
            tile.page = tile.target = frames[i];
            const auto& f = windows[i].frame;
            tile.start = {double(f.left - origin.left), double(f.top - origin.top), double(f.right - f.left), double(f.bottom - f.top)};
            tile.flies = windows[i].onCurrentDesktop && !windows[i].minimized;
            hits_.push_back({frames[i], HitKind::Window, tiles_.size(), true, frames[i]});
            tiles_.push_back(tile);
        }
    };

    pinnedSlots_ = placeSlots(specs, stage, metrics);
    pinnedArea_ = {stage.x, stage.y, stage.w, separatorY - stage.y};
    for (const auto& slot : pinnedSlots_) {
        placed_[slot.id] = slot;
        auto found = snapshot_.apps.find(slot.id);
        if (found == snapshot_.apps.end() || found->second.windows.empty()) {
            size_t index = 0;
            for (size_t i = 0; i < pins_.size(); ++i) if (pins_[i].id == slot.id) index = i;
            double h = std::min(slot.pile.h - 4 * s, slot.pile.w * 0.72);
            double w = std::min(slot.pile.w - 4 * s, h * 4 / 3);
            Rect rect{slot.pile.midX() - w / 2, slot.pile.bottom() - h - 2 * s, w, h};
            hits_.push_back({rect, HitKind::EmptySlot, index, true, rect});
            continue;
        }
        addPile(slot, found->second.windows);
    }

    for (const auto& [id, app] : snapshot_.apps) {
        if (!pinnedIds.count(id) && !app.windows.empty()) otherApps_.push_back(id);
    }
    std::sort(otherApps_.begin(), otherApps_.end(), [&](const std::string& a, const std::string& b) {
        return snapshot_.apps[a].name < snapshot_.apps[b].name;
    });

    // Kaydırınca gelen bölüm ekranın hemen altından başlar, ilk görünüm değişmez.
    const double viewportTop = hintBottom + 4 * s;
    double pageBottom = height_;
    if (settings_.otherAppsScroll && !otherApps_.empty()) {
        std::vector<SlotSpec> others;
        for (const auto& id : otherApps_)
            others.push_back({id, initialSlotSize(int(snapshot_.apps[id].windows.size()))});
        for (const auto& slot : placeSlotsFlowing(others, stage.x, stage.w, height_ + 16 * s, height_ - viewportTop - 16 * s, metrics)) {
            placed_[slot.id] = slot;
            addPile(slot, snapshot_.apps[slot.id].windows);
            pageBottom = std::max(pageBottom, slot.frame.bottom() + 16 * s);
        }
    }
    maxScroll_ = pageBottom - height_;
    viewport_ = maxScroll_ > 0 ? Rect{0, viewportTop, double(width_), height_ - viewportTop} : Rect{0, 0, double(width_), double(height_)};
    scrollOffset_ = std::min(scrollOffset_, maxScroll_);
    scrollTarget_ = std::min(scrollTarget_, maxScroll_);
    applyScroll();
    // Görünmeyen pencereler uçmaz, yerinde solarak gelir.
    for (auto& tile : tiles_) tile.flies = tile.flies && viewport_.intersects(tile.target);
}

/// Üst kenar yalnızca kaydırılmışken kırpılır: açılışta pencereler şeridin hizasından da uçar.
Rect App::clipRect() const {
    double top = scrollOffset_ > 0 ? viewport_.y : 0;
    return {0, top, double(width_), viewport_.bottom() - top};
}

void App::applyScroll() {
    for (auto& tile : tiles_) tile.target = shifted(tile.page);
    for (auto& hit : hits_) if (hit.scrolls) hit.rect = shifted(hit.page);
}

void App::scrollChanged() {
    applyScroll();
    for (auto& tile : tiles_) placeThumbnail(tile, tile.target, matches(tile.window) ? 255 : 45);
    renderBack();
    renderFront();
}

void App::scrollTo(double value) {
    double next = std::min(std::max(value, 0.0), maxScroll_);
    if (next == scrollTarget_) return;
    scrollTarget_ = next;
    SetTimer(control_, kScrollTimer, 15, nullptr);
}

void App::stepScroll() {
    double remaining = scrollTarget_ - scrollOffset_;
    bool done = std::abs(remaining) < 0.75;
    scrollOffset_ = done ? scrollTarget_ : scrollOffset_ + remaining * 0.32;
    if (done) KillTimer(control_, kScrollTimer);
    scrollChanged();
}

/// Klavyeyle ya da aramayla seçilen pencere görünür alana gelir; alttaki etiket satırı da görünsün.
void App::scrollIntoView(const Tile& tile) {
    if (maxScroll_ <= 0) return;
    const double margin = 12 * scale_, label = 32 * scale_;
    double top = tile.page.y - scrollTarget_, bottom = tile.page.bottom() - scrollTarget_ + label;
    if (bottom > viewport_.bottom() - margin) scrollTo(scrollTarget_ + bottom - (viewport_.bottom() - margin));
    else if (top < viewport_.y + margin) scrollTo(scrollTarget_ - (viewport_.y + margin - top));
}

/// Sıralanabilecek sabit hücre. Arama açıkken sıralama olmaz.
int App::pinAt(int x, int y) const {
    if (!query_.empty() || pinnedSlots_.size() < 2 || !viewport_.contains(x, y)) return -1;
    for (size_t i = 0; i < pinnedSlots_.size(); ++i)
        if (pinnedSlots_[i].frame.contains(x, y + scrollOffset_)) return int(i);
    return -1;
}

bool App::onHoveredTile(int x, int y) const {
    return hover_ >= 0 && hover_ < int(hits_.size()) && hits_[hover_].kind == HitKind::Window &&
           viewport_.contains(x, y) && tiles_[hits_[hover_].index].target.contains(x, y);
}

/// Sırası değişen hücreler eski yerlerinden kayarak gelir.
void App::reorderPin(size_t pin, size_t gap) {
    std::map<HWND, Rect> previous;
    for (const auto& tile : tiles_) previous[tile.window.hwnd] = tile.target;
    moveToGap(pins_, pin, gap);
    savePins(pins_);
    refreshScene();
    for (auto& tile : tiles_) {
        auto found = previous.find(tile.window.hwnd);
        tile.start = found != previous.end() ? found->second : tile.target;
        tile.flies = true;
    }
    animationStart_ = GetTickCount64();
    SetTimer(control_, kAnimationTimer, 15, nullptr);
}

#ifdef DEBUG
ID2D1Bitmap* App::skeletonFor(ID2D1RenderTarget* rt, HWND hwnd) {
    auto found = skeletons_.find(hwnd);
    if (found != skeletons_.end()) return found->second.Get();
    ComPtr<ID2D1Bitmap> bitmap;
    demo::Image image = demo::skeleton(hwnd);
    if (image.width > 0) {
        D2D1_BITMAP_PROPERTIES props{D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96};
        rt->CreateBitmap(D2D1::SizeU(image.width, image.height), image.pixels.data(), image.width * 4, props, bitmap.GetAddressOf());
    }
    skeletons_[hwnd] = bitmap;
    return bitmap.Get();
}
#endif

void App::clearStripThumbnails() {
    for (HTHUMBNAIL t : stripThumbs_) DwmUnregisterThumbnail(t);
    stripThumbs_.clear();
}

/// Şeritteki masaüstü kartlarına o masaüstündeki pencerelerin gerçek önizlemesi konur. Windows
/// diğer masaüstlerinin görüntüsünü vermiyor, ama DWM önizlemesi gizli masaüstündeki pencerede de
/// çalışıyor (ölçüldü): kart, pencerelerin küçültülmüş önizlemeleri üst üste dizilerek kurulur.
/// Önce kaydedilen alta çizilir; yığın önizlemeleri sonra kaydedildiği için şeridin üstünde kalır.
void App::registerThumbnails() {
    clearStripThumbnails();
#ifdef DEBUG
    if (demo::skeletons()) return;
#endif
    for (const auto& [rect, desktop] : strip_) {
        std::vector<const SceneWindow*> inDesktop;
        for (const auto& [id, app] : snapshot_.apps)
            for (const auto& w : app.windows)
                if (w.hasDesktop && IsEqualGUID(w.desktop, desktop.id) && !w.minimized) inDesktop.push_back(&w);
        std::sort(inDesktop.begin(), inDesktop.end(), [](auto* a, auto* b) { return a->zRank > b->zRank; });
        double sx = rect.w / width_, sy = rect.h / height_;
        for (const auto* w : inDesktop) {
            // Sahnenin ekranı dışında kalan kısım kırpılır.
            RECT visible;
            if (!IntersectRect(&visible, &w->frame, &area_)) continue;
            HTHUMBNAIL thumb = nullptr;
            if (FAILED(DwmRegisterThumbnail(back_, w->hwnd, &thumb))) continue;
            RECT outer{};
            GetWindowRect(w->hwnd, &outer);
            DWM_THUMBNAIL_PROPERTIES p{};
            p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_RECTSOURCE | DWM_TNP_VISIBLE | DWM_TNP_SOURCECLIENTAREAONLY | DWM_TNP_OPACITY;
            p.rcSource = {visible.left - outer.left, visible.top - outer.top, visible.right - outer.left, visible.bottom - outer.top};
            p.rcDestination = {LONG(rect.x + (visible.left - area_.left) * sx), LONG(rect.y + (visible.top - area_.top) * sy),
                               LONG(rect.x + (visible.right - area_.left) * sx), LONG(rect.y + (visible.bottom - area_.top) * sy)};
            p.fVisible = TRUE;
            p.opacity = 255;
            p.fSourceClientAreaOnly = FALSE;
            DwmUpdateThumbnailProperties(thumb, &p);
            stripThumbs_.push_back(thumb);
        }
    }
    for (auto& tile : tiles_) {
        if (FAILED(DwmRegisterThumbnail(back_, tile.window.hwnd, &tile.thumb))) tile.thumb = nullptr;
    }
}

void App::placeThumbnail(Tile& tile, const Rect& rect, BYTE opacity, bool clip) {
    if (!tile.thumb) return;
    if (!tile.source.cy) DwmQueryThumbnailSourceSize(tile.thumb, &tile.source);
    DWM_THUMBNAIL_PROPERTIES p{};
    p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY | DWM_TNP_SOURCECLIENTAREAONLY;
    Rect r = rect;
    // DWM önizlemesi pencerenin üstünde çizilir, kırpma yok: görünmeyen kısım kaynaktan kesilir.
    if (tile.source.cy) {
        p.dwFlags |= DWM_TNP_RECTSOURCE;
        p.rcSource = {0, 0, tile.source.cx, tile.source.cy};
        if (clip) {
            const Rect c = clipRect();
            double top = std::max(rect.y, c.y), bottom = std::min(rect.bottom(), c.bottom());
            if (bottom <= top) {
                p.dwFlags = DWM_TNP_VISIBLE;
                p.fVisible = FALSE;
                DwmUpdateThumbnailProperties(tile.thumb, &p);
                return;
            }
            double perPixel = tile.source.cy / rect.h;
            p.rcSource.top = LONG((top - rect.y) * perPixel);
            p.rcSource.bottom = LONG((bottom - rect.y) * perPixel);
            r.y = top;
            r.h = bottom - top;
        }
    }
    p.rcDestination = {LONG(r.x), LONG(r.y), LONG(r.right()), LONG(r.bottom())};
    p.fVisible = TRUE;
    p.opacity = opacity;
    p.fSourceClientAreaOnly = FALSE;
    DwmUpdateThumbnailProperties(tile.thumb, &p);
}

void App::stepAnimation() {
    double t = double(GetTickCount64() - animationStart_) / kAnimationMs;
    bool done = t >= 1;
    if (done) t = 1;
    // Mac'teki eğri: hızlı başlar, yumuşak oturur.
    double e = 1 - std::pow(1 - t, 3);
    for (auto& tile : tiles_) {
        if (tile.flies) {
            Rect r{tile.start.x + (tile.target.x - tile.start.x) * e, tile.start.y + (tile.target.y - tile.start.y) * e,
                   tile.start.w + (tile.target.w - tile.start.w) * e, tile.start.h + (tile.target.h - tile.start.h) * e};
            placeThumbnail(tile, r, 255, false);
        } else {
            placeThumbnail(tile, tile.target, BYTE(255 * e));
        }
    }
    if (done) KillTimer(control_, kAnimationTimer);
}

void App::loadWallpaper() {
    wallpaperSource_.Reset();
    wchar_t path[MAX_PATH]{};
    if (!SystemParametersInfoW(SPI_GETDESKWALLPAPER, MAX_PATH, path, 0) || !path[0] || !wic_) return;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(wic_->CreateDecoderFromFilename(path, nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, decoder.GetAddressOf()))) return;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, frame.GetAddressOf()))) return;
    ComPtr<IWICFormatConverter> converter;
    wic_->CreateFormatConverter(converter.GetAddressOf());
    if (SUCCEEDED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeMedianCut)))
        wallpaperSource_ = converter;
}

ID2D1Bitmap* App::iconFor(ID2D1RenderTarget* rt, const std::wstring& path, std::map<std::wstring, ComPtr<ID2D1Bitmap>>& cache) {
    auto found = cache.find(path);
    if (found != cache.end()) return found->second.Get();
    ComPtr<ID2D1Bitmap> bitmap;
    SHFILEINFOW info{};
    if (SHGetFileInfoW(path.c_str(), 0, &info, sizeof info, SHGFI_ICON | SHGFI_LARGEICON) && info.hIcon && wic_) {
        ComPtr<IWICBitmap> source;
        if (SUCCEEDED(wic_->CreateBitmapFromHICON(info.hIcon, source.GetAddressOf()))) {
            ComPtr<IWICFormatConverter> converter;
            wic_->CreateFormatConverter(converter.GetAddressOf());
            if (SUCCEEDED(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeMedianCut)))
                rt->CreateBitmapFromWicBitmap(converter.Get(), bitmap.GetAddressOf());
        }
        DestroyIcon(info.hIcon);
    }
    cache[path] = bitmap;
    return bitmap.Get();
}

void App::drawText(ID2D1RenderTarget* rt, const std::wstring& text, const Rect& rect, IDWriteTextFormat* format, ID2D1Brush* brush, bool shadow) {
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(dwrite_->CreateTextLayout(text.c_str(), UINT32(text.size()), format, float(rect.w), float(rect.h), layout.GetAddressOf()))) return;
    if (shadow) {
        ComPtr<ID2D1SolidColorBrush> dark;
        rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0.55f), dark.GetAddressOf());
        rt->DrawTextLayout(D2D1::Point2F(float(rect.x), float(rect.y + scale_)), layout.Get(), dark.Get());
    }
    rt->DrawTextLayout(D2D1::Point2F(float(rect.x), float(rect.y)), layout.Get(), brush);
}

void App::renderBack() {
    ID2D1HwndRenderTarget* rt = backTarget_.Get();
    if (!rt) return;
    // Çipler çizilirken konumları ölçülür; yeniden çizimde iki kez eklenmesin.
    hits_.erase(std::remove_if(hits_.begin(), hits_.end(), [](const Hit& h) { return h.kind == HitKind::Chip; }), hits_.end());
    rt->BeginDraw();
    rt->Clear(D2D1::ColorF(0.12f, 0.12f, 0.13f));
    const double s = scale_;
    const float screenW = float(width_), screenH = float(height_);

    ComPtr<ID2D1DeviceContext> dc;
    rt->QueryInterface(IID_PPV_ARGS(&dc));
    if (wallpaperSource_ && dc && !blurredBackdrop_) {
        if (!wallpaperBitmap_) dc->CreateBitmapFromWicBitmap(wallpaperSource_.Get(), wallpaperBitmap_.GetAddressOf());
        ID2D1Bitmap* wallpaper = wallpaperBitmap_.Get();
        ComPtr<ID2D1BitmapRenderTarget> layer;
        ComPtr<ID2D1DeviceContext> layerContext;
        if (wallpaper && SUCCEEDED(rt->CreateCompatibleRenderTarget(D2D1::SizeF(screenW, screenH), layer.GetAddressOf())) &&
            SUCCEEDED(layer->QueryInterface(IID_PPV_ARGS(&layerContext)))) {
            ComPtr<ID2D1Effect> blur;
            if (SUCCEEDED(layerContext->CreateEffect(CLSID_D2D1GaussianBlur, blur.GetAddressOf()))) {
                blur->SetInput(0, wallpaper);
                blur->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION, float(22 * s));
                blur->SetValue(D2D1_GAUSSIANBLUR_PROP_BORDER_MODE, D2D1_BORDER_MODE_HARD);
                D2D1_SIZE_F size = wallpaper->GetSize();
                // Ekranı doldur: duvar kağıdı en-boy oranı korunur.
                float zoom = std::max(screenW / size.width, screenH / size.height);
                layerContext->BeginDraw();
                layerContext->SetTransform(D2D1::Matrix3x2F::Scale(zoom, zoom) *
                                           D2D1::Matrix3x2F::Translation((screenW - size.width * zoom) / 2, (screenH - size.height * zoom) / 2));
                layerContext->DrawImage(blur.Get());
                layerContext->SetTransform(D2D1::Matrix3x2F::Identity());
                layerContext->EndDraw();
                layer->GetBitmap(blurredBackdrop_.GetAddressOf());
            }
        }
    }
    if (blurredBackdrop_) rt->DrawBitmap(blurredBackdrop_.Get(), D2D1::RectF(0, 0, screenW, screenH));

    ComPtr<ID2D1SolidColorBrush> white, soft, faint, dim, accent, line;
    rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), white.GetAddressOf());
    rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.72f), soft.GetAddressOf());
    rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.14f), faint.GetAddressOf());
    rt->CreateSolidColorBrush(D2D1::ColorF(0.08f, 0.05f, 0.04f, 0.28f), dim.GetAddressOf());
    rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.45f), line.GetAddressOf());
    DWORD color = 0;
    BOOL opaque = FALSE;
    DwmGetColorizationColor(&color, &opaque);
    rt->CreateSolidColorBrush(D2D1::ColorF(float((color >> 16) & 255) / 255, float((color >> 8) & 255) / 255, float(color & 255) / 255), accent.GetAddressOf());
    rt->FillRectangle(D2D1::RectF(0, 0, screenW, screenH), dim.Get());

    // Masaüstü şeridi
    int desktopNumber = 0;
    for (const auto& [rect, desktop] : strip_) {
        ++desktopNumber;
        D2D1_ROUNDED_RECT round{toD2D(rect), float(7 * s), float(7 * s)};
        rt->FillRoundedRectangle(round, faint.Get());
        // Bu masaüstündeki pencerelerin yeri: gerçek önizleme yerine sade kutular.
        double sx = rect.w / width_, sy = rect.h / height_;
        std::vector<const SceneWindow*> inDesktop;
        for (const auto& [id, app] : snapshot_.apps)
            for (const auto& w : app.windows)
                if (w.hasDesktop && IsEqualGUID(w.desktop, desktop.id) && !w.minimized) inDesktop.push_back(&w);
        std::sort(inDesktop.begin(), inDesktop.end(), [](auto* a, auto* b) { return a->zRank > b->zRank; });
        rt->PushAxisAlignedClip(toD2D(rect), D2D1_ANTIALIAS_MODE_ALIASED);
        // Kartın zemini duvar kağıdı; pencere önizlemeleri DWM ile üstüne biner.
        if (ID2D1Bitmap* wallpaper = wallpaperBitmap_.Get()) {
            D2D1_SIZE_F size = wallpaper->GetSize();
            float zoom = std::max(float(rect.w) / size.width, float(rect.h) / size.height);
            float w = size.width * zoom, h = size.height * zoom;
            rt->DrawBitmap(wallpaper, D2D1::RectF(float(rect.midX() - w / 2), float(rect.midY() - h / 2), float(rect.midX() + w / 2), float(rect.midY() + h / 2)));
        }
        for (const auto* w : inDesktop) {
            Rect r{rect.x + (w->frame.left - area_.left) * sx, rect.y + (w->frame.top - area_.top) * sy,
                   (w->frame.right - w->frame.left) * sx, (w->frame.bottom - w->frame.top) * sy};
            rt->FillRectangle(toD2D(r), line.Get());
            rt->DrawRectangle(toD2D(r), faint.Get(), float(s));
        }
        rt->PopAxisAlignedClip();
        if (desktop.current) rt->DrawRoundedRectangle(round, accent.Get(), float(2 * s));
        else rt->DrawRoundedRectangle(round, line.Get(), float(0.5 * s));

        std::wstring name = desktop.name.empty() ? (tx(L"Masa\u00FCst\u00FC ", L"Desktop ") + std::to_wstring(desktopNumber)) : desktop.name;
        if (strip_.size() == 1 && desktop.name.empty()) name = tx(L"Masa\u00FCst\u00FC", L"Desktop");
        ComPtr<IDWriteTextLayout> layout;
        dwrite_->CreateTextLayout(name.c_str(), UINT32(name.size()), smallFormat_.Get(), float(rect.w + 12 * s), float(18 * s), layout.GetAddressOf());
        layout->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        rt->DrawTextLayout(D2D1::Point2F(float(rect.x - 6 * s), float(rect.bottom() + 3 * s)), layout.Get(), white.Get());
    }

    // Arama kutusu. Uygulama paneli açıkken arama satırı panelin içindedir; arkada ikincisi görünmesin.
    if (appResults_.empty() || query_.empty()) {
        const Rect& r = hintRect_;
        double h = r.h;
        bool typing = searchFocused_ || !query_.empty();
        rt->FillRoundedRectangle(D2D1::RoundedRect(toD2D(r), float(h / 2), float(h / 2)), faint.Get());
        if (!typing) {
            std::wstring text = tx(L"Aramak i\u00E7in yazmaya ba\u015Flay\u0131n", L"Start typing to search");
            ComPtr<IDWriteTextLayout> layout;
            dwrite_->CreateTextLayout(text.c_str(), UINT32(text.size()), hintFormat_.Get(), float(r.w), float(h), layout.GetAddressOf());
            layout->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
            rt->DrawTextLayout(D2D1::Point2F(float(r.x), float(r.y)), layout.Get(), soft.Get());
        } else {
            rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(r), float(h / 2), float(h / 2)), accent.Get(), float(s));
            // Büyüteç
            float gx = float(r.x + 18 * s), gy = float(r.midY() - 1 * s), gr = float(5.5 * s);
            rt->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(gx, gy), gr, gr), soft.Get(), float(1.6 * s));
            rt->DrawLine(D2D1::Point2F(gx + gr * 0.7f, gy + gr * 0.7f), D2D1::Point2F(gx + gr * 1.6f, gy + gr * 1.6f), soft.Get(), float(1.6 * s));
            std::wstring text = query_.empty() ? std::wstring(tx(L"Uygulama ya da pencere ara", L"Search apps and windows")) : query_;
            double textX = r.x + 34 * s, textW = r.w - 48 * s;
            ComPtr<IDWriteTextLayout> layout;
            dwrite_->CreateTextLayout(text.c_str(), UINT32(text.size()), hintFormat_.Get(), float(textW), float(h), layout.GetAddressOf());
            DWRITE_TEXT_METRICS m{};
            layout->GetMetrics(&m);
            if (selectAll_ && !query_.empty()) {
                ComPtr<ID2D1SolidColorBrush> selection;
                rt->CreateSolidColorBrush(D2D1::ColorF(0.0f, 0.47f, 0.84f, 0.75f), selection.GetAddressOf());
                double selW = std::min<double>(m.widthIncludingTrailingWhitespace, textW);
                rt->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(float(textX - 2 * s), float(r.midY() - 10 * s), float(textX + selW + 2 * s), float(r.midY() + 10 * s)), float(3 * s), float(3 * s)), selection.Get());
            }
            rt->DrawTextLayout(D2D1::Point2F(float(textX), float(r.y)), layout.Get(), query_.empty() ? soft.Get() : white.Get());
            if (!selectAll_ || query_.empty()) {
            double caretX = query_.empty() ? textX : textX + std::min<double>(m.widthIncludingTrailingWhitespace, textW) + 1 * s;
            rt->DrawLine(D2D1::Point2F(float(caretX), float(r.midY() - 9 * s)), D2D1::Point2F(float(caretX), float(r.midY() + 9 * s)), white.Get(), float(1.5 * s));
            }
        }
    }

    // Yeni masaüstü
    if (!strip_.empty()) {
        D2D1_ROUNDED_RECT round{toD2D(newDesktopRect_), float(7 * s), float(7 * s)};
        rt->FillRoundedRectangle(round, faint.Get());
        rt->DrawRoundedRectangle(round, line.Get(), float(0.5 * s));
        float cx = float(newDesktopRect_.midX()), cy = float(newDesktopRect_.midY()), arm = float(9 * s);
        rt->DrawLine(D2D1::Point2F(cx - arm, cy), D2D1::Point2F(cx + arm, cy), soft.Get(), float(2 * s));
        rt->DrawLine(D2D1::Point2F(cx, cy - arm), D2D1::Point2F(cx, cy + arm), soft.Get(), float(2 * s));
    }

    // Hücre etiketleri ve boş yuvalar
    ComPtr<ID2D1StrokeStyle> dash;
    float dashes[] = {4, 3};
    d2d_->CreateStrokeStyle(D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_LINE_JOIN_MITER, 10, D2D1_DASH_STYLE_CUSTOM, 0), dashes, 2, dash.GetAddressOf());

    // Sayfa: şeridin ve aramanın altında kayar.
    rt->PushAxisAlignedClip(toD2D(clipRect()), D2D1_ANTIALIAS_MODE_ALIASED);
#ifdef DEBUG
    if (demo::skeletons()) {
        for (const auto& tile : tiles_) {
            if (auto* bitmap = skeletonFor(rt, tile.window.hwnd))
                rt->DrawBitmap(bitmap, toD2D(tile.target), matches(tile.window) ? 1.0f : 0.18f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
        }
    }
#endif

    for (const auto& hit : hits_) {
        if (hit.kind != HitKind::EmptySlot) continue;
        rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(hit.rect), float(10 * s), float(10 * s)), line.Get(), float(s), dash.Get());
        const auto& pin = pins_[hit.index];
        if (auto* icon = iconFor(rt, pin.path, backIcons_)) {
            double side = std::min(48 * s, hit.rect.h * 0.45);
            rt->DrawBitmap(icon, D2D1::RectF(float(hit.rect.midX() - side / 2), float(hit.rect.midY() - side / 2), float(hit.rect.midX() + side / 2), float(hit.rect.midY() + side / 2)), 0.6f);
        }
    }

    auto drawLabel = [&](const PlacedSlot& placedSlot, const std::wstring& name, const std::wstring& path, bool hasWindows) {
        const PlacedSlot slot{placedSlot.id, placedSlot.size, shifted(placedSlot.frame), shifted(placedSlot.pile)};
        ComPtr<IDWriteTextLayout> layout;
        double maxWidth = slot.frame.w - 30 * s;
        dwrite_->CreateTextLayout(name.c_str(), UINT32(name.size()), labelFormat_.Get(), float(maxWidth), float(24 * s), layout.GetAddressOf());
        DWRITE_TEXT_METRICS m{};
        layout->GetMetrics(&m);
        double iconSize = 22 * s;
        double total = iconSize + 6 * s + m.width;
        double x = slot.frame.midX() - total / 2;
        double cy = slot.pile.bottom() + (slot.frame.bottom() - slot.pile.bottom()) / 2;
        if (auto* icon = iconFor(rt, path, backIcons_))
            rt->DrawBitmap(icon, D2D1::RectF(float(x), float(cy - iconSize / 2), float(x + iconSize), float(cy + iconSize / 2)));
        drawText(rt, name, {x + iconSize + 6 * s, cy - 12 * s, maxWidth, 24 * s}, labelFormat_.Get(), hasWindows ? white.Get() : soft.Get(), true);
    };
    for (const auto& pin : pins_) {
        auto slotIt = placed_.find(pin.id);
        if (slotIt == placed_.end()) continue;
        auto appIt = snapshot_.apps.find(pin.id);
        bool hasWindows = appIt != snapshot_.apps.end() && !appIt->second.windows.empty();
        bool running = appIt != snapshot_.apps.end();
        std::wstring name = (running ? appIt->second.name : pin.name);
        if (!hasWindows) name += running ? tx(L" \u00B7 pencere yok", L" \u00B7 no windows") : tx(L" \u00B7 kapal\u0131", L" \u00B7 not running");
        drawLabel(slotIt->second, name, pin.path, hasWindows);
    }
    for (const auto& id : otherApps_) {
        auto slotIt = placed_.find(id);
        if (slotIt != placed_.end()) drawLabel(slotIt->second, snapshot_.apps[id].name, snapshot_.apps[id].path, true);
    }

    // Diğer açık uygulamalar
    if (!otherApps_.empty()) {
        const double chipH = 32 * s;
        double chipsY = height_ - chipH - 12 * s - scrollOffset_;
        if (settings_.otherAppsScroll) {
            drawText(rt, tx(L"Di\u011Fer a\u00E7\u0131k uygulamalar \u00B7 pencereler i\u00E7in kayd\u0131r\u0131n", L"Other open apps \u00B7 scroll for windows"),
                     {36 * s, chipsY - 26 * s, 420 * s, 20 * s}, smallFormat_.Get(), soft.Get(), true);
        }
        std::vector<double> widths;
        double total = 0;
        for (const auto& id : otherApps_) {
            const auto& app = snapshot_.apps[id];
            std::wstring text = app.windows.size() > 1 ? app.name + L" \u00B7 " + std::to_wstring(app.windows.size()) : app.name;
            ComPtr<IDWriteTextLayout> layout;
            dwrite_->CreateTextLayout(text.c_str(), UINT32(text.size()), smallFormat_.Get(), float(300 * s), float(chipH), layout.GetAddressOf());
            DWRITE_TEXT_METRICS m{};
            layout->GetMetrics(&m);
            double w = 8 * s + 20 * s + 6 * s + std::min(double(m.width), 240 * s) + 12 * s;
            widths.push_back(w);
            total += w + 8 * s;
        }
        bool iconOnly = total > width_ - 72 * s;
        if (iconOnly) {
            total = 0;
            for (auto& w : widths) { w = 34 * s; total += w + 8 * s; }
        }
        double x = width_ / 2.0 - (total - 8 * s) / 2;
        for (size_t i = 0; i < otherApps_.size(); ++i) {
            const auto& app = snapshot_.apps[otherApps_[i]];
            Rect r{x, chipsY, widths[i], chipH};
            rt->FillRoundedRectangle(D2D1::RoundedRect(toD2D(r), float(chipH / 2), float(chipH / 2)), faint.Get());
            rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(r), float(chipH / 2), float(chipH / 2)), line.Get(), float(0.5 * s));
            if (auto* icon = iconFor(rt, app.path, backIcons_))
                rt->DrawBitmap(icon, D2D1::RectF(float(x + 7 * s), float(chipsY + 6 * s), float(x + 27 * s), float(chipsY + 26 * s)));
            if (!iconOnly) {
                std::wstring text = app.windows.size() > 1 ? app.name + L" \u00B7 " + std::to_wstring(app.windows.size()) : app.name;
                drawText(rt, text, {x + 33 * s, chipsY, widths[i] - 40 * s, chipH}, smallFormat_.Get(), white.Get(), false);
            }
            hits_.push_back({r, HitKind::Chip, i, true, {r.x, r.y + scrollOffset_, r.w, r.h}});
            x += widths[i] + 8 * s;
        }
    }
    rt->PopAxisAlignedClip();
    rt->EndDraw();
}

void App::renderFront() {
    // Tüm ekran yarı saydam olmayan bir tuval: fare olayları için alfa en az 1.
    BITMAPINFO bi{};
    bi.bmiHeader = {sizeof(BITMAPINFOHEADER), width_, -height_, 1, 32, BI_RGB};
    void* bits = nullptr;
    HDC screen = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP dib = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ old = SelectObject(mem, dib);

    ComPtr<ID2D1DCRenderTarget> rt;
    auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    if (SUCCEEDED(d2d_->CreateDCRenderTarget(&props, rt.GetAddressOf()))) {
        RECT all{0, 0, width_, height_};
        rt->BindDC(mem, &all);
        rt->BeginDraw();
        rt->Clear(D2D1::ColorF(0, 0, 0, 1.0f / 255));
        const double s = scale_;
        ComPtr<ID2D1SolidColorBrush> white, pill, accent;
        rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1), white.GetAddressOf());
        rt->CreateSolidColorBrush(D2D1::ColorF(0.05f, 0.05f, 0.05f, 0.72f), pill.GetAddressOf());
        DWORD color = 0;
        BOOL opaque = FALSE;
        DwmGetColorizationColor(&color, &opaque);
        rt->CreateSolidColorBrush(D2D1::ColorF(float((color >> 16) & 255) / 255, float((color >> 8) & 255) / 255, float(color & 255) / 255), accent.GetAddressOf());

        // Hangi masaüstünde olduğu
        const Rect clip = clipRect();
        rt->PushAxisAlignedClip(toD2D(clip), D2D1_ANTIALIAS_MODE_ALIASED);
        for (const auto& tile : tiles_) {
            if (tile.target.w < 80 * s || !clip.intersects(tile.target)) continue;
            // Sürüklenen önizleme yerinden kalktı: rozeti boşlukta kalmasın.
            if (drag_ == DragKind::Tile && &tile == &tiles_[dragTile_]) continue;
            std::wstring badge;
            if (tile.window.minimized) {
                badge = tx(L"K\u00FC\u00E7\u00FCltülmüş", L"Minimized");
            } else {
                int number = 0;
                for (size_t i = 0; i < snapshot_.desktops.size(); ++i)
                    if (tile.window.hasDesktop && IsEqualGUID(snapshot_.desktops[i].id, tile.window.desktop)) {
                        number = int(i) + 1;
                        badge = snapshot_.desktops[i].name;
                    }
                if (badge.empty()) badge = snapshot_.desktops.size() > 1 && number ? tx(L"Masa\u00FCst\u00FC ", L"Desktop ") + std::to_wstring(number) : std::wstring(tx(L"Masa\u00FCst\u00FC", L"Desktop"));
                // Birden çok ekranda, sahnenin açık olmadığı ekrandaki pencereye ekran numarası eklenir.
                if (GetSystemMetrics(SM_CMONITORS) > 1) {
                    HMONITOR own = MonitorFromRect(&tile.window.frame, MONITOR_DEFAULTTONEAREST);
                    if (own != sceneMonitor_) {
                        struct Find { HMONITOR target; int index = 0, found = 0; } find{own};
                        EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR m, HDC, LPRECT, LPARAM l) -> BOOL {
                            auto* f = reinterpret_cast<Find*>(l);
                            ++f->index;
                            if (m == f->target) { f->found = f->index; return FALSE; }
                            return TRUE;
                        }, reinterpret_cast<LPARAM>(&find));
                        badge = tx(L"Ekran ", L"Display ") + std::to_wstring(find.found) + L" \u00B7 " + badge;
                    }
                }
            }
            ComPtr<IDWriteTextLayout> layout;
            dwrite_->CreateTextLayout(badge.c_str(), UINT32(badge.size()), smallFormat_.Get(), float(tile.target.w - 20 * s), float(18 * s), layout.GetAddressOf());
            DWRITE_TEXT_METRICS m{};
            layout->GetMetrics(&m);
            Rect r{tile.target.x + 6 * s, tile.target.bottom() - 25 * s, m.width + 14 * s, 19 * s};
            rt->FillRoundedRectangle(D2D1::RoundedRect(toD2D(r), float(r.h / 2), float(r.h / 2)), pill.Get());
            rt->DrawTextLayout(D2D1::Point2F(float(r.x + 7 * s), float(r.y)), layout.Get(), white.Get());
        }
        rt->PopAxisAlignedClip();

        // Üstüne gelinen pencere
        if (hover_ >= 0 && hover_ < int(hits_.size()) && hits_[hover_].kind == HitKind::Window) {
            const auto& tile = tiles_[hits_[hover_].index];
            Rect r{tile.target.x - 3 * s, tile.target.y - 3 * s, tile.target.w + 6 * s, tile.target.h + 6 * s};
            rt->PushAxisAlignedClip(toD2D(clip), D2D1_ANTIALIAS_MODE_ALIASED);
            rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(r), float(9 * s), float(9 * s)), accent.Get(), float(2.5 * s));
            rt->PopAxisAlignedClip();
            std::wstring title = tile.window.title;
#ifdef DEBUG
            if (demo::skeletons()) title = snapshot_.apps[tile.window.appId].name;
#endif
            ComPtr<IDWriteTextLayout> layout;
            dwrite_->CreateTextLayout(title.c_str(), UINT32(title.size()), smallFormat_.Get(), float(420 * s), float(26 * s), layout.GetAddressOf());
            DWRITE_TEXT_METRICS m{};
            layout->GetMetrics(&m);
            double w = m.width + 22 * s, h = 26 * s;
            double x = std::min(std::max(tile.target.midX() - w / 2, 12 * s), width_ - w - 12 * s);
            double y = std::max(tile.target.y - h - 8 * s, 8 * s);
            rt->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(float(x), float(y), float(x + w), float(y + h)), float(h / 2), float(h / 2)), pill.Get());
            rt->DrawTextLayout(D2D1::Point2F(float(x + 11 * s), float(y)), layout.Get(), white.Get());

            // Köşe düğmeleri
            if (drag_ == DragKind::None && clip.contains(tile.target.right() - 1, tile.target.y + 9 * s)) {
                Rect first = actionRect(tile, 0), last = actionRect(tile, kActionCount - 1);
                Rect bar{first.x - 3 * s, first.y - 3 * s, last.right() - first.x + 6 * s, first.h + 6 * s};
                ComPtr<ID2D1SolidColorBrush> barBrush, hot, red;
                rt->CreateSolidColorBrush(D2D1::ColorF(0.08f, 0.08f, 0.08f, 0.82f), barBrush.GetAddressOf());
                rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.26f), hot.GetAddressOf());
                rt->CreateSolidColorBrush(D2D1::ColorF(0.9f, 0.2f, 0.2f), red.GetAddressOf());
                rt->FillRoundedRectangle(D2D1::RoundedRect(toD2D(bar), float(bar.h / 2), float(bar.h / 2)), barBrush.Get());
                for (int i = 0; i < kActionCount; ++i) {
                    Rect b = actionRect(tile, i);
                    if (hoverAction_ == i)
                        rt->FillRoundedRectangle(D2D1::RoundedRect(toD2D(b), float(b.w / 2), float(b.w / 2)), i == kCloseAction ? red.Get() : hot.Get());
                    float cx = float(b.midX()), cy = float(b.midY()), a = float(7 * s), t = float(5 * s);
                    if (i == 3) {
                        rt->DrawLine(D2D1::Point2F(cx - t, cy), D2D1::Point2F(cx + t, cy), white.Get(), float(1.6 * s));
                    } else if (i == kCloseAction) {
                        rt->DrawLine(D2D1::Point2F(cx - t, cy - t), D2D1::Point2F(cx + t, cy + t), white.Get(), float(1.6 * s));
                        rt->DrawLine(D2D1::Point2F(cx + t, cy - t), D2D1::Point2F(cx - t, cy + t), white.Get(), float(1.6 * s));
                    } else {
                        D2D1_RECT_F box = D2D1::RectF(cx - a, cy - t, cx + a, cy + t);
                        if (i == 2) {
                            rt->FillRectangle(box, white.Get());
                        } else {
                            rt->DrawRectangle(box, white.Get(), float(1.2 * s));
                            rt->FillRectangle(i == 0 ? D2D1::RectF(cx - a, cy - t, cx, cy + t) : D2D1::RectF(cx, cy - t, cx + a, cy + t), white.Get());
                        }
                    }
                }
            }
        }

        // Arama altında, sahnede olmayan uygulamalar: önizlemelerin üstünde, yerleşimi değiştirmeden.
        hits_.erase(std::remove_if(hits_.begin(), hits_.end(), [](const Hit& h) { return h.kind == HitKind::Launch; }), hits_.end());
        if (hover_ >= int(hits_.size())) hover_ = -1;
        if (!appResults_.empty() && drag_ == DragKind::None && !query_.empty()) {
            // Yazınca arama kutusu tek panele dönüşür: arama satırı kutunun tam yerinde, altında simge
            // ızgarası. Sahnenin malzemesiyle: yarı saydam koyu cam, ince açık kenar, beyaz yazı.
            const size_t columns = std::min<size_t>(7, appResults_.size()), rows = (appResults_.size() + columns - 1) / columns;
            const double cellW = 104 * s, cellH = 100 * s, pad = 14 * s, gap = 12 * s, searchH = hintRect_.h;
            const double w = std::max(hintRect_.w, columns * cellW + pad * 2);
            Rect panel{width_ / 2.0 - w / 2, hintRect_.y, w, searchH + gap * 2 + rows * cellH};
            ComPtr<ID2D1SolidColorBrush> panelBrush, edge, ink, soft, mark;
            rt->CreateSolidColorBrush(D2D1::ColorF(0.07f, 0.07f, 0.07f, 0.8f), panelBrush.GetAddressOf());
            rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.2f), edge.GetAddressOf());
            rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1), ink.GetAddressOf());
            rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.6f), soft.GetAddressOf());
            rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 0.16f), mark.GetAddressOf());
            const float radius = float(18 * s);
            rt->FillRoundedRectangle(D2D1::RoundedRect(toD2D(panel), radius, radius), panelBrush.Get());
            rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(panel), radius, radius), edge.Get(), float(s));

            // Arama satırı: kutudakiyle aynı büyüteç, yazı ve imleç.
            float gx = float(panel.x + 18 * s), gy = float(panel.y + searchH / 2 - 1 * s), gr = float(5.5 * s);
            rt->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(gx, gy), gr, gr), soft.Get(), float(1.6 * s));
            rt->DrawLine(D2D1::Point2F(gx + gr * 0.7f, gy + gr * 0.7f), D2D1::Point2F(gx + gr * 1.6f, gy + gr * 1.6f), soft.Get(), float(1.6 * s));
            {
                double textX = panel.x + 34 * s, textW = panel.w - 48 * s;
                ComPtr<IDWriteTextLayout> layout;
                dwrite_->CreateTextLayout(query_.c_str(), UINT32(query_.size()), hintFormat_.Get(), float(textW), float(searchH), layout.GetAddressOf());
                if (layout) {
                    DWRITE_TEXT_METRICS m{};
                    layout->GetMetrics(&m);
                    double typedW = std::min<double>(m.widthIncludingTrailingWhitespace, textW);
                    float midY = float(panel.y + searchH / 2);
                    if (selectAll_) {
                        ComPtr<ID2D1SolidColorBrush> selection;
                        rt->CreateSolidColorBrush(D2D1::ColorF(0.0f, 0.47f, 0.84f, 0.75f), selection.GetAddressOf());
                        rt->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(float(textX - 2 * s), midY - float(10 * s), float(textX + typedW + 2 * s), midY + float(10 * s)), float(3 * s), float(3 * s)), selection.Get());
                    }
                    rt->DrawTextLayout(D2D1::Point2F(float(textX), float(panel.y)), layout.Get(), ink.Get());
                    if (!selectAll_) {
                        float cx = float(textX + typedW + 1 * s);
                        rt->DrawLine(D2D1::Point2F(cx, midY - float(9 * s)), D2D1::Point2F(cx, midY + float(9 * s)), ink.Get(), float(1.5 * s));
                    }
                }
            }
            rt->FillRectangle(D2D1::RectF(float(panel.x + pad), float(panel.y + searchH), float(panel.right() - pad), float(panel.y + searchH + s)), edge.Get());
            const double gridX = panel.x + (panel.w - columns * cellW) / 2;

            bool enterLaunches = true;
            for (const auto& tile : tiles_) if (matches(tile.window)) enterLaunches = false;
            ComPtr<IDWriteTextFormat> nameFormat;
            dwrite_->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, float(12 * s), text::locale(), nameFormat.GetAddressOf());
            if (nameFormat) {
                nameFormat->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
                nameFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
                DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
                ComPtr<IDWriteInlineObject> ellipsis;
                dwrite_->CreateEllipsisTrimmingSign(nameFormat.Get(), ellipsis.GetAddressOf());
                nameFormat->SetTrimming(&trim, ellipsis.Get());
            }
            for (size_t i = 0; i < appResults_.size(); ++i) {
                Rect cell{gridX + (i % columns) * cellW, panel.y + searchH + gap + (i / columns) * cellH, cellW, cellH};
                if (i == 0 && enterLaunches) {
                    // Enter bunu açar.
                    rt->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(float(cell.x + 5 * s), float(cell.y), float(cell.right() - 5 * s), float(cell.bottom())), float(14 * s), float(14 * s)), mark.Get());
                }
                if (IWICBitmapSource* source = installedIcon(appResults_[i].parsing)) {
                    ComPtr<ID2D1Bitmap> icon;
                    if (SUCCEEDED(rt->CreateBitmapFromWicBitmap(source, icon.GetAddressOf()))) {
                        float iconSize = float(52 * s), x = float(cell.midX() - iconSize / 2), y = float(cell.y + 12 * s);
                        rt->DrawBitmap(icon.Get(), D2D1::RectF(x, y, x + iconSize, y + iconSize));
                    }
                }
                if (nameFormat)
                    drawText(rt.Get(), appResults_[i].name, {cell.x + 6 * s, cell.y + 72 * s, cell.w - 12 * s, 20 * s}, nameFormat.Get(), ink.Get(), true);
                hits_.push_back({cell, HitKind::Launch, i});
            }
        }

        // Sürükleme: hedef masaüstü, "+" ya da aralık
        if (drag_ != DragKind::None) {
            float thick = float(2.5 * s);
            if (dropDesktop_ >= 0 && dropDesktop_ < int(strip_.size())) {
                rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(strip_[dropDesktop_].first), float(7 * s), float(7 * s)), accent.Get(), thick);
            }
            if (dropNew_) rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(newDesktopRect_), float(7 * s), float(7 * s)), accent.Get(), thick);
            if (dropGap_ >= 0 && !strip_.empty()) {
                double gapX = dropGap_ < int(strip_.size()) ? strip_[dropGap_].first.x - 8 * s : strip_.back().first.right() + 8 * s;
                const Rect& any = strip_.front().first;
                rt->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(float(gapX - 2 * s), float(any.y - 3 * s), float(gapX + 2 * s), float(any.bottom() + 3 * s)), float(2 * s), float(2 * s)), accent.Get());
            }
            if (slotDrop_) {
                float top = float(slotDrop_->markTop - scrollOffset_), bottom = float(slotDrop_->markBottom - scrollOffset_), mark = float(slotDrop_->markX);
                rt->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(mark - float(2 * s), top, mark + float(2 * s), bottom), float(2 * s), float(2 * s)), accent.Get());
            }
            bool tileHasGhost = drag_ == DragKind::Tile && tiles_[dragTile_].thumb;
            if (dragPin_ >= 0 && dragPin_ < int(pins_.size()) && !tileHasGhost) {
                // Önizlemesi olmayan hücre: imlecin altında uygulamanın adı gider.
                const std::wstring& name = pins_[dragPin_].name;
                ComPtr<IDWriteTextLayout> label;
                dwrite_->CreateTextLayout(name.c_str(), UINT32(name.size()), labelFormat_.Get(), float(300 * s), float(32 * s), label.GetAddressOf());
                DWRITE_TEXT_METRICS m{};
                label->GetMetrics(&m);
                Rect g{dragX_ - (m.width + 28 * s) / 2, dragY_ + 14 * s, m.width + 28 * s, 32 * s};
                rt->FillRoundedRectangle(D2D1::RoundedRect(toD2D(g), float(g.h / 2), float(g.h / 2)), pill.Get());
                rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(g), float(g.h / 2), float(g.h / 2)), accent.Get(), float(1.5 * s));
                rt->DrawTextLayout(D2D1::Point2F(float(g.x + 14 * s), float(g.y)), label.Get(), white.Get());
            }
            if (drag_ == DragKind::Space && dragSpace_ < strip_.size()) {
                const Rect& src = strip_[dragSpace_].first;
                Rect g{dragX_ - src.w / 2, dragY_ + 10 * s, src.w, src.h};
                ComPtr<ID2D1SolidColorBrush> ghost;
                rt->CreateSolidColorBrush(D2D1::ColorF(0.2f, 0.2f, 0.22f, 0.9f), ghost.GetAddressOf());
                rt->FillRoundedRectangle(D2D1::RoundedRect(toD2D(g), float(7 * s), float(7 * s)), ghost.Get());
                rt->DrawRoundedRectangle(D2D1::RoundedRect(toD2D(g), float(7 * s), float(7 * s)), white.Get(), float(s));
            }
        }
        rt->EndDraw();
    }

    POINT src{0, 0}, dst{area_.left, area_.top};
    SIZE size{width_, height_};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(front_, screen, &dst, &size, mem, &src, 0, &blend, ULW_ALPHA);
    SelectObject(mem, old);
    DeleteObject(dib);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
}

const Hit* App::hitAt(int x, int y) const {
    for (auto it = hits_.rbegin(); it != hits_.rend(); ++it)
        if (it->rect.contains(x, y) && (!it->scrolls || viewport_.contains(x, y))) return &*it;
    return nullptr;
}

void App::activate(const SceneWindow& window) {
    if (!window.onCurrentDesktop && window.hasDesktop) desktops_.switchTo(window.desktop);
    if (IsIconic(window.hwnd)) ShowWindowAsync(window.hwnd, SW_RESTORE);
    // Ön plan kilidi. Eskiden Alt'a basılıp bırakılıyordu; tek başına Alt dokunuşu hedef pencerede
    // menü erişim harflerini açıyordu (Not Defteri'nde ölçüldü). Boş fare girdisi tuş göndermeden
    // aynı izni verir; yalnızca ilk deneme olmazsa kullanılır.
    if (!SetForegroundWindow(window.hwnd) || GetForegroundWindow() != window.hwnd) {
        INPUT empty{};
        empty.type = INPUT_MOUSE;
        SendInput(1, &empty, sizeof empty);
        SetForegroundWindow(window.hwnd);
    }
}

Rect App::actionRect(const Tile& tile, int action) const {
    const double s = scale_;
    double size = 26 * s;
    // Dar önizlemede düğmeler küçülür, kaybolmaz.
    if (tile.target.w < (kActionCount * 26 + 18) * s) size = std::max(18 * s, (tile.target.w - 18 * s) / kActionCount);
    return {tile.target.right() - 9 * s - (kActionCount - action) * size, tile.target.y + 9 * s, size, size};
}

void App::refreshScene() {
    if (!isOpen_) return;
    KillTimer(control_, kAnimationTimer);
    clearStripThumbnails();
    for (auto& tile : tiles_) {
        if (tile.thumb) DwmUnregisterThumbnail(tile.thumb);
    }
    snapshot_ = readSnapshot(desktops_);
    layout();
    hover_ = -1;
    hoverAction_ = -1;
    registerThumbnails();
    applyQuery();
    renderBack();
    renderFront();
    writeLayoutTrace();
}

void App::snapWindow(const SceneWindow& window, SnapPosition position) {
    RECT area = area_;
    close();
    if (!window.onCurrentDesktop && window.hasDesktop) desktops_.switchTo(window.desktop);
    if (position == SnapPosition::Fill) {
        ShowWindow(window.hwnd, SW_MAXIMIZE);
    } else {
        if (IsIconic(window.hwnd) || IsZoomed(window.hwnd)) ShowWindow(window.hwnd, SW_RESTORE);
        Rect work{double(area.left), double(area.top), double(area.right - area.left), double(area.bottom - area.top)};
        Rect target = snapFrame(position, work);
        // Pencere karesi görünen kenardan geniştir: görünmez gölge payı eklenmezse aralık kalır.
        RECT outer{}, visible{};
        GetWindowRect(window.hwnd, &outer);
        if (FAILED(DwmGetWindowAttribute(window.hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &visible, sizeof visible))) visible = outer;
        int left = visible.left - outer.left, top = visible.top - outer.top;
        int right = outer.right - visible.right, bottom = outer.bottom - visible.bottom;
        SetWindowPos(window.hwnd, nullptr, int(target.x) - left, int(target.y) - top,
                     int(target.w) + left + right, int(target.h) + top + bottom, SWP_NOZORDER | SWP_NOACTIVATE);
    }
    activate(window);
}

void App::closeWindowAction(const SceneWindow& window) {
    closing_ = window.hwnd;
    closingWindow_ = window;
    closeTicks_ = 0;
    PostMessageW(window.hwnd, WM_CLOSE, 0, 0);
    SetTimer(control_, kCloseTimer, 120, nullptr);
}

// Sahne açık kalır; küçültme canlandırması bitince pencere küçültülmüş olarak yeniden çizilir.
void App::minimizeWindowAction(const SceneWindow& window) {
    if (!IsIconic(window.hwnd)) ShowWindowAsync(window.hwnd, SW_MINIMIZE);
    SetTimer(control_, kMinimizeTimer, 350, nullptr);
}

void App::closeTimerTick() {
    bool gone = !closing_ || !IsWindow(closing_) || !IsWindowVisible(closing_);
    if (!gone && ++closeTicks_ < 8) return;
    KillTimer(control_, kCloseTimer);
    HWND hwnd = closing_;
    closing_ = nullptr;
    if (gone) {
        refreshScene();
    } else if (hwnd) {
        // Kapanmadıysa büyük ihtimalle kaydet sorusu çıktı; sahnenin altında kalmasın.
        SceneWindow window = closingWindow_;
        close();
        activate(window);
    }
}

void App::mouseDown(int x, int y) {
    const Hit* hit = hitAt(x, y);
    pressHit_ = hit ? int(hit - hits_.data()) : -1;
    if (hover_ >= 0 && hover_ < int(hits_.size()) && hits_[hover_].kind == HitKind::Window) {
        const Rect& t = tiles_[hits_[hover_].index].target;
        if (t.contains(x, y)) pressHit_ = hover_;
    }
    pressPin_ = pinAt(x, y);
    pressX_ = x;
    pressY_ = y;
    SetCapture(front_);
}

void App::updateDrop(int x, int y) {
    int desktop = -1, gap = -1;
    bool isNew = false;
    if (!strip_.empty()) {
        const Rect& first = strip_.front().first;
        if (y < first.bottom() + 28 * scale_) {
            if (drag_ == DragKind::Tile) {
                for (size_t i = 0; i < strip_.size(); ++i) {
                    Rect r = strip_[i].first;
                    if (x >= r.x - 8 * scale_ && x < r.right() + 8 * scale_) desktop = int(i);
                }
                isNew = newDesktopRect_.contains(x, std::min(double(y), newDesktopRect_.midY()));
            } else if (drag_ == DragKind::Space) {
                int candidate = 0;
                for (const auto& [rect, info] : strip_) if (rect.midX() < x) ++candidate;
                // Bulunduğu yerin iki yanı anlamsızdır.
                if (candidate != int(dragSpace_) && candidate != int(dragSpace_) + 1) gap = candidate;
            }
        }
    }
    std::optional<SlotDrop> slotDrop;
    if (dragPin_ >= 0 && desktop < 0 && !isNew && viewport_.contains(x, y)) {
        double pageY = y + scrollOffset_;
        Rect area{pinnedArea_.x - 24 * scale_, pinnedArea_.y - 8 * scale_, pinnedArea_.w + 48 * scale_, pinnedArea_.h + 16 * scale_};
        if (area.contains(x, pageY)) slotDrop = slotDropAt(x, pageY, size_t(dragPin_), pinnedSlots_, 20 * scale_);
    }
    if (desktop != dropDesktop_ || gap != dropGap_ || isNew != dropNew_ || slotDrop != slotDrop_ ||
        drag_ == DragKind::Space || drag_ == DragKind::Slot) {
        dropDesktop_ = desktop;
        dropGap_ = gap;
        dropNew_ = isNew;
        slotDrop_ = slotDrop;
        renderFront();
    }
}

void App::mouseMoved(int x, int y, bool buttonDown) {
    const double s = scale_;
    if (buttonDown && (pressHit_ >= 0 || pressPin_ >= 0) && drag_ == DragKind::None && std::hypot(x - pressX_, y - pressY_) > 6 * s && hoverAction_ < 0) {
        const HitKind kind = pressHit_ >= 0 ? hits_[pressHit_].kind : HitKind::EmptySlot;
        const size_t index = pressHit_ >= 0 ? hits_[pressHit_].index : 0;
        dragPin_ = -1;
        slotDrop_.reset();
        if (kind == HitKind::Window) {
            drag_ = DragKind::Tile;
            dragTile_ = index;
            dragPin_ = pressPin_;
            // Önizlemeler kayıt sırasıyla çizilir: yeniden kayıt en üste çıkarır.
            Tile& tile = tiles_[dragTile_];
            if (tile.thumb) {
                DwmUnregisterThumbnail(tile.thumb);
                if (FAILED(DwmRegisterThumbnail(back_, tile.window.hwnd, &tile.thumb))) tile.thumb = nullptr;
            }
            tile.source = {};
            // Sıralanırken hücrenin diğer pencereleri de soluklaşır.
            if (dragPin_ >= 0) {
                for (auto& other : tiles_)
                    if (&other != &tile && other.window.appId == pins_[dragPin_].id) placeThumbnail(other, other.target, 90);
            }
        } else if (kind == HitKind::Space) {
            drag_ = DragKind::Space;
            dragSpace_ = index;
        } else if (kind == HitKind::EmptySlot && pressPin_ >= 0) {
            drag_ = DragKind::Slot;
            dragPin_ = pressPin_;
        }
        dropDesktop_ = dropGap_ = -1;
        dropNew_ = false;
        hover_ = -1;
    }
    if (drag_ != DragKind::None) {
        dragX_ = x;
        dragY_ = y;
        if (drag_ == DragKind::Tile) {
            Tile& tile = tiles_[dragTile_];
            double w = std::min(tile.target.w, 180 * s), h = w / tile.window.aspect();
            placeThumbnail(tile, {x - w / 2, y + 14 * s, w, h}, 230, false);
        }
        updateDrop(x, y);
        return;
    }
    if (buttonDown) return;

    // Üstüne gelinen önizleme, imleç üstünde kaldıkça seçili kalır; yoksa çakışan yığında
    // arkadaki pencere seçimi kapar ve düğmelere ulaşılamaz.
    int next = -1;
    if (onHoveredTile(x, y)) {
        next = hover_;
    } else if (const Hit* hit = hitAt(x, y)) {
        next = int(hit - hits_.data());
    }
    int action = -1;
    if (next >= 0 && hits_[next].kind == HitKind::Window) {
        for (int i = 0; i < kActionCount; ++i)
            if (actionRect(tiles_[hits_[next].index], i).contains(x, y)) action = i;
    }
    if (next != hover_ || action != hoverAction_) {
        hover_ = next;
        hoverAction_ = action;
        renderFront();
    }
}

void App::finishDrag(int x, int y) {
    updateDrop(x, y);
    DragKind kind = drag_;
    int pin = dragPin_;
    std::optional<SlotDrop> slotDrop = slotDrop_;
    drag_ = DragKind::None;
    dragPin_ = -1;
    slotDrop_.reset();
    if (pin >= 0 && slotDrop) {
        dropDesktop_ = dropGap_ = -1;
        dropNew_ = false;
        reorderPin(size_t(pin), slotDrop->gap);
    } else if (kind == DragKind::Slot) {
        renderFront();
    } else if (kind == DragKind::Tile) {
        SceneWindow window = tiles_[dragTile_].window;
        bool changed = false;
        if (dropNew_) {
            GUID created{};
            if (desktops_.create(created)) changed = desktops_.moveWindow(window.hwnd, created);
        } else if (dropDesktop_ >= 0) {
            const GUID& target = strip_[dropDesktop_].second.id;
            if (!window.hasDesktop || !IsEqualGUID(window.desktop, target)) changed = desktops_.moveWindow(window.hwnd, target);
        }
        dropDesktop_ = dropGap_ = -1;
        dropNew_ = false;
        if (changed) {
            refreshScene();
        } else {
            applyQuery();
            renderFront();
        }
    } else if (kind == DragKind::Space) {
        int gap = dropGap_;
        dropDesktop_ = dropGap_ = -1;
        dropNew_ = false;
        if (gap >= 0) {
            UINT index = UINT(gap > int(dragSpace_) ? gap - 1 : gap);
            desktops_.moveDesktop(strip_[dragSpace_].second.id, index);
            refreshScene();
        } else {
            renderFront();
        }
    }
}

void App::mouseUp(int x, int y) {
    if (GetCapture() == front_) ReleaseCapture();
    if (drag_ != DragKind::None) {
        finishDrag(x, y);
        pressHit_ = -1;
        return;
    }
    int press = pressHit_;
    pressHit_ = -1;
    if (hover_ >= 0 && hoverAction_ >= 0 && press == hover_ && hits_[hover_].kind == HitKind::Window) {
        SceneWindow window = tiles_[hits_[hover_].index].window;
        switch (hoverAction_) {
        case 0: snapWindow(window, SnapPosition::LeftHalf); break;
        case 1: snapWindow(window, SnapPosition::RightHalf); break;
        case 2: snapWindow(window, SnapPosition::Fill); break;
        case 3: minimizeWindowAction(window); break;
        default: closeWindowAction(window); break;
        }
        return;
    }
    // Tıklama, basılan yerde bırakmaktır.
    const Hit* hit = hitAt(x, y);
    int released = hit ? int(hit - hits_.data()) : -1;
    if (onHoveredTile(x, y)) released = hover_;
    if (press != released) return;
    if (released == hover_ && hover_ >= 0) {
        Hit copy = hits_[hover_];
        if (copy.kind == HitKind::Window) {
            SceneWindow window = tiles_[copy.index].window;
            close();
            activate(window);
            return;
        }
    }
    click(x, y);
}

void App::rightClick(int x, int y) {
    std::string id;
    if (viewport_.contains(x, y))
        for (const auto& [slotId, slot] : placed_) if (slot.frame.contains(x, y + scrollOffset_)) id = slotId;
    if (id.empty()) {
        const Hit* hit = hitAt(x, y);
        if (hit && hit->kind == HitKind::Chip) id = otherApps_[hit->index];
    }
    if (id.empty()) return;
    int pinIndex = -1;
    for (size_t i = 0; i < pins_.size(); ++i) if (pins_[i].id == id) pinIndex = int(i);

    enum { Left = 1, Right, Small, Medium, Large, Unpin, DoPin };
    HMENU menu = CreatePopupMenu();
    if (pinIndex >= 0) {
        AppendMenuW(menu, MF_STRING | (pinIndex > 0 ? 0 : MF_GRAYED), Left, tx(L"Sola ta\u015F\u0131", L"Move left"));
        AppendMenuW(menu, MF_STRING | (pinIndex + 1 < int(pins_.size()) ? 0 : MF_GRAYED), Right, tx(L"Sa\u011Fa ta\u015F\u0131", L"Move right"));
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        SlotSize size = pins_[pinIndex].size;
        AppendMenuW(menu, MF_STRING | (size == SlotSize::Small ? MF_CHECKED : 0), Small, tx(L"K\u00FC\u00E7\u00FCk", L"Small"));
        AppendMenuW(menu, MF_STRING | (size == SlotSize::Medium ? MF_CHECKED : 0), Medium, tx(L"Orta", L"Medium"));
        AppendMenuW(menu, MF_STRING | (size == SlotSize::Large ? MF_CHECKED : 0), Large, tx(L"B\u00FCy\u00FCk", L"Large"));
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, Unpin, tx(L"Sabitlemeyi kald\u0131r", L"Unpin"));
    } else {
        AppendMenuW(menu, MF_STRING, DoPin, tx(L"Sabitle", L"Pin"));
    }
    POINT p{x + area_.left, y + area_.top};
    int choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, p.x, p.y, 0, front_, nullptr);
    DestroyMenu(menu);
    if (!isOpen_) return;
    switch (choice) {
    case Left: std::swap(pins_[pinIndex], pins_[pinIndex - 1]); break;
    case Right: std::swap(pins_[pinIndex], pins_[pinIndex + 1]); break;
    case Small: pins_[pinIndex].size = SlotSize::Small; break;
    case Medium: pins_[pinIndex].size = SlotSize::Medium; break;
    case Large: pins_[pinIndex].size = SlotSize::Large; break;
    case Unpin: pins_.erase(pins_.begin() + pinIndex); break;
    case DoPin: {
        const auto& app = snapshot_.apps[id];
        pins_.push_back({id, app.path, app.name, initialSlotSize(int(app.windows.size()))});
        break;
    }
    default: return;
    }
    savePins(pins_);
    refreshScene();
}

bool App::containsQuery(const std::wstring& text) const {
    return FindNLSStringEx(LOCALE_NAME_USER_DEFAULT, FIND_FROMSTART | LINGUISTIC_IGNORECASE | LINGUISTIC_IGNOREDIACRITIC,
                           text.c_str(), int(text.size()), query_.c_str(), int(query_.size()), nullptr, nullptr, nullptr, 0) >= 0;
}

bool App::matches(const SceneWindow& window) const {
    if (query_.empty()) return true;
    if (containsQuery(window.title)) return true;
    auto app = snapshot_.apps.find(window.appId);
    return app != snapshot_.apps.end() && containsQuery(app->second.name);
}

void App::applyQuery() {
    for (auto& tile : tiles_) placeThumbnail(tile, tile.target, matches(tile.window) ? 255 : 45);
}

void App::character(wchar_t ch) {
    if (ch == VK_ESCAPE) {
        if (query_.empty()) {
            close();
            return;
        }
        query_.clear();
    } else if (ch == VK_RETURN) {
        // Klavyeyle seçilen önizleme, yoksa ilk eşleşen.
        if (hover_ >= 0 && hover_ < int(hits_.size()) && hits_[hover_].kind == HitKind::Window) {
            SceneWindow window = tiles_[hits_[hover_].index].window;
            close();
            activate(window);
            return;
        }
        for (const auto& tile : tiles_) {
            if (!query_.empty() && matches(tile.window)) {
                SceneWindow window = tile.window;
                close();
                activate(window);
                return;
            }
        }
        // Penceresi eşleşmeyen uygulama: kapalı sabit uygulama açılır, çalışan uygulamanın ilk
        // penceresine geçilir.
        if (!query_.empty()) {
            for (const auto& pin : pins_) {
                auto app = snapshot_.apps.find(pin.id);
                bool running = app != snapshot_.apps.end();
                if (!containsQuery(running ? app->second.name : pin.name)) continue;
                if (running && !app->second.windows.empty()) {
                    SceneWindow window = app->second.windows.front();
                    close();
                    activate(window);
                } else if (!pin.path.empty()) {
                    std::wstring path = pin.path;
                    close();
                    ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                }
                return;
            }
            for (const auto& id : otherApps_) {
                const auto& app = snapshot_.apps[id];
                if (!containsQuery(app.name) || app.windows.empty()) continue;
                SceneWindow window = app.windows.front();
                close();
                activate(window);
                return;
            }
            // Sahnede hiç yoksa: kurulu ama açık olmayan uygulama.
            if (!appResults_.empty()) launchInstalled(0);
        }
        return;
    } else if (ch == 1) { // Ctrl+A: tümünü seç
        if (query_.empty()) return;
        selectAll_ = true;
        renderBack();
        renderFront();
        return;
    } else if (ch == VK_BACK || ch == 0x7F) { // Backspace aramanın tümünü siler; kullanıcı baştan yazar.
        if (query_.empty()) return;
        query_.clear();
    } else if (ch >= 32) {
        if (selectAll_) query_.clear();
        query_.push_back(ch);
    } else {
        return;
    }
    selectAll_ = false;
    searchFocused_ = true;
    if (hover_ >= 0) {
        hover_ = -1;
        hoverAction_ = -1;
        renderFront();
    }
    KillTimer(control_, kAnimationTimer);
    applyQuery();
    updateAppResults();
    renderBack();
    renderFront();
    // En iyi eşleşme aşağıda kaldıysa Enter'ın nereye gideceği görünsün.
    if (!query_.empty()) {
        for (const auto& tile : tiles_) {
            if (matches(tile.window)) {
                scrollIntoView(tile);
                break;
            }
        }
    }
}

void App::scanInstalled() {
    if (scanning_.exchange(true)) return;
    // Klasör birkaç yüz öğe; arka planda okunur, arama o ana kadarki listeyi kullanır.
    std::thread([this] {
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        std::vector<InstalledApp> found;
        ComPtr<IShellItem> folder;
        if (SUCCEEDED(SHGetKnownFolderItem(FOLDERID_AppsFolder, KF_FLAG_DEFAULT, nullptr, IID_PPV_ARGS(folder.GetAddressOf())))) {
            ComPtr<IEnumShellItems> items;
            if (SUCCEEDED(folder->BindToHandler(nullptr, BHID_EnumItems, IID_PPV_ARGS(items.GetAddressOf())))) {
                ComPtr<IShellItem> item;
                while (items->Next(1, item.ReleaseAndGetAddressOf(), nullptr) == S_OK) {
                    PWSTR name = nullptr, parsing = nullptr;
                    if (SUCCEEDED(item->GetDisplayName(SIGDN_NORMALDISPLAY, &name)) &&
                        SUCCEEDED(item->GetDisplayName(SIGDN_PARENTRELATIVEPARSING, &parsing))) {
                        std::wstring n = name, pn = parsing;
                        // Kaldırma ve yardım kısayolları uygulama değil.
                        bool skip = n.find(L"Uninstall") != std::wstring::npos || n.find(L"Kald\u0131r") != std::wstring::npos ||
                                    pn.rfind(L"http", 0) == 0;
                        if (!skip) found.push_back({n, pn});
                    }
                    CoTaskMemFree(name);
                    CoTaskMemFree(parsing);
                }
            }
        }
        {
            std::lock_guard<std::mutex> guard(installedLock_);
            installed_ = std::move(found);
        }
        scanning_ = false;
        CoUninitialize();
    }).detach();
}

void App::updateAppResults() {
    appResults_.clear();
    if (query_.empty()) return;
    auto lower = [](std::wstring t) {
        CharLowerBuffW(t.data(), DWORD(t.size()));
        return t;
    };
    std::set<std::wstring> seen;
    auto find = [&](const std::wstring& text, DWORD flags) {
        return FindNLSStringEx(LOCALE_NAME_USER_DEFAULT, flags | LINGUISTIC_IGNORECASE | LINGUISTIC_IGNOREDIACRITIC,
                               text.c_str(), int(text.size()), query_.c_str(), int(query_.size()), nullptr, nullptr, nullptr, 0) >= 0;
    };
    // 0 adın başı, 1 bir sözcüğün başı, 2 içinde.
    auto rank = [&](const std::wstring& name) -> int {
        if (find(name, FIND_STARTSWITH)) return 0;
        for (size_t i = 1; i < name.size(); ++i)
            if (wcschr(L" -._", name[i - 1]) && find(name.substr(i), FIND_STARTSWITH)) return 1;
        return find(name, FIND_FROMSTART) ? 2 : -1;
    };
    std::vector<std::pair<int, InstalledApp>> ranked;
    {
        std::lock_guard<std::mutex> guard(installedLock_);
        for (const auto& app : installed_) {
            // Aynı adlı kısayollar bir kez görünür.
            int r = rank(app.name);
            if (r >= 0 && !seen.insert(lower(app.name)).second) continue;
            if (r >= 0) ranked.push_back({r, app});
        }
    }
    std::stable_sort(ranked.begin(), ranked.end(), [](const auto& a, const auto& b) {
        if (a.first != b.first) return a.first < b.first;
        return CompareStringEx(LOCALE_NAME_USER_DEFAULT, LINGUISTIC_IGNORECASE, a.second.name.c_str(), -1, b.second.name.c_str(), -1, nullptr, nullptr, 0) == CSTR_LESS_THAN;
    });
    for (size_t i = 0; i < ranked.size() && i < 14; ++i) appResults_.push_back(ranked[i].second);
}

void App::launchInstalled(size_t index) {
    if (index >= appResults_.size()) return;
    // Açık uygulama yeniden başlatılmaz: penceresine geçilir (yoksa çoğu uygulama yeni pencere açar).
    for (const auto& [id, app] : snapshot_.apps) {
        if (app.windows.empty() || CompareStringEx(LOCALE_NAME_USER_DEFAULT, LINGUISTIC_IGNORECASE, app.name.c_str(), -1,
                                                   appResults_[index].name.c_str(), -1, nullptr, nullptr, 0) != CSTR_EQUAL)
            continue;
        SceneWindow window = app.windows.front();
        close();
        activate(window);
        return;
    }
    std::wstring target = L"shell:AppsFolder\\" + appResults_[index].parsing;
    close();
    ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

IWICBitmapSource* App::installedIcon(const std::wstring& parsing) {
    auto found = appIcons_.find(parsing);
    if (found != appIcons_.end()) return found->second.Get();
    ComPtr<IWICBitmapSource> result;
    ComPtr<IShellItemImageFactory> factory;
    std::wstring path = L"shell:AppsFolder\\" + parsing;
    if (wic_ && SUCCEEDED(SHCreateItemFromParsingName(path.c_str(), nullptr, IID_PPV_ARGS(factory.GetAddressOf())))) {
        int size = int(52 * scale_);
        HBITMAP bitmap = nullptr;
        if (SUCCEEDED(factory->GetImage({size, size}, SIIGBF_ICONONLY, &bitmap)) && bitmap) {
            ComPtr<IWICBitmap> source;
            if (SUCCEEDED(wic_->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapUsePremultipliedAlpha, source.GetAddressOf()))) {
                ComPtr<IWICFormatConverter> converter;
                wic_->CreateFormatConverter(converter.GetAddressOf());
                if (SUCCEEDED(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeMedianCut)))
                    result = converter;
            }
            DeleteObject(bitmap);
        }
    }
    appIcons_[parsing] = result;
    return result.Get();
}

void App::keyDown(WPARAM vk) {
    bool control = GetKeyState(VK_CONTROL) & 0x8000;
    if (vk == VK_LEFT || vk == VK_RIGHT || vk == VK_UP || vk == VK_DOWN) {
        moveSelection(vk);
    } else if (control && vk >= '1' && vk <= '9') {
        // Ctrl+1…9: şeritteki o masaüstüne geç.
        size_t index = vk - '1';
        if (index < snapshot_.desktops.size()) {
            GUID id = snapshot_.desktops[index].id;
            close();
            desktops_.switchTo(id);
        }
    } else if (control && vk == 'V') {
        if (!OpenClipboard(front_)) return;
        std::wstring pasted;
        if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
            if (auto* text = static_cast<const wchar_t*>(GlobalLock(data))) {
                pasted = text;
                GlobalUnlock(data);
            }
        }
        CloseClipboard();
        for (wchar_t ch : pasted) character(ch == L'\r' || ch == L'\n' || ch == L'\t' ? L' ' : ch);
    }
}

/// Okla seçim: eşleşen önizlemeler arasında yön ekseninde en yakın olana geçer; fareyle üstüne
/// gelmekle aynı görünür.
void App::moveSelection(WPARAM vk) {
    std::vector<int> pool;
    for (size_t i = 0; i < hits_.size(); ++i)
        if (hits_[i].kind == HitKind::Window && matches(tiles_[hits_[i].index].window)) pool.push_back(int(i));
    if (pool.empty()) return;
    bool hasCurrent = hover_ >= 0 && hover_ < int(hits_.size()) && hits_[hover_].kind == HitKind::Window &&
                      std::find(pool.begin(), pool.end(), hover_) != pool.end();
    int next = -1;
    if (!hasCurrent) {
        next = *std::min_element(pool.begin(), pool.end(), [&](int a, int b) {
            const Rect &ra = tiles_[hits_[a].index].target, &rb = tiles_[hits_[b].index].target;
            return std::make_pair(ra.y, ra.x) < std::make_pair(rb.y, rb.x);
        });
    } else {
        const Rect& from = tiles_[hits_[hover_].index].target;
        double best = 1e18;
        for (int candidate : pool) {
            if (candidate == hover_) continue;
            const Rect& to = tiles_[hits_[candidate].index].target;
            double dx = to.midX() - from.midX(), dy = to.midY() - from.midY();
            double along = vk == VK_LEFT ? -dx : vk == VK_RIGHT ? dx : vk == VK_DOWN ? dy : -dy;
            double across = (vk == VK_LEFT || vk == VK_RIGHT) ? dy : dx;
            if (along <= 8 * scale_) continue;
            double score = along + std::abs(across) * 2;
            if (score < best) {
                best = score;
                next = candidate;
            }
        }
    }
    if (next < 0 || next == hover_) return;
    hover_ = next;
    hoverAction_ = -1;
    scrollIntoView(tiles_[hits_[next].index]);
    renderFront();
}

/// Sınama için: `arrangement.txt` yanında `trace.on` varsa sahne yerleşimini dosyaya yazar.
void App::writeLayoutTrace() const {
    std::wstring base = storePath();
    auto slash = base.find_last_of(L'\\');
    if (slash == std::wstring::npos) return;
    base.resize(slash);
    if (GetFileAttributesW((base + L"\\trace.on").c_str()) == INVALID_FILE_ATTRIBUTES) return;
    std::ofstream out(base + L"\\layout.txt", std::ios::trunc);
    auto pr = [&](const char* tag, const Rect& r, const std::wstring& text) {
        out << tag << ' ' << int(r.x + area_.left) << ' ' << int(r.y + area_.top) << ' ' << int(r.w) << ' ' << int(r.h) << ' ' << toUtf8(text) << '\n';
    };
    for (const auto& t : tiles_) pr("T", t.target, t.window.title);
    for (const auto& [id, slot] : placed_) pr("S", slot.frame, fromUtf8(id));
    for (const auto& [r, d] : strip_) pr("D", r, d.name);
    pr("N", newDesktopRect_, L"");
    pr("H", hintRect_, L"");
    for (const auto& t : tiles_) {
        for (int i = 0; i < kActionCount; ++i) pr("A", actionRect(t, i), t.window.title);
    }
}

void App::click(int x, int y) {
    const Hit* hit = hitAt(x, y);
    if (!hit) {
        close();
        return;
    }
    Hit copy = *hit;
    switch (copy.kind) {
    case HitKind::Window: {
        SceneWindow window = tiles_[copy.index].window;
        close();
        activate(window);
        break;
    }
    case HitKind::Space: {
        GUID id = snapshot_.desktops[copy.index].id;
        close();
        desktops_.switchTo(id);
        break;
    }
    case HitKind::Launch:
        launchInstalled(copy.index);
        break;
    case HitKind::Hint:
        if (!searchFocused_) {
            searchFocused_ = true;
            renderBack();
        }
        break;
    case HitKind::NewDesktop: {
        GUID created{};
        if (desktops_.create(created)) refreshScene();
        break;
    }
    case HitKind::EmptySlot: {
        std::wstring path = pins_[copy.index].path;
        close();
        ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        break;
    }
    case HitKind::Chip: {
        const auto& app = snapshot_.apps[otherApps_[copy.index]];
        if (!app.windows.empty()) {
            SceneWindow window = app.windows.front();
            close();
            activate(window);
        }
        break;
    }
    default:
        break;
    }
}

LRESULT App::handle(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_HOTKEY:
        if (int(wp) >= kLayoutHotKeyBase) {
            auto layouts = loadLayouts();
            size_t index = size_t(wp) - kLayoutHotKeyBase;
            if (index < layouts.size()) {
                if (isOpen_) close();
                restoreSaved(layouts[index]);
            }
            return 0;
        }
        toggle();
        return 0;
    case kToggleMessage:
        toggle();
        return 0;
    case kTrayMessage:
        if (LOWORD(lp) == WM_LBUTTONUP) toggle();
        else if (LOWORD(lp) == WM_RBUTTONUP) trayMenu();
        return 0;
    case WM_TIMER:
        if (wp == kAnimationTimer) stepAnimation();
        if (wp == kScrollTimer) stepScroll();
        if (wp == kCloseTimer) closeTimerTick();
        if (wp == kTaskbarTimer) {
            if (settings_.taskbarPreview) preview_.tick();
            hotCornerTick();
        }
        if (wp == kLayoutRetryTimer) layoutRetryTick();
        if (wp == kMinimizeTimer) {
            KillTimer(control_, kMinimizeTimer);
            if (isOpen_) refreshScene();
        }
        return 0;
    case WM_MOUSEMOVE:
        if (hwnd == front_ && isOpen_) mouseMoved(short(LOWORD(lp)), short(HIWORD(lp)), (wp & MK_LBUTTON) != 0);
        return 0;
    case WM_LBUTTONDOWN:
        if (hwnd == front_ && isOpen_) mouseDown(short(LOWORD(lp)), short(HIWORD(lp)));
        return 0;
    case WM_LBUTTONUP:
        if (hwnd == front_ && isOpen_) mouseUp(short(LOWORD(lp)), short(HIWORD(lp)));
        return 0;
    case WM_RBUTTONUP:
        if (hwnd == front_ && isOpen_) rightClick(short(LOWORD(lp)), short(HIWORD(lp)));
        return 0;
    case WM_MOUSEWHEEL:
        if (isOpen_ && maxScroll_ > 0 && drag_ == DragKind::None && (query_.empty() || appResults_.empty())) {
            KillTimer(control_, kAnimationTimer);
            if (hover_ >= 0) {
                hover_ = -1;
                hoverAction_ = -1;
                renderFront();
            }
            scrollTo(scrollTarget_ - GET_WHEEL_DELTA_WPARAM(wp) * scale_);
        }
        return 0;
    case WM_CHAR:
        if (isOpen_) character(wchar_t(wp));
        return 0;
    case WM_KEYDOWN:
        if (isOpen_) keyDown(wp);
        return 0;
    case WM_ACTIVATE:
        // Başka pencereye geçildiyse iş bitmiştir.
        if (hwnd == front_ && LOWORD(wp) == WA_INACTIVE && isOpen_) {
            close();
            closedByDeactivationAt_ = GetTickCount64();
        }
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_SETTINGCHANGE:
        // Görev çubuğu açık/koyu temaya geçti: tepsi simgesi yeniden çizilir.
        if (hwnd == back_ && lp && wcscmp(reinterpret_cast<const wchar_t*>(lp), L"ImmersiveColorSet") == 0) {
            showTray(false);
            showTray(true);
        }
        return 0;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
        close();
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

} // namespace

/// Uygulamanın eski adı "Workspace Navigator 2" idi. Berth ilk açıldığında ayarlar, sabit
/// uygulamalar ve çalışma düzenleri eski klasörden kopyalanır; eskiler silinmez.
void migrateFromWorkspaceNavigator() {
    PWSTR base = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) return;
    std::wstring root = base;
    CoTaskMemFree(base);
    std::wstring from = root + L"\\WorkspaceNavigator2", to = root + L"\\Berth";
    if (GetFileAttributesW(to.c_str()) != INVALID_FILE_ATTRIBUTES || GetFileAttributesW(from.c_str()) == INVALID_FILE_ATTRIBUTES) return;
    CreateDirectoryW(to.c_str(), nullptr);
    WIN32_FIND_DATAW found{};
    HANDLE search = FindFirstFileW((from + L"\\*").c_str(), &found);
    if (search == INVALID_HANDLE_VALUE) return;
    do {
        if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        CopyFileW((from + L"\\" + found.cFileName).c_str(), (to + L"\\" + found.cFileName).c_str(), TRUE);
    } while (FindNextFileW(search, &found));
    FindClose(search);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR commandLine, int) {
    std::wstring args = commandLine ? commandLine : L"";
    // Paketleme: simge dosyalarını yazar ve çıkar (scripts\\build.ps1 kullanır).
    if (auto at = args.find(L"--write-icons "); at != std::wstring::npos) {
        std::wstring folder = args.substr(at + 14);
        if (!folder.empty() && folder.front() == L'"') folder = folder.substr(1, folder.find(L'"', 1) - 1);
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        return writeIconAssets(folder) ? 0 : 1;
    }
    migrateFromWorkspaceNavigator();
    // Çalışan kopyaya iletilen komutlar: --toggle, --settings, --quit.
    const wchar_t* forward = args.find(L"--quit") != std::wstring::npos ? kQuitEvent
        : args.find(L"--settings") != std::wstring::npos ? kSettingsEvent
        : args.find(L"--toggle") != std::wstring::npos ? kToggleEvent : nullptr;
    if (forward) {
        if (HANDLE e = OpenEventW(EVENT_MODIFY_STATE, FALSE, forward)) {
            SetEvent(e);
            CloseHandle(e);
        }
        return 0;
    }
    // Yönetici olarak çalışan kopyanın kilidi açılamaz; o da "zaten çalışıyor" demektir.
    HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\Berth.Single");
    DWORD singleError = GetLastError();
    if (singleError == ERROR_ALREADY_EXISTS || singleError == ERROR_ACCESS_DENIED) {
        // Çalışırken yeniden başlatmak (görev çubuğuna sabitlenmiş simge, Başlat menüsü) sahneyi
        // açar ya da kapatır: Mac'teki menü çubuğu simgesi gibi.
        if (HANDLE e = OpenEventW(EVENT_MODIFY_STATE, FALSE, kToggleEvent)) {
            SetEvent(e);
            CloseHandle(e);
        }
        return 0;
    }

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    App app;
    g_app = &app;
    if (!app.start(instance)) return 1;

    HANDLE events[3] = {CreateEventW(nullptr, FALSE, FALSE, kToggleEvent), CreateEventW(nullptr, FALSE, FALSE, kQuitEvent),
                        CreateEventW(nullptr, FALSE, FALSE, kSettingsEvent)};
    for (;;) {
        DWORD r = MsgWaitForMultipleObjects(3, events, FALSE, INFINITE, QS_ALLINPUT);
        if (r == WAIT_OBJECT_0) {
            app.toggle();
        } else if (r == WAIT_OBJECT_0 + 1) {
            break;
        } else if (r == WAIT_OBJECT_0 + 2) {
            app.openSettings();
        }
        MSG msg;
        bool quit = false;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) quit = true;
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (quit) break;
    }
    if (single) CloseHandle(single);
    return 0;
}
