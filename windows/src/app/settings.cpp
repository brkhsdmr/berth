#define NOMINMAX
#include "settings.h"
#include "icon.h"
#include "text.h"
#include <algorithm>
#include <appmodel.h>
#include <thread>
#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <fstream>
#include <sstream>
#include <vector>

#include <d2d1.h>
#include <dwmapi.h>
#include <dwrite.h>
#include <uxtheme.h>
#include <windowsx.h>
#include <wrl/client.h>
#pragma comment(lib, "comctl32")
#pragma comment(lib, "dwmapi")
#pragma comment(lib, "uxtheme")
#pragma comment(lib, "advapi32")
#pragma comment(lib, "d2d1")
#pragma comment(lib, "dwrite")
#pragma comment(lib, "version")
#pragma comment(lib, "windowsapp")

// Store sürümünün başlangıç görevi (Windows.ApplicationModel.StartupTask).
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.h>

namespace {

std::wstring storePath();

/// Uygulamalar koyu temada mı (Windows Ayarları > Kişiselleştirme > Renkler)?
bool appsUseDarkTheme() {
    // Sınama: temayı değiştirmeden koyu görünümü görmek için ayar klasöründe "dark.test".
    std::wstring probe = storePath();
    if (!probe.empty() && GetFileAttributesW((probe.substr(0, probe.find_last_of(L'\\')) + L"\\dark.test").c_str()) != INVALID_FILE_ATTRIBUTES)
        return true;
    DWORD value = 1, size = sizeof value;
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
    return value == 0;
}

/// Win32 denetimlerinin koyu temaya geçmesi için uxtheme'in belgelenmemiş iki çağrısı (Explorer,
/// Not Defteri de bunları kullanır). Bulunamazsa denetimler açık temada kalır, pencere çalışır.
void allowDarkControls(HWND window, bool dark) {
    static HMODULE uxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!uxtheme) return;
    using SetPreferredAppMode = int(WINAPI*)(int);
    using AllowDarkModeForWindow = bool(WINAPI*)(HWND, bool);
    static auto setMode = reinterpret_cast<SetPreferredAppMode>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(135)));
    static auto allow = reinterpret_cast<AllowDarkModeForWindow>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(133)));
    if (setMode) setMode(dark ? 1 : 0); // 1: AllowDark
    if (allow) allow(window, dark);
}

/// Hassas dokunmatik yüzey bağlı mı? Windows 11'in SPI_GETTOUCHPADPARAMETERS çağrısı; ilk bayrak
/// "touchpadPresent". Çağrı yoksa (eski Windows) varmış sayılır: düğme zararsızdır.
bool hasTouchpad() {
    unsigned char params[64]{};
    *reinterpret_cast<UINT*>(params) = 1; // TOUCHPAD_PARAMETERS_VERSION_1
    if (!SystemParametersInfoW(0x00AE /* SPI_GETTOUCHPADPARAMETERS */, 44, params, 0)) return true;
    return (*reinterpret_cast<UINT*>(params + 12) & 1) != 0;
}

std::wstring storePath() {
    PWSTR base = nullptr;
    std::wstring path;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) {
        path = std::wstring(base) + L"\\Berth";
        CreateDirectoryW(path.c_str(), nullptr);
        path += L"\\settings.ini";
    }
    CoTaskMemFree(base);
    return path;
}

constexpr const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t* kRunValue = L"Berth";

enum Control {
    IdShortcutOn = 100, IdShortcut, IdCornerDelay, IdTouchOpen, IdTaskbar, IdOtherAppsScroll, IdLaunch, IdLanguage,
    IdPins, IdPinUp, IdPinDown, IdPinSmall, IdPinMedium, IdPinLarge, IdPinRemove, IdPinAdd,
    IdRemoteHost, IdRemoteToken, IdRemoteApply,
    IdLayouts, IdLayoutRestore, IdLayoutRemove, IdLayoutName, IdLayoutRename, IdLayoutSave, IdLayoutKey, IdLayoutKeyClear,
};
const wchar_t* kSizeNames[][2] = {{L"K\u00FC\u00E7\u00FCk", L"Small"}, {L"Orta", L"Medium"}, {L"B\u00FCy\u00FCk", L"Large"}};

const wchar_t* kCornerNames[][2] = {{L"Yok", L"None"}, {L"Sol üst", L"Top left"}, {L"Sağ üst", L"Top right"}, {L"Sol alt", L"Bottom left"}, {L"Sağ alt", L"Bottom right"}};
const int kDelays[] = {0, 250, 500, 1000};
const wchar_t* kDelayNames[][2] = {{L"Hemen", L"Immediately"}, {L"0,25 sn", L"0.25 s"}, {L"0,5 sn", L"0.5 s"}, {L"1 sn", L"1 s"}};
const wchar_t* kLanguageNames[][2] = {{L"Windows dili", L"Windows language"}, {L"Türkçe", L"Türkçe"}, {L"English", L"English"}};

SettingsWindow* g_window = nullptr;

LRESULT CALLBACK settingsProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    return g_window ? g_window->handle(hwnd, msg, wp, lp) : DefWindowProcW(hwnd, msg, wp, lp);
}

} // namespace

Settings Settings::load() {
    Settings s;
    std::wifstream in(storePath());
    std::wstring line;
    // Dil seçimi gelmeden önce kurulmuş sürümler hep Türkçeydi; onların dili değişmesin.
    if (in.is_open()) s.language = 1;
    while (std::getline(in, line)) {
        if (!line.empty() && line[0] == 0xFEFF) line.erase(0, 1);
        auto eq = line.find(L'=');
        if (eq == std::wstring::npos) continue;
        std::wstring key = line.substr(0, eq);
        std::wstring text = line.substr(eq + 1);
        int value = _wtoi(text.c_str());
        if (key == L"remoteHost") s.remoteHost = text;
        else if (key == L"remoteToken") s.remoteToken = text;
        else if (key == L"remoteEnabled") s.remoteEnabled = value != 0;
        if (key == L"shortcutEnabled") s.shortcutEnabled = value != 0;
        else if (key == L"shortcutMods") s.shortcutMods = UINT(value);
        else if (key == L"shortcutKey" && value > 0) s.shortcutKey = UINT(value);
        else if (key == L"corner" && value >= 0 && value <= 4) s.corner = HotCorner(value);
        else if (key == L"cornerDelayMs" && value >= 0) s.cornerDelayMs = value;
        else if (key == L"taskbarPreview") s.taskbarPreview = value != 0;
        else if (key == L"otherAppsScroll") s.otherAppsScroll = value != 0;
        else if (key == L"language" && value >= 0 && value <= 2) s.language = value;
    }
    return s;
}

void Settings::save() const {
    std::wofstream out(storePath(), std::ios::trunc);
    out << L"shortcutEnabled=" << (shortcutEnabled ? 1 : 0) << L"\n"
        << L"shortcutMods=" << shortcutMods << L"\n"
        << L"shortcutKey=" << shortcutKey << L"\n"
        << L"corner=" << int(corner) << L"\n"
        << L"cornerDelayMs=" << cornerDelayMs << L"\n"
        << L"taskbarPreview=" << (taskbarPreview ? 1 : 0) << L"\n"
        << L"otherAppsScroll=" << (otherAppsScroll ? 1 : 0) << L"\n"
        << L"remoteHost=" << remoteHost << L"\n"
        << L"remoteToken=" << remoteToken << L"\n"
        << L"remoteEnabled=" << (remoteEnabled ? 1 : 0) << L"\n"
        << L"language=" << language << L"\n";
}

std::wstring shortcutText(UINT mods, UINT key) {
    std::wstring text;
    if (mods & MOD_CONTROL) text += L"Ctrl+";
    if (mods & MOD_ALT) text += L"Alt+";
    if (mods & MOD_SHIFT) text += L"Shift+";
    if (mods & MOD_WIN) text += L"Win+";
    wchar_t name[64] = L"";
    LONG scan = LONG(MapVirtualKeyW(key, MAPVK_VK_TO_VSC)) << 16;
    if (key >= VK_PRIOR && key <= VK_HELP) scan |= 1 << 24; // Genişletilmiş tuşlar.
    if (GetKeyNameTextW(scan, name, 64) > 0) text += name;
    else text += L"?";
    return text;
}

HotCorner cornerAt(POINT p, const RECT& m) {
    const int pad = 2;
    bool left = p.x <= m.left + pad, right = p.x >= m.right - 1 - pad;
    bool top = p.y <= m.top + pad, bottom = p.y >= m.bottom - 1 - pad;
    if (top && left) return HotCorner::TopLeft;
    if (top && right) return HotCorner::TopRight;
    if (bottom && left) return HotCorner::BottomLeft;
    if (bottom && right) return HotCorner::BottomRight;
    return HotCorner::None;
}

namespace {

constexpr const wchar_t* kStartupTaskId = L"BerthStartup"; // AppxManifest.xml ile aynı.

/// WinRT çağrısını ayrı bir MTA iş parçacığında bekler: arayüz iş parçacığı STA'dır ve orada
/// .get() ile beklemek yasaktır.
template <class F>
auto onWorker(F f) {
    decltype(f()) result{};
    std::thread([&] {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        try { result = f(); } catch (...) {}
        winrt::uninit_apartment();
    }).join();
    return result;
}

using winrt::Windows::ApplicationModel::StartupTask;
using winrt::Windows::ApplicationModel::StartupTaskState;

StartupTaskState startupState() {
    return onWorker([] { return StartupTask::GetAsync(kStartupTaskId).get().State(); });
}

} // namespace

bool launch::packaged() {
    UINT32 length = 0;
    return GetCurrentPackageFullName(&length, nullptr) != APPMODEL_ERROR_NO_PACKAGE;
}

bool launch::enabled() {
    if (packaged()) {
        auto state = startupState();
        return state == StartupTaskState::Enabled || state == StartupTaskState::EnabledByPolicy;
    }
    wchar_t buffer[MAX_PATH * 2];
    DWORD size = sizeof buffer;
    return RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ, nullptr, buffer, &size) == ERROR_SUCCESS;
}

bool launch::blockedByUser() {
    if (!packaged()) return false;
    auto state = startupState();
    return state == StartupTaskState::DisabledByUser || state == StartupTaskState::DisabledByPolicy;
}

bool launch::set(bool on) {
    if (packaged()) {
        return onWorker([on] {
            auto task = StartupTask::GetAsync(kStartupTaskId).get();
            if (!on) {
                task.Disable();
                return true;
            }
            auto state = task.RequestEnableAsync().get();
            return state == StartupTaskState::Enabled || state == StartupTaskState::EnabledByPolicy;
        });
    }
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return false;
    LSTATUS result;
    if (on) {
        wchar_t exe[MAX_PATH];
        GetModuleFileNameW(nullptr, exe, MAX_PATH);
        std::wstring value = L"\"" + std::wstring(exe) + L"\"";
        result = RegSetValueExW(key, kRunValue, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()), DWORD((value.size() + 1) * sizeof(wchar_t)));
    } else {
        result = RegDeleteValueW(key, kRunValue);
        if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

// MARK: - Pencere
//
// Windows 11 Ayarlar'ına benzer: solda bölüm menüsü, sağda kartlar. Pencere, kartlar, anahtarlar,
// düğmeler ve listeler Direct2D ile kendimiz çizilir (açık ve koyu temada aynı görünsün diye);
// yazı kutusu, açılır liste ve kısayol kutusu Windows'un kendi denetimleridir.

namespace {

using Microsoft::WRL::ComPtr;

struct Palette {
    D2D1_COLOR_F bg, card, border, selected, hover, text, soft, accent, onAccent, danger, success, warning, control, controlBorder, track;
};

D2D1_COLOR_F rgb(UINT32 v) { return D2D1::ColorF(v); }

Palette palette(bool dark) {
    if (dark)
        return {rgb(0x202020), rgb(0x2B2B2B), rgb(0x3A3A3A), rgb(0x2D2D2D), rgb(0x292929), rgb(0xFFFFFF), rgb(0xC5C5C5),
                rgb(0x60CDFF), rgb(0x000000), rgb(0xFF99A4), rgb(0x6CCB5F), rgb(0xFCE100), rgb(0x373737), rgb(0x4A4A4A), rgb(0x9A9A9A)};
    return {rgb(0xF3F3F3), rgb(0xFBFBFB), rgb(0xE5E5E5), rgb(0xEAEAEA), rgb(0xEDEDED), rgb(0x1B1B1B), rgb(0x5F5F5F),
            rgb(0x005FB8), rgb(0xFFFFFF), rgb(0xC42B1C), rgb(0x0F7B0F), rgb(0x9D5D00), rgb(0xFFFFFF), rgb(0xD0D0D0), rgb(0x8A8A8A)};
}

COLORREF colorref(const D2D1_COLOR_F& c) { return RGB(BYTE(c.r * 255), BYTE(c.g * 255), BYTE(c.b * 255)); }

/// Windows 11'in simge yazı tipi; Windows 10'da aynı kodlar Segoe MDL2 Assets'te.
const wchar_t* iconFamily(IDWriteFactory* dw) {
    static const wchar_t* family = [dw] {
        ComPtr<IDWriteFontCollection> fonts;
        dw->GetSystemFontCollection(fonts.GetAddressOf());
        UINT32 index = 0;
        BOOL exists = FALSE;
        if (fonts) fonts->FindFamilyName(L"Segoe Fluent Icons", &index, &exists);
        return exists ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
    }();
    return family;
}

/// Bir DC'ye Direct2D ile çizer; koordinatlar pencerenin piksel uzayındadır.
class Painter {
public:
    Painter(HDC dc, const RECT& area, bool dark, float scale) : pal(palette(dark)), scale_(scale), origin_{area.left, area.top} {
        static ComPtr<ID2D1Factory> factory;
        static ComPtr<IDWriteFactory> dwrite;
        if (!factory) D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, factory.GetAddressOf());
        if (!dwrite) DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(dwrite.GetAddressOf()));
        dw_ = dwrite;
        auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
                                                  D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96, 96);
        if (!factory || FAILED(factory->CreateDCRenderTarget(&props, rt_.GetAddressOf()))) return;
        rt_->BindDC(dc, &area);
        rt_->BeginDraw();
    }
    ~Painter() {
        if (rt_) rt_->EndDraw();
    }
    bool ok() const { return rt_ != nullptr; }

    void fill(const RECT& r, const D2D1_COLOR_F& c, float radius = 0) {
        if (!rt_) return;
        if (radius <= 0) rt_->FillRectangle(f(r), brush(c));
        else rt_->FillRoundedRectangle(D2D1::RoundedRect(f(r), radius * scale_, radius * scale_), brush(c));
    }
    void stroke(const RECT& r, const D2D1_COLOR_F& c, float radius, float width = 1) {
        if (!rt_) return;
        float w = width * scale_, h = w / 2;
        D2D1_RECT_F rr = f(r);
        rr = D2D1::RectF(rr.left + h, rr.top + h, rr.right - h, rr.bottom - h);
        rt_->DrawRoundedRectangle(D2D1::RoundedRect(rr, radius * scale_, radius * scale_), brush(c), w);
    }
    void circle(float cx, float cy, float radius, const D2D1_COLOR_F& c, bool filled = true, float width = 1) {
        if (!rt_) return;
        auto e = D2D1::Ellipse(D2D1::Point2F(cx - origin_.x, cy - origin_.y), radius, radius);
        if (filled) rt_->FillEllipse(e, brush(c));
        else rt_->DrawEllipse(e, brush(c), width * scale_);
    }
    /// `size` DIP cinsinden.
    void text(const RECT& r, const std::wstring& s, float size, const D2D1_COLOR_F& c,
              DWRITE_FONT_WEIGHT weight = DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT align = DWRITE_TEXT_ALIGNMENT_LEADING,
              bool wrap = false, const wchar_t* family = L"Segoe UI Variable Text") {
        if (!rt_ || s.empty()) return;
        ComPtr<IDWriteTextFormat> format;
        dw_->CreateTextFormat(family, nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size * scale_,
                              ::text::locale(), format.GetAddressOf());
        if (!format) return;
        format->SetTextAlignment(align);
        format->SetParagraphAlignment(wrap ? DWRITE_PARAGRAPH_ALIGNMENT_NEAR : DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        format->SetWordWrapping(wrap ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
        DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        ComPtr<IDWriteInlineObject> ellipsis;
        dw_->CreateEllipsisTrimmingSign(format.Get(), ellipsis.GetAddressOf());
        format->SetTrimming(&trim, ellipsis.Get());
        rt_->DrawText(s.c_str(), UINT32(s.size()), format.Get(), f(r), brush(c), D2D1_DRAW_TEXT_OPTIONS_CLIP);
    }
    void glyph(const RECT& r, wchar_t g, float size, const D2D1_COLOR_F& c) {
        text(r, std::wstring(1, g), size, c, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_CENTER, false, iconFamily(dw_.Get()));
    }

    const Palette pal;

private:
    D2D1_RECT_F f(const RECT& r) const {
        return D2D1::RectF(float(r.left - origin_.x), float(r.top - origin_.y), float(r.right - origin_.x), float(r.bottom - origin_.y));
    }
    ID2D1SolidColorBrush* brush(const D2D1_COLOR_F& c) {
        brushes_.emplace_back();
        rt_->CreateSolidColorBrush(c, brushes_.back().GetAddressOf());
        return brushes_.back().Get();
    }

    float scale_;
    POINT origin_;
    ComPtr<ID2D1DCRenderTarget> rt_;
    ComPtr<IDWriteFactory> dw_;
    std::vector<ComPtr<ID2D1SolidColorBrush>> brushes_;
};

// Bölümler: simge, Türkçe ve İngilizce ad.
struct Section { wchar_t glyph; const wchar_t* tr; const wchar_t* en; };
const Section kSections[] = {
    {0xE768, L"Açılış", L"Opening"},
    {0xE718, L"Sabit uygulamalar", L"Pinned apps"},
    {0xE80A, L"Çalışma düzenleri", L"Workspace layouts"},
    {0xE7F8, L"Mac bağlantısı", L"Mac connection"},
    {0xE713, L"Genel", L"General"},
};

// Yerleşim (DIP).
constexpr int kNavWidth = 264, kContentX = 288, kContentWidth = 680, kWindowWidth = 1000, kWindowHeight = 680;

/// Sabit uygulama şeridinin hücreleri: genişlik boyutla orantılı (küçük 1, orta 2, büyük 3).
std::vector<RECT> pinCells(const RECT& strip, const std::vector<SettingsWindow::Callbacks::PinRow>& rows, int gap) {
    std::vector<RECT> cells;
    int units = 0;
    for (const auto& row : rows) units += std::clamp(row.size, 0, 2) + 1;
    if (units == 0) return cells;
    double unit = double(strip.right - strip.left - gap * int(rows.size() - 1)) / units;
    double x = strip.left;
    for (const auto& row : rows) {
        double w = unit * (std::clamp(row.size, 0, 2) + 1);
        cells.push_back({LONG(x), strip.top, LONG(x + w), strip.bottom});
        x += w + gap;
    }
    return cells;
}

std::wstring appVersion() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    DWORD handle = 0, size = GetFileVersionInfoSizeW(path, &handle);
    if (!size) return L"";
    std::vector<BYTE> data(size);
    VS_FIXEDFILEINFO* info = nullptr;
    UINT length = 0;
    if (!GetFileVersionInfoW(path, 0, size, data.data()) || !VerQueryValueW(data.data(), L"\\", reinterpret_cast<void**>(&info), &length) || !info)
        return L"";
    return std::to_wstring(HIWORD(info->dwFileVersionMS)) + L"." + std::to_wstring(LOWORD(info->dwFileVersionMS)) + L"." +
           std::to_wstring(HIWORD(info->dwFileVersionLS));
}

bool isToggled(const std::vector<std::pair<int, bool>>& toggles, int id) {
    for (const auto& [key, on] : toggles)
        if (key == id) return on;
    return false;
}

void setToggled(std::vector<std::pair<int, bool>>& toggles, int id, bool on) {
    for (auto& [key, value] : toggles)
        if (key == id) { value = on; return; }
    toggles.push_back({id, on});
}

} // namespace

int SettingsWindow::px(int v) const { return MulDiv(v, int(dpi_), 96); }

void SettingsWindow::show(HINSTANCE instance, const Settings& current, Callbacks callbacks) {
    instance_ = instance;
    settings_ = current;
    callbacks_ = std::move(callbacks);
    g_window = this;
    if (!hwnd_) create();
    else sync();
    ShowWindow(hwnd_, SW_SHOWNORMAL);
    SetForegroundWindow(hwnd_);
}

void SettingsWindow::create() {
    INITCOMMONCONTROLSEX icc{sizeof icc, ICC_HOTKEY_CLASS | ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);

    WNDCLASSW wc{};
    wc.lpfnWndProc = settingsProc;
    wc.hInstance = instance_;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hIcon = makeAppIcon(GetSystemMetrics(SM_CXICON), false);
    wc.lpszClassName = L"Berth.Settings";
    RegisterClassW(&wc);

    dpi_ = GetDpiForSystem();
    RECT r{0, 0, px(kWindowWidth), px(kWindowHeight)};
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
    AdjustWindowRectExForDpi(&r, style, FALSE, 0, dpi_);
    RECT work;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int w = r.right - r.left, h = r.bottom - r.top;
    hwnd_ = CreateWindowExW(0, wc.lpszClassName, tx(L"Berth Ayarları", L"Berth Settings"), style,
                            work.left + (work.right - work.left - w) / 2, work.top + (work.bottom - work.top - h) / 2,
                            w, h, nullptr, nullptr, instance_, nullptr);
    dpi_ = GetDpiForWindow(hwnd_);
    applyTheme();
    buildPage();
}

void SettingsWindow::applyTheme() {
    dark_ = appsUseDarkTheme();
    Palette pal = palette(dark_);
    BOOL dark = dark_;
    DwmSetWindowAttribute(hwnd_, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof dark);
    // Başlık çubuğu pencereyle aynı renkte: Windows 11 Ayarlar gibi tek parça görünür.
    COLORREF caption = colorref(pal.bg);
    DwmSetWindowAttribute(hwnd_, 35 /* DWMWA_CAPTION_COLOR */, &caption, sizeof caption);
    allowDarkControls(hwnd_, dark_);
    if (cardBrush_) DeleteObject(cardBrush_);
    if (controlBrush_) DeleteObject(controlBrush_);
    cardBrush_ = CreateSolidBrush(colorref(pal.card));
    controlBrush_ = CreateSolidBrush(colorref(pal.control));
    if (font_) DeleteObject(font_);
    LOGFONTW lf{};
    lf.lfHeight = -px(14);
    lf.lfWeight = FW_NORMAL;
    lf.lfQuality = CLEARTYPE_QUALITY;
    wcscpy_s(lf.lfFaceName, L"Segoe UI Variable Text");
    font_ = CreateFontIndirectW(&lf);
}

HWND SettingsWindow::addControl(const wchar_t* cls, const wchar_t* text, DWORD style, int id, int x, int y, int w, int h) {
    HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, px(x), px(y), px(w), px(h), hwnd_,
                             reinterpret_cast<HMENU>(INT_PTR(id)), instance_, nullptr);
    SendMessageW(c, WM_SETFONT, WPARAM(font_), TRUE);
    allowDarkControls(c, dark_);
    if (wcscmp(cls, L"COMBOBOX") == 0 || wcscmp(cls, L"EDIT") == 0) SetWindowTheme(c, dark_ ? L"DarkMode_CFD" : nullptr, nullptr);
    else if (wcscmp(cls, L"LISTBOX") == 0) SetWindowTheme(c, dark_ ? L"DarkMode_Explorer" : nullptr, nullptr);
    return c;
}

HWND SettingsWindow::addButton(int id, const wchar_t* text, ButtonKind kind, int x, int y, int w, int h) {
    buttons_.push_back({id, kind});
    return addControl(L"BUTTON", text, BS_OWNERDRAW | WS_TABSTOP, id, x, y, w, h);
}

HWND SettingsWindow::addField(int id, DWORD style, int x, int y, int w, int h) {
    fields_.push_back({px(x), px(y), px(x + w), px(y + h)});
    // Tek satırlık yazı kutusu yazıyı dikeyde ortalamaz: kutu çerçevenin içine ortalanarak konur.
    return addControl(L"EDIT", L"", style | ES_AUTOHSCROLL | WS_TABSTOP, id, x + 10, y + (h - 20) / 2, w - 20, 20);
}

LRESULT CALLBACK SettingsWindow::recorderProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR, DWORD_PTR data) {
    auto* self = reinterpret_cast<SettingsWindow*>(data);
    int id = GetDlgCtrlID(hwnd);
    switch (msg) {
    case WM_GETDLGCODE:
        if (self->recording_ == id) return DLGC_WANTALLKEYS;
        break;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        if (self->recording_ == id) {
            self->recordKey(id, UINT(wp));
            return 0;
        }
        break;
    case WM_SYSCHAR:
    case WM_CHAR:
        if (self->recording_ == id) return 0; // Alt+harf menü sesi çıkarmasın.
        break;
    case WM_KILLFOCUS:
        if (self->recording_ == id) {
            self->recording_ = 0;
            InvalidateRect(hwnd, nullptr, FALSE);
        }
        break;
    }
    return DefSubclassProc(hwnd, msg, wp, lp);
}

void SettingsWindow::recordKey(int id, UINT vk) {
    switch (vk) {
    case VK_SHIFT: case VK_CONTROL: case VK_MENU: case VK_LWIN: case VK_RWIN:
    case VK_LSHIFT: case VK_RSHIFT: case VK_LCONTROL: case VK_RCONTROL: case VK_LMENU: case VK_RMENU:
        return; // Değiştiriciler basılı tutuluyor; asıl tuş bekleniyor.
    }
    UINT mods = 0;
    if (GetKeyState(VK_CONTROL) < 0) mods |= MOD_CONTROL;
    if (GetKeyState(VK_MENU) < 0) mods |= MOD_ALT;
    if (GetKeyState(VK_SHIFT) < 0) mods |= MOD_SHIFT;
    if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) mods |= MOD_WIN;
    HWND button = GetDlgItem(hwnd_, id);
    if (mods == 0 && vk == VK_ESCAPE) {
        recording_ = 0;
    } else if (mods == 0 && (vk == VK_BACK || vk == VK_DELETE) && id == IdLayoutKey) {
        recording_ = 0;
        layoutMods_ = layoutKey_ = 0;
        editLayout(Callbacks::LayoutEdit::ClearHotkey);
    } else if (mods == 0) {
        return; // Değiştiricisiz kısayol olmaz: başka tuşla birlikte basılsın.
    } else {
        recording_ = 0;
        if (id == IdShortcut) {
            applyShortcut(mods, vk);
        } else {
            layoutMods_ = mods;
            layoutKey_ = vk;
            editLayout(Callbacks::LayoutEdit::SetHotkey);
        }
    }
    InvalidateRect(button, nullptr, FALSE);
}

void SettingsWindow::applyShortcut(UINT mods, UINT key) {
    if (callbacks_.tryShortcut && callbacks_.tryShortcut(mods, key)) {
        settings_.shortcutMods = mods;
        settings_.shortcutKey = key;
        shortcutError_.clear();
        if (callbacks_.changed) callbacks_.changed(settings_);
    } else {
        shortcutError_ = shortcutText(mods, key) + tx(L" başka bir uygulamada kullanılıyor; önceki kısayol geçerli.",
                                                      L" is used by another app; the previous shortcut stays.");
    }
    sync();
}

void SettingsWindow::buildPage() {
    for (HWND c = GetWindow(hwnd_, GW_CHILD); c; c = GetWindow(hwnd_, GW_CHILD)) DestroyWindow(c);
    cards_.clear();
    notes_.clear();
    buttons_.clear();
    fields_.clear();
    recording_ = 0;
    statusCard_ = shortcutCard_ = -1;
    cornerScreen_ = pinStrip_ = listFrame_ = RECT{};
    for (auto& d : cornerDots_) d = RECT{};

    for (int i = 0; i < 5; ++i) navRects_[i] = {px(12), px(76 + i * 44), px(kNavWidth - 12), px(76 + i * 44 + 40)};

    const int x0 = kContentX, cw = kContentWidth, right = x0 + cw - 20;
    auto rect = [&](int l, int t, int r, int b) { return RECT{px(l), px(t), px(r), px(b)}; };
    auto card = [&](int y, int h, wchar_t glyph, std::wstring title, std::wstring desc, int reserve = 0) {
        Card c;
        c.r = rect(x0, y, x0 + cw, y + h);
        c.glyph = glyph;
        c.title = std::move(title);
        c.desc = std::move(desc);
        c.reserve = reserve;
        cards_.push_back(c);
        return int(cards_.size()) - 1;
    };
    auto note = [&](int y, int h, std::wstring text, int width = kContentWidth) {
        notes_.push_back({rect(x0, y, x0 + width, y + h), std::move(text)});
    };

    switch (page_) {
    case 0: {
        shortcutCard_ = card(88, 76, 0xE765, tx(L"Klavye kısayolu", L"Keyboard shortcut"), L"", 360);
        addButton(IdShortcut, L"", ButtonKind::Recorder, right - 116 - 220, 88 + 22, 220, 32);
        addButton(IdShortcutOn, L"", ButtonKind::Toggle, right - 104, 88 + 24, 104, 28);

        card(172, 140, 0xE7F4, tx(L"Sıcak köşe", L"Hot corner"),
             tx(L"İmleç seçilen köşeye gelince sahne açılır, açıksa kapanır. Köşeye tıklayarak seç; seçili köşeye yeniden tıklamak kapatır.",
                L"Moving the pointer into the chosen corner opens the scene, or closes it. Click a corner to choose it; click it again to turn it off."),
             340);
        cornerScreen_ = rect(right - 330, 172 + 26, right - 330 + 150, 172 + 26 + 88);
        const int dot = 16;
        POINT corners[4] = {{cornerScreen_.left, cornerScreen_.top}, {cornerScreen_.right, cornerScreen_.top},
                            {cornerScreen_.left, cornerScreen_.bottom}, {cornerScreen_.right, cornerScreen_.bottom}};
        for (int i = 0; i < 4; ++i)
            cornerDots_[i] = {corners[i].x - px(dot / 2), corners[i].y - px(dot / 2), corners[i].x + px(dot / 2), corners[i].y + px(dot / 2)};
        notes_.push_back({rect(right - 150, 172 + 30, right, 172 + 52), tx(L"Bekleme", L"Delay")});
        HWND delay = addControl(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, IdCornerDelay, right - 150, 172 + 56, 150, 200);
        for (auto& name : kDelayNames) SendMessageW(delay, CB_ADDSTRING, 0, LPARAM(tx(name[0], name[1])));

        bool touchpad = hasTouchpad();
        card(320, 84, 0xE7C9, tx(L"Dokunmatik yüzey", L"Touchpad"),
             touchpad ? tx(L"Üç ya da dört parmakla yukarı kaydırmayı Windows işler. Gelişmiş hareketler'de bu hareketi \"Özel kısayol\" yapıp yukarıdaki kısayola ata.",
                           L"Windows handles three- and four-finger swipes. In Advanced gestures, set the swipe up to \"Custom shortcut\" and assign the shortcut above.")
                      : tx(L"Bu bilgisayarda dokunmatik yüzey yok. Uzak masaüstüyle bağlanınca Mac'in trackpad'i de fare olarak gelir.",
                           L"This PC has no touchpad. Over Remote Desktop, a Mac's trackpad also arrives as a mouse."),
             touchpad ? 170 : 0);
        if (touchpad) addButton(IdTouchOpen, tx(L"Ayarları aç", L"Open settings"), ButtonKind::Normal, right - 150, 320 + 26, 150);

        card(412, 76, 0xE8A7, tx(L"Görev çubuğu simgesi", L"Taskbar icon"),
             tx(L"Görev çubuğuna sabitlenmiş simgeye ya da tepsi simgesine tıklamak sahneyi açar, açıksa kapatır.",
                L"Clicking the pinned taskbar icon or the tray icon opens the scene, or closes it if open."));
        break;
    }
    case 1: {
        note(84, 24, tx(L"Sahnede yeri hep aynı olan uygulamalar; soldan sağa bu sırayla yerleşir. Boyut, hücrenin genişliğidir.",
                        L"Apps with a fixed place in the scene, laid out left to right in this order. Size is the cell width."));
        pinStrip_ = rect(x0, 120, x0 + cw, 172);
        listFrame_ = rect(x0, 192, x0 + cw - 204, 192 + 360);
        addControl(L"LISTBOX", L"", WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | WS_TABSTOP,
                   IdPins, x0 + 6, 192 + 6, cw - 204 - 12, 360 - 12);
        int bx = x0 + cw - 188;
        addButton(IdPinUp, tx(L"Yukarı", L"Move up"), ButtonKind::Normal, bx, 192, 188);
        addButton(IdPinDown, tx(L"Aşağı", L"Move down"), ButtonKind::Normal, bx, 232, 188);
        notes_.push_back({rect(bx, 276, bx + 188, 296), tx(L"Boyut", L"Size")});
        const wchar_t* shortNames[][2] = {{L"K", L"S"}, {L"O", L"M"}, {L"B", L"L"}};
        for (int i = 0; i < 3; ++i)
            addButton(IdPinSmall + i, tx(shortNames[i][0], shortNames[i][1]), ButtonKind::Segment, bx + i * 64, 298, 60);
        addButton(IdPinRemove, tx(L"Kaldır", L"Remove"), ButtonKind::Normal, bx, 346, 188);
        addButton(IdPinAdd, tx(L"Uygulama ekle…", L"Add app…"), ButtonKind::Accent, bx, 404, 188);
        break;
    }
    case 2: {
        addButton(IdLayoutSave, tx(L"Şimdikini kaydet", L"Save current"), ButtonKind::Accent, x0 + cw - 184, 30, 184, 34);
        note(84, 24, tx(L"Her pencerenin masaüstü, yeri ve boyutu kaydedilir. Yüklerken kapalı uygulamalar açılır.",
                        L"Saves each window's desktop, position and size. Restoring launches apps that are closed."));
        listFrame_ = rect(x0, 120, x0 + cw - 204, 120 + 240);
        addControl(L"LISTBOX", L"", WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | WS_TABSTOP,
                   IdLayouts, x0 + 6, 120 + 6, cw - 204 - 12, 240 - 12);
        int bx = x0 + cw - 188;
        addButton(IdLayoutRestore, tx(L"Yükle", L"Restore"), ButtonKind::Normal, bx, 120, 188);
        addButton(IdLayoutRemove, tx(L"Sil", L"Delete"), ButtonKind::Normal, bx, 160, 188);

        card(376, 120, 0, L"", L"");
        notes_.push_back({rect(x0 + 20, 376 + 26, x0 + 140, 376 + 50), tx(L"Ad", L"Name")});
        addField(IdLayoutName, 0, x0 + 140, 376 + 18, 320);
        addButton(IdLayoutRename, tx(L"Yeniden adlandır", L"Rename"), ButtonKind::Normal, x0 + 472, 376 + 18, 188);
        notes_.push_back({rect(x0 + 20, 376 + 76, x0 + 140, 376 + 100), tx(L"Kısayol", L"Shortcut")});
        addButton(IdLayoutKey, L"", ButtonKind::Recorder, x0 + 140, 376 + 68, 320, 32);
        addButton(IdLayoutKeyClear, tx(L"Kısayolu kaldır", L"Clear shortcut"), ButtonKind::Normal, x0 + 472, 376 + 68, 188);
        break;
    }
    case 3: {
        statusCard_ = card(88, 76, 0xE7F8, tx(L"Durum", L"Status"), remoteStatus_, 180);
        card(172, 76, 0xE774, tx(L"Mac'in adı", L"Mac name"),
             tx(L"Mac'in adı ya da IP adresi (Mac'te Berth ayarları > Windows). VPN kullanıyorsanız IP adresini girin.",
                L"The Mac's name or IP address (on the Mac: Berth Settings > Windows). If you use a VPN, enter the IP address."),
             300);
        addField(IdRemoteHost, 0, right - 280, 172 + 22, 280);
        card(256, 76, 0xE72E, tx(L"Eşleştirme kodu", L"Pairing code"),
             tx(L"Mac'teki ayarlarda gösterilen 8 karakterlik kod.", L"The 8-character code shown in the Mac's settings."), 200);
        addField(IdRemoteToken, ES_UPPERCASE, right - 180, 256 + 22, 180);
        addButton(IdRemoteApply, remoteConnected() ? tx(L"Bağlantıyı kes", L"Disconnect") : tx(L"Bağlan", L"Connect"),
                  ButtonKind::Accent, x0 + cw - 150, 348, 150, 34);
        note(348, 64,
             tx(L"Mac'te Windows App ile bu bilgisayara bağlıyken yukarı kaydırma buradaki sahneyi açar. Bağlantıyı bu bilgisayar kurar; güvenlik duvarı ayarı gerekmez.",
                L"While a Mac is connected to this PC with Windows App, swiping up there opens the scene here. This PC makes the connection, so no firewall rule is needed."),
             cw - 170);
        break;
    }
    default: {
        card(88, 76, 0xE774, tx(L"Dil", L"Language"), tx(L"Yeniden başlatınca geçerli olur.", L"Takes effect after a restart."), 240);
        HWND language = addControl(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP, IdLanguage, right - 220, 88 + 24, 220, 200);
        for (auto& name : kLanguageNames) SendMessageW(language, CB_ADDSTRING, 0, LPARAM(tx(name[0], name[1])));
        card(172, 76, 0xE7E8, tx(L"Oturum açıldığında başlat", L"Start at sign-in"),
             launch::packaged() ? tx(L"Görev Yöneticisi > Başlangıç uygulamaları'ndan da yönetilir.", L"Also managed in Task Manager > Startup apps.")
                                : tx(L"Windows'a girince tepside hazır bekler.", L"Waits in the tray after you sign in."),
             140);
        addButton(IdLaunch, L"", ButtonKind::Toggle, right - 104, 172 + 24, 104, 28);
        card(256, 76, 0xE8A7, tx(L"Diğer masaüstlerindeki pencereler", L"Windows on other desktops"),
             tx(L"Görev çubuğu simgesinin üstüne gelince uygulamanın diğer masaüstlerindeki pencereleri de gösterilir.",
                L"Hovering a taskbar icon also shows that app's windows on other desktops."),
             140);
        addButton(IdTaskbar, L"", ButtonKind::Toggle, right - 104, 256 + 24, 104, 28);
        card(340, 76, 0xE8A9, tx(L"Aşağı kaydırınca diğer uygulamaların pencereleri", L"Other apps' windows when scrolling down"),
             tx(L"Sabit olmayan uygulamalar sahnenin altında kendi hücreleri ve önizlemeleriyle listelenir.",
                L"Apps you haven't pinned are listed below the scene with their own cells and previews."),
             140);
        addButton(IdOtherAppsScroll, L"", ButtonKind::Toggle, right - 104, 340 + 24, 104, 28);
        std::wstring version = appVersion();
        card(424, 76, 0xE946, L"Berth",
             (version.empty() ? L"" : tx(L"Sürüm ", L"Version ") + version + L" · ") +
                 tx(L"Masaüstleri ve pencereler için sabit yerleşimli sahne.", L"A fixed-layout overview of your desktops and windows."));
        break;
    }
    }
    for (int id : {IdShortcut, IdLayoutKey})
        if (HWND recorder = GetDlgItem(hwnd_, id)) SetWindowSubclass(recorder, recorderProc, 1, DWORD_PTR(this));
    sync();
    InvalidateRect(hwnd_, nullptr, TRUE);
}

void SettingsWindow::paint(HDC dc, const RECT& area) {
    const float scale = float(dpi_) / 96;
    {
        Painter p(dc, area, dark_, scale);
        if (!p.ok()) return;
        const Palette& pal = p.pal;
        p.fill(area, pal.bg);

        // Bölüm menüsü
        p.text({px(52), px(20), px(kNavWidth), px(56)}, L"Berth", 14, pal.text, DWRITE_FONT_WEIGHT_SEMI_BOLD);
        for (int i = 0; i < 5; ++i) {
            const RECT& r = navRects_[i];
            if (i == page_) p.fill(r, pal.selected, 4);
            else if (i == hoverNav_) p.fill(r, pal.hover, 4);
            if (i == page_) {
                int mid = (r.top + r.bottom) / 2;
                p.fill({r.left, mid - px(8), r.left + px(3), mid + px(8)}, pal.accent, 1.5f);
            }
            p.glyph({r.left + px(10), r.top, r.left + px(36), r.bottom}, kSections[i].glyph, 16, pal.text);
            p.text({r.left + px(46), r.top, r.right - px(8), r.bottom}, tx(kSections[i].tr, kSections[i].en), 14, pal.text);
        }

        // Sayfa başlığı
        p.text({px(kContentX), px(24), px(kContentX + kContentWidth - 200), px(70)}, tx(kSections[page_].tr, kSections[page_].en), 28,
               pal.text, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_TEXT_ALIGNMENT_LEADING, false, L"Segoe UI Variable Display");

        for (size_t i = 0; i < cards_.size(); ++i) {
            const Card& c = cards_[i];
            p.fill(c.r, pal.card, 6);
            p.stroke(c.r, pal.border, 6);
            if (c.title.empty()) continue;
            int textLeft = c.r.left + px(c.glyph ? 60 : 20);
            int textRight = c.r.right - px(20 + c.reserve);
            if (c.glyph) p.glyph({c.r.left + px(18), c.r.top + px(14), c.r.left + px(44), c.r.top + px(42)}, c.glyph, 20, pal.text);
            p.text({textLeft, c.r.top + px(14), textRight, c.r.top + px(36)}, c.title, 14, pal.text);
            bool danger = c.danger || (int(i) == shortcutCard_ && !shortcutError_.empty());
            p.text({textLeft, c.r.top + px(37), textRight, c.r.bottom - px(3)}, c.desc, 12, danger ? pal.danger : pal.soft,
                   DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_LEADING, true);
            if (int(i) == statusCard_) {
                bool connected = remoteStatus_.rfind(tx(L"Bağlı: ", L"Connected: "), 0) == 0;
                bool off = remoteStatus_ == tx(L"Kapalı", L"Off");
                D2D1_COLOR_F color = connected ? pal.success : off ? pal.track : pal.warning;
                std::wstring label = connected ? tx(L"Bağlı", L"Connected") : off ? tx(L"Kapalı", L"Off") : tx(L"Bağlı değil", L"Not connected");
                RECT pill{c.r.right - px(170), (c.r.top + c.r.bottom) / 2 - px(14), c.r.right - px(20), (c.r.top + c.r.bottom) / 2 + px(14)};
                p.stroke(pill, color, 14);
                p.circle(float(pill.left + px(16)), float((pill.top + pill.bottom) / 2), float(px(4)), color);
                p.text({pill.left + px(28), pill.top, pill.right - px(8), pill.bottom}, label, 12, pal.text);
            }
        }
        for (const Note& n : notes_)
            p.text(n.r, n.text, 12, n.danger ? pal.danger : pal.soft, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_LEADING, true);

        // Sıcak köşe seçici: küçük bir ekran, köşelerinde seçilebilir noktalar.
        if (page_ == 0 && cornerScreen_.right > cornerScreen_.left) {
            p.fill(cornerScreen_, pal.bg, 6);
            p.stroke(cornerScreen_, pal.track, 6, 1.5f);
            RECT bar{cornerScreen_.left + px(2), cornerScreen_.bottom - px(12), cornerScreen_.right - px(2), cornerScreen_.bottom - px(2)};
            p.fill(bar, pal.border, 2);
            for (int i = 0; i < 4; ++i) {
                const RECT& d = cornerDots_[i];
                float cx = float(d.left + d.right) / 2, cy = float(d.top + d.bottom) / 2, radius = float(d.right - d.left) / 2;
                bool on = int(settings_.corner) == i + 1;
                p.circle(cx, cy, radius, on ? pal.accent : pal.card);
                if (!on) p.circle(cx, cy, radius - scale, pal.track, false, 1.5f);
            }
            int corner = std::clamp(int(settings_.corner), 0, 4);
            p.text({cornerScreen_.left, cornerScreen_.bottom + px(10), cornerScreen_.right, cornerScreen_.bottom + px(30)},
                   tx(kCornerNames[corner][0], kCornerNames[corner][1]), 12, pal.soft, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_CENTER);
        }

        // Sabit uygulama şeridi: sahnedeki sıra ve genişlik.
        if (page_ == 1) {
            auto cells = pinCells(pinStrip_, pinRows_, px(4));
            if (cells.empty())
                p.text(pinStrip_, tx(L"Henüz sabit uygulama yok. Sahnede bir uygulamaya sağ tıklayıp sabitleyebilir ya da buradan ekleyebilirsin.",
                                     L"No pinned apps yet. Right-click an app in the scene to pin it, or add one here."),
                       12, pal.soft, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_CENTER);
            for (size_t i = 0; i < cells.size(); ++i) {
                bool on = int(i) == selectedPin_;
                p.fill(cells[i], on ? pal.accent : pal.card, 6);
                if (!on) p.stroke(cells[i], pal.border, 6);
                RECT label{cells[i].left + px(6), cells[i].top, cells[i].right - px(6), cells[i].bottom};
                p.text(label, pinRows_[i].name, 12, on ? pal.onAccent : pal.text, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_CENTER);
            }
        }
        if (listFrame_.right > listFrame_.left) {
            p.fill(listFrame_, pal.card, 6);
            p.stroke(listFrame_, pal.border, 6);
            HWND list = GetDlgItem(hwnd_, page_ == 1 ? IdPins : IdLayouts);
            if (list && SendMessageW(list, LB_GETCOUNT, 0, 0) == 0) {
                int mid = (listFrame_.top + listFrame_.bottom) / 2;
                RECT empty{listFrame_.left + px(40), mid - px(22), listFrame_.right - px(40), mid + px(40)};
                p.text(empty, page_ == 1 ? tx(L"Sabit uygulama yok.", L"No pinned apps.")
                                         : tx(L"Henüz kayıtlı düzen yok. \"Şimdikini kaydet\" pencerelerin yerini saklar; sonra buradan ya da tepsi menüsünden yüklersin.",
                                              L"No saved layouts yet. \"Save current\" stores where your windows are; restore it here or from the tray menu."),
                       13, pal.soft, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_CENTER, true);
            }
        }
        for (const RECT& field : fields_) {
            p.fill(field, pal.control, 4);
            p.stroke(field, pal.controlBorder, 4);
        }
        if (page_ == 2 && !layoutMessage_.empty())
            p.text({px(kContentX), px(504), px(kContentX + kContentWidth), px(530)}, layoutMessage_, 12, pal.danger);
    }
    // Uygulama simgesi menünün başında.
    static HICON icon = makeAppIcon(GetSystemMetrics(SM_CXSMICON) * 2, false);
    DrawIconEx(dc, px(20) - area.left, px(26) - area.top, icon, px(24), px(24), 0, nullptr, DI_NORMAL);
}

void SettingsWindow::drawItem(const DRAWITEMSTRUCT* d) {
    const float scale = float(dpi_) / 96;
    Painter p(d->hDC, d->rcItem, dark_, scale);
    if (!p.ok()) return;
    const Palette& pal = p.pal;
    RECT r = d->rcItem;
    // Painter'ın uzayı öğenin karesidir: çizimler doğrudan öğe koordinatında.
    if (d->CtlType == ODT_LISTBOX) {
        p.fill(r, pal.card);
        if (d->itemID == UINT(-1)) return;
        bool selected = (d->itemState & ODS_SELECTED) != 0;
        RECT row{r.left + px(2), r.top + px(2), r.right - px(2), r.bottom - px(2)};
        if (selected) {
            p.fill(row, pal.selected, 4);
            int mid = (row.top + row.bottom) / 2;
            p.fill({row.left, mid - px(8), row.left + px(3), mid + px(8)}, pal.accent, 1.5f);
        }
        wchar_t buffer[512] = L"";
        SendMessageW(d->hwndItem, LB_GETTEXT, d->itemID, LPARAM(buffer));
        std::wstring textValue = buffer;
        if (d->CtlID == IdPins) {
            int size = d->itemID < pinRows_.size() ? std::clamp(pinRows_[d->itemID].size, 0, 2) : 0;
            RECT chip{row.right - px(96), (row.top + row.bottom) / 2 - px(11), row.right - px(12), (row.top + row.bottom) / 2 + px(11)};
            p.text({row.left + px(14), row.top, chip.left - px(8), row.bottom}, textValue, 14, pal.text);
            p.fill(chip, pal.bg, 11);
            p.text(chip, tx(kSizeNames[size][0], kSizeNames[size][1]), 12, pal.soft, DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_CENTER);
        } else {
            auto tab = textValue.find(L'\t');
            std::wstring name = textValue.substr(0, tab), detail = tab == std::wstring::npos ? L"" : textValue.substr(tab + 1);
            int mid = (row.top + row.bottom) / 2;
            p.text({row.left + px(14), row.top + px(4), row.right - px(12), mid + px(2)}, name, 14, pal.text, DWRITE_FONT_WEIGHT_SEMI_BOLD);
            p.text({row.left + px(14), mid, row.right - px(12), row.bottom - px(4)}, detail, 12, pal.soft);
        }
        return;
    }
    if (d->CtlType != ODT_BUTTON) return;

    // Arka plan: düğme bir kartın içindeyse kartın rengi.
    RECT inParent = r;
    MapWindowPoints(d->hwndItem, hwnd_, reinterpret_cast<POINT*>(&inParent), 2);
    bool onCard = std::any_of(cards_.begin(), cards_.end(), [&](const Card& c) {
        RECT overlap;
        return IntersectRect(&overlap, &c.r, &inParent) != 0;
    });
    p.fill(r, onCard ? pal.card : pal.bg);

    ButtonKind kind = ButtonKind::Normal;
    for (const auto& [id, k] : buttons_)
        if (id == int(d->CtlID)) kind = k;
    bool pressed = (d->itemState & ODS_SELECTED) != 0, disabled = (d->itemState & ODS_DISABLED) != 0;
    wchar_t label[128] = L"";
    GetWindowTextW(d->hwndItem, label, 128);

    if (kind == ButtonKind::Toggle) {
        bool on = isToggled(toggles_, int(d->CtlID));
        RECT track{r.right - px(42), (r.top + r.bottom) / 2 - px(10), r.right - px(2), (r.top + r.bottom) / 2 + px(10)};
        p.text({r.left, r.top, track.left - px(12), r.bottom}, on ? tx(L"Açık", L"On") : tx(L"Kapalı", L"Off"), 14, pal.text,
               DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_TRAILING);
        float cy = float(track.top + track.bottom) / 2;
        if (on) {
            p.fill(track, pal.accent, 10);
            p.circle(float(track.right - px(10)), cy, 6 * scale, pal.onAccent);
        } else {
            p.stroke(track, pal.track, 10, 1);
            p.circle(float(track.left + px(10)), cy, 5 * scale, pal.track);
        }
        return;
    }
    if (kind == ButtonKind::Recorder) {
        bool recording = recording_ == int(d->CtlID);
        std::wstring value;
        if (recording) value = tx(L"Tuşlara basın…", L"Press the keys…");
        else if (d->CtlID == IdShortcut) value = shortcutText(settings_.shortcutMods, settings_.shortcutKey);
        else value = layoutKey_ ? shortcutText(layoutMods_, layoutKey_) : tx(L"Kısayol yok", L"No shortcut");
        p.fill(r, pal.control, 4);
        p.stroke(r, recording ? pal.accent : pal.controlBorder, 4, recording ? 2.f : 1.f);
        RECT inner{r.left + px(12), r.top, r.right - px(36), r.bottom};
        p.text(inner, value, 14, disabled ? pal.track : recording ? pal.accent : pal.text);
        p.glyph({r.right - px(34), r.top, r.right - px(8), r.bottom}, 0xE765, 14, disabled ? pal.track : pal.soft);
        return;
    }
    bool selectedSegment = false;
    if (kind == ButtonKind::Segment && selectedPin_ >= 0 && selectedPin_ < int(pinRows_.size()))
        selectedSegment = int(d->CtlID) - IdPinSmall == std::clamp(pinRows_[selectedPin_].size, 0, 2);
    bool accent = (kind == ButtonKind::Accent || selectedSegment) && !disabled;
    RECT face{r.left, r.top, r.right, r.bottom};
    if (accent) {
        p.fill(face, pal.accent, 4);
        if (pressed) p.fill(face, pal.selected, 4);
    } else {
        p.fill(face, pressed ? pal.selected : pal.control, 4);
        p.stroke(face, pal.controlBorder, 4);
    }
    D2D1_COLOR_F ink = disabled ? pal.track : accent && !pressed ? pal.onAccent : pal.text;
    p.text(face, label, 14, ink, accent ? DWRITE_FONT_WEIGHT_SEMI_BOLD : DWRITE_FONT_WEIGHT_REGULAR, DWRITE_TEXT_ALIGNMENT_CENTER);
}

void SettingsWindow::click(POINT pt) {
    for (int i = 0; i < 5; ++i) {
        if (PtInRect(&navRects_[i], pt)) {
            if (i != page_) {
                page_ = i;
                buildPage();
            }
            return;
        }
    }
    if (page_ == 0) {
        for (int i = 0; i < 4; ++i) {
            RECT hit = cornerDots_[i];
            InflateRect(&hit, px(8), px(8));
            if (!PtInRect(&hit, pt)) continue;
            HotCorner chosen = HotCorner(i + 1);
            settings_.corner = settings_.corner == chosen ? HotCorner::None : chosen;
            if (callbacks_.changed) callbacks_.changed(settings_);
            sync();
            return;
        }
    }
    if (page_ == 1) {
        auto cells = pinCells(pinStrip_, pinRows_, px(4));
        for (size_t i = 0; i < cells.size(); ++i)
            if (PtInRect(&cells[i], pt)) {
                syncPins(int(i));
                return;
            }
    }
}

void SettingsWindow::refreshStatus() {
    if (!callbacks_.remoteStatus) return;
    std::wstring now = callbacks_.remoteStatus();
    if (now == remoteStatus_) return;
    remoteStatus_ = now;
    if (statusCard_ >= 0) {
        cards_[statusCard_].desc = remoteStatus_;
        InvalidateRect(hwnd_, &cards_[statusCard_].r, FALSE);
    }
    if (HWND button = GetDlgItem(hwnd_, IdRemoteApply)) {
        SetWindowTextW(button, remoteConnected() ? tx(L"Bağlantıyı kes", L"Disconnect") : tx(L"Bağlan", L"Connect"));
        InvalidateRect(button, nullptr, FALSE);
    }
}

bool SettingsWindow::remoteConnected() const {
    return remoteStatus_.rfind(tx(L"Bağlı: ", L"Connected: "), 0) == 0;
}

void SettingsWindow::syncLayouts(int select) {
    HWND list = GetDlgItem(hwnd_, IdLayouts);
    if (!list || !callbacks_.layouts) return;
    syncingLayouts_ = true;
    auto rows = callbacks_.layouts();
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    for (const auto& row : rows) {
        std::wstring textValue = row.name + L"\t" + text::windows(row.windows);
        if (row.key) textValue += L"  ·  " + shortcutText(row.mods, row.key);
        SendMessageW(list, LB_ADDSTRING, 0, LPARAM(textValue.c_str()));
    }
    if (select >= int(rows.size())) select = int(rows.size()) - 1;
    SendMessageW(list, LB_SETCURSEL, select, 0);
    // Boş liste gizlenir: arkasındaki çerçevede ne yapılacağı yazar.
    ShowWindow(list, rows.empty() ? SW_HIDE : SW_SHOW);
    bool has = select >= 0;
    for (int id : {IdLayoutRestore, IdLayoutRemove, IdLayoutRename, IdLayoutKey, IdLayoutKeyClear, IdLayoutName}) EnableWindow(GetDlgItem(hwnd_, id), has);
    SetDlgItemTextW(hwnd_, IdLayoutName, has ? rows[select].name.c_str() : L"");
    layoutMods_ = has ? rows[select].mods : 0;
    layoutKey_ = has ? rows[select].key : 0;
    InvalidateRect(GetDlgItem(hwnd_, IdLayoutKey), nullptr, FALSE);
    InvalidateRect(hwnd_, &listFrame_, FALSE);
    syncingLayouts_ = false;
    RECT message{px(kContentX), px(500), px(kContentX + kContentWidth), px(534)};
    InvalidateRect(hwnd_, &message, FALSE);
}

void SettingsWindow::editLayout(Callbacks::LayoutEdit edit) {
    using E = Callbacks::LayoutEdit;
    int index = int(SendDlgItemMessageW(hwnd_, IdLayouts, LB_GETCURSEL, 0, 0));
    if (edit != E::SaveNew && index < 0) return;
    wchar_t name[128] = L"";
    GetDlgItemTextW(hwnd_, IdLayoutName, name, 128);
    UINT key = layoutKey_, mods = layoutMods_;
    if (edit == E::SetHotkey && (key == 0 || mods == 0)) return;
    layoutMessage_.clear();
    bool ok = callbacks_.editLayout ? callbacks_.editLayout(edit, index, edit == E::SaveNew ? L"" : name, mods, key) : false;
    if (!ok && edit == E::SetHotkey)
        layoutMessage_ = shortcutText(mods, key) + tx(L" başka bir uygulamada kullanılıyor.", L" is used by another app.");
    syncLayouts(edit == E::SaveNew ? (1 << 20) : index);
}

void SettingsWindow::syncPins(int select) {
    pinRows_ = callbacks_.pins ? callbacks_.pins() : std::vector<Callbacks::PinRow>{};
    if (select >= int(pinRows_.size())) select = int(pinRows_.size()) - 1;
    selectedPin_ = select;
    if (HWND list = GetDlgItem(hwnd_, IdPins)) {
        SendMessageW(list, LB_RESETCONTENT, 0, 0);
        for (const auto& row : pinRows_) SendMessageW(list, LB_ADDSTRING, 0, LPARAM(row.name.c_str()));
        SendMessageW(list, LB_SETCURSEL, select, 0);
        ShowWindow(list, pinRows_.empty() ? SW_HIDE : SW_SHOW);
    }
    bool has = select >= 0;
    EnableWindow(GetDlgItem(hwnd_, IdPinUp), has && select > 0);
    EnableWindow(GetDlgItem(hwnd_, IdPinDown), has && select + 1 < int(pinRows_.size()));
    EnableWindow(GetDlgItem(hwnd_, IdPinRemove), has);
    for (int i = 0; i < 3; ++i) {
        HWND segment = GetDlgItem(hwnd_, IdPinSmall + i);
        EnableWindow(segment, has);
        InvalidateRect(segment, nullptr, FALSE);
    }
    InvalidateRect(hwnd_, &pinStrip_, FALSE);
}

void SettingsWindow::editPin(Callbacks::PinEdit edit, int value) {
    int index = selectedPin_;
    if (edit != Callbacks::PinEdit::Add && index < 0) return;
    if (callbacks_.editPin) callbacks_.editPin(edit, index, value);
    int select = index;
    if (edit == Callbacks::PinEdit::MoveUp) select = index - 1;
    if (edit == Callbacks::PinEdit::MoveDown) select = index + 1;
    if (edit == Callbacks::PinEdit::Add) select = 1 << 20; // Sona eklendi; syncPins sona kırpar.
    syncPins(select);
}

void SettingsWindow::sync() {
    setToggled(toggles_, IdShortcutOn, settings_.shortcutEnabled);
    setToggled(toggles_, IdTaskbar, settings_.taskbarPreview);
    setToggled(toggles_, IdOtherAppsScroll, settings_.otherAppsScroll);
    if (page_ == 4) setToggled(toggles_, IdLaunch, launch::enabled());
    for (int id : {IdShortcutOn, IdTaskbar, IdOtherAppsScroll, IdLaunch})
        if (HWND c = GetDlgItem(hwnd_, id)) InvalidateRect(c, nullptr, FALSE);

    if (HWND recorder = GetDlgItem(hwnd_, IdShortcut)) {
        EnableWindow(recorder, settings_.shortcutEnabled);
        InvalidateRect(recorder, nullptr, FALSE);
    }
    if (shortcutCard_ >= 0) {
        cards_[shortcutCard_].desc = !shortcutError_.empty() ? shortcutError_
            : tx(L"Aynı kısayol sahne açıkken kapatır. Tepsi simgesine tıklamak da açar ya da kapatır.",
                 L"The same shortcut closes the scene when it is open. Clicking the tray icon also opens or closes it.");
        InvalidateRect(hwnd_, &cards_[shortcutCard_].r, FALSE);
    }
    int delayIndex = 0;
    for (int i = 0; i < 4; ++i)
        if (kDelays[i] == settings_.cornerDelayMs) delayIndex = i;
    SendDlgItemMessageW(hwnd_, IdCornerDelay, CB_SETCURSEL, delayIndex, 0);
    EnableWindow(GetDlgItem(hwnd_, IdCornerDelay), settings_.corner != HotCorner::None);
    if (page_ == 0) {
        RECT picker = cornerScreen_;
        InflateRect(&picker, px(12), px(40));
        InvalidateRect(hwnd_, &picker, FALSE);
    }

    SendDlgItemMessageW(hwnd_, IdLanguage, CB_SETCURSEL, settings_.language, 0);
    SetDlgItemTextW(hwnd_, IdRemoteHost, settings_.remoteHost.c_str());
    SetDlgItemTextW(hwnd_, IdRemoteToken, settings_.remoteToken.c_str());
    remoteStatus_.clear();
    refreshStatus();
    if (page_ == 1) syncPins(selectedPin_ < 0 ? 0 : selectedPin_);
    if (page_ == 2) {
        int layout = int(SendDlgItemMessageW(hwnd_, IdLayouts, LB_GETCURSEL, 0, 0));
        syncLayouts(layout < 0 ? 0 : layout);
    }
}

void SettingsWindow::command(int id, int code) {
    switch (id) {
    case IdShortcutOn:
        settings_.shortcutEnabled = !settings_.shortcutEnabled;
        shortcutError_.clear();
        break;
    case IdShortcut:
    case IdLayoutKey:
        // Kaydedici: tıklanınca tuş bekler; tuşları alt sınıf yordamı yakalar.
        if (code != BN_CLICKED) return;
        recording_ = recording_ == id ? 0 : id;
        SetFocus(GetDlgItem(hwnd_, id));
        InvalidateRect(GetDlgItem(hwnd_, id), nullptr, FALSE);
        return;
    case IdCornerDelay:
        if (code != CBN_SELCHANGE) return;
        settings_.cornerDelayMs = kDelays[std::max<LRESULT>(0, SendDlgItemMessageW(hwnd_, IdCornerDelay, CB_GETCURSEL, 0, 0))];
        break;
    case IdLayouts:
        if (code == LBN_SELCHANGE) {
            layoutMessage_.clear();
            syncLayouts(int(SendDlgItemMessageW(hwnd_, IdLayouts, LB_GETCURSEL, 0, 0)));
        }
        return;
    case IdLayoutRestore: editLayout(Callbacks::LayoutEdit::Restore); return;
    case IdLayoutRemove: editLayout(Callbacks::LayoutEdit::Remove); return;
    case IdLayoutRename: editLayout(Callbacks::LayoutEdit::Rename); return;
    case IdLayoutSave: editLayout(Callbacks::LayoutEdit::SaveNew); return;
    case IdLayoutKeyClear:
        layoutMods_ = layoutKey_ = 0;
        editLayout(Callbacks::LayoutEdit::ClearHotkey);
        return;
    case IdPins:
        if (code == LBN_SELCHANGE) syncPins(int(SendDlgItemMessageW(hwnd_, IdPins, LB_GETCURSEL, 0, 0)));
        return;
    case IdPinUp: editPin(Callbacks::PinEdit::MoveUp); return;
    case IdPinDown: editPin(Callbacks::PinEdit::MoveDown); return;
    case IdPinRemove: editPin(Callbacks::PinEdit::Remove); return;
    case IdPinSmall:
    case IdPinMedium:
    case IdPinLarge:
        editPin(Callbacks::PinEdit::SetSize, id - IdPinSmall);
        return;
    case IdPinAdd: {
        auto names = callbacks_.addable ? callbacks_.addable() : std::vector<std::wstring>{};
        HMENU menu = CreatePopupMenu();
        for (size_t i = 0; i < names.size(); ++i) AppendMenuW(menu, MF_STRING, i + 1, names[i].c_str());
        if (names.empty()) AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, tx(L"Sabitlenmemiş açık uygulama yok", L"No unpinned open apps"));
        RECT r;
        GetWindowRect(GetDlgItem(hwnd_, IdPinAdd), &r);
        int choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, r.left, r.bottom, 0, hwnd_, nullptr);
        DestroyMenu(menu);
        if (choice > 0) editPin(Callbacks::PinEdit::Add, choice - 1);
        return;
    }
    case IdRemoteApply: {
        wchar_t host[256] = L"", token[64] = L"";
        GetDlgItemTextW(hwnd_, IdRemoteHost, host, 256);
        GetDlgItemTextW(hwnd_, IdRemoteToken, token, 64);
        if (remoteConnected()) {
            settings_.remoteEnabled = false; // Bağlıyken düğme "Bağlantıyı kes".
        } else {
            settings_.remoteHost = host;
            settings_.remoteToken = token;
            settings_.remoteEnabled = true;
        }
        break;
    }
    case IdTouchOpen:
        ShellExecuteW(nullptr, L"open", L"ms-settings:devices-touchpad", nullptr, nullptr, SW_SHOWNORMAL);
        return;
    case IdTaskbar:
        settings_.taskbarPreview = !settings_.taskbarPreview;
        break;
    case IdOtherAppsScroll:
        settings_.otherAppsScroll = !settings_.otherAppsScroll;
        break;
    case IdLaunch: {
        bool on = !isToggled(toggles_, IdLaunch);
        if (!launch::set(on) && on && launch::blockedByUser())
            MessageBoxW(hwnd_, tx(L"Başlangıç, Görev Yöneticisi > Başlangıç uygulamaları'nda kapatılmış. Oradan yeniden açabilirsiniz.",
                                  L"Startup was turned off in Task Manager > Startup apps. You can turn it back on there."),
                        L"Berth", MB_OK | MB_ICONINFORMATION);
        sync();
        return;
    }
    case IdLanguage: {
        if (code != CBN_SELCHANGE) return;
        int chosen = int(SendDlgItemMessageW(hwnd_, IdLanguage, CB_GETCURSEL, 0, 0));
        if (chosen < 0 || chosen == settings_.language) return;
        settings_.language = chosen;
        MessageBoxW(hwnd_, tx(L"Yeni dil, Berth yeniden başlatılınca geçerli olur.",
                              L"The new language takes effect after Berth restarts."),
                    L"Berth", MB_OK | MB_ICONINFORMATION);
        break;
    }
    default:
        return;
    }
    if (callbacks_.changed) callbacks_.changed(settings_);
    sync();
}

LRESULT SettingsWindow::handle(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_COMMAND:
        command(LOWORD(wp), HIWORD(wp));
        return 0;
    case WM_MEASUREITEM: {
        auto* m = reinterpret_cast<MEASUREITEMSTRUCT*>(lp);
        m->itemHeight = px(m->CtlID == IdLayouts ? 52 : 40);
        return TRUE;
    }
    case WM_DRAWITEM:
        drawItem(reinterpret_cast<DRAWITEMSTRUCT*>(lp));
        return TRUE;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        RECT client;
        GetClientRect(hwnd, &client);
        // Titremesin diye önce bellekte çizilir.
        HDC memory = CreateCompatibleDC(dc);
        HBITMAP bitmap = CreateCompatibleBitmap(dc, client.right, client.bottom);
        HGDIOBJ old = SelectObject(memory, bitmap);
        paint(memory, client);
        BitBlt(dc, ps.rcPaint.left, ps.rcPaint.top, ps.rcPaint.right - ps.rcPaint.left, ps.rcPaint.bottom - ps.rcPaint.top,
               memory, ps.rcPaint.left, ps.rcPaint.top, SRCCOPY);
        SelectObject(memory, old);
        DeleteObject(bitmap);
        DeleteDC(memory);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_LBUTTONDOWN:
        click({GET_X_LPARAM(lp), GET_Y_LPARAM(lp)});
        return 0;
    case WM_MOUSEMOVE: {
        POINT pt{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        int hover = -1;
        for (int i = 0; i < 5; ++i)
            if (PtInRect(&navRects_[i], pt)) hover = i;
        if (hover != hoverNav_) {
            hoverNav_ = hover;
            RECT nav{0, 0, px(kNavWidth), px(kWindowHeight)};
            InvalidateRect(hwnd, &nav, FALSE);
            TRACKMOUSEEVENT track{sizeof track, TME_LEAVE, hwnd, 0};
            TrackMouseEvent(&track);
        }
        return 0;
    }
    case WM_MOUSELEAVE:
        if (hoverNav_ != -1) {
            hoverNav_ = -1;
            RECT nav{0, 0, px(kNavWidth), px(kWindowHeight)};
            InvalidateRect(hwnd, &nav, FALSE);
        }
        return 0;
    case WM_SETCURSOR: {
        POINT pt;
        GetCursorPos(&pt);
        ScreenToClient(hwnd, &pt);
        bool hand = false;
        for (int i = 0; i < 5; ++i) hand |= PtInRect(&navRects_[i], pt) != 0;
        if (page_ == 0)
            for (const auto& dot : cornerDots_) {
                RECT hit = dot;
                InflateRect(&hit, px(8), px(8));
                hand |= PtInRect(&hit, pt) != 0;
            }
        if (page_ == 1) hand |= PtInRect(&pinStrip_, pt) && !pinRows_.empty();
        if (hand && LOWORD(lp) == HTCLIENT) {
            SetCursor(LoadCursorW(nullptr, IDC_HAND));
            return TRUE;
        }
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORLISTBOX:
    case WM_CTLCOLORSTATIC: {
        Palette pal = palette(dark_);
        HDC dc = HDC(wp);
        int id = GetDlgCtrlID(HWND(lp));
        bool list = id == IdPins || id == IdLayouts;
        SetBkColor(dc, colorref(list ? pal.card : pal.control));
        SetTextColor(dc, colorref(IsWindowEnabled(HWND(lp)) ? pal.text : pal.track));
        return LRESULT(list ? cardBrush_ : controlBrush_);
    }
    case WM_SETTINGCHANGE:
        if (lp && wcscmp(reinterpret_cast<const wchar_t*>(lp), L"ImmersiveColorSet") == 0 && appsUseDarkTheme() != dark_) {
            applyTheme();
            buildPage();
        }
        return 0;
    case WM_DPICHANGED: {
        dpi_ = HIWORD(wp);
        RECT* r = reinterpret_cast<RECT*>(lp);
        SetWindowPos(hwnd, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        applyTheme();
        buildPage();
        return 0;
    }
    case WM_TIMER:
        refreshStatus(); // Bağlantı durumu canlı gösterilir.
        return 0;
    case WM_SHOWWINDOW:
        if (wp) SetTimer(hwnd, 1, 1000, nullptr);
        else KillTimer(hwnd, 1);
        return DefWindowProcW(hwnd, msg, wp, lp);
    case WM_CLOSE:
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}
