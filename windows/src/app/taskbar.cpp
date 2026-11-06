#define NOMINMAX
#include "text.h"
#include "taskbar.h"
#include <dwmapi.h>
#include <propkey.h>
#include <propsys.h>
#include <shellapi.h>
#include <shlobj.h>
#include <uiautomation.h>
#include <algorithm>
#include <cwctype>
#include <fstream>

#pragma comment(lib, "propsys")
#pragma comment(lib, "advapi32")
#pragma comment(lib, "oleaut32")

using Microsoft::WRL::ComPtr;

namespace {

constexpr ULONGLONG kDwellMs = 180;
constexpr ULONGLONG kLeaveGraceMs = 300;
/// Windows 11'in kendi önizlemesinin görev çubuğundan taşan kısmı (25H2'de ekran görüntüsünden
/// ölçüldü, nokta cinsinden). Kapatılamadığı için panel onun ötesinde açılır, ikisi üst üste binmez.
/// Önizleme ayrı bir pencere değil, görev çubuğunun içinde çiziliyor; konumu canlı okunamıyor.
/// Görev çubuğu alttayken önizleme yukarı, üstteyken aşağı 171 nokta; yandayken kartlar alt alta
/// dizilir ve önizleme 202 nokta yana taşar, simgeyle dikey ortalanır.
constexpr double kNativePreviewHeight = 171;
constexpr double kNativePreviewWidth = 202;
constexpr double kNativePreviewGap = 10;

enum class TaskbarEdge { Left, Top, Right, Bottom };

/// Görev çubuğunun durduğu kenar: simgenin ekranın hangi kenarına en yakın olduğuna bakılır. Böylece
/// ikinci ekranlardaki görev çubukları ve Windows 11'in yeni konum ayarı da kendiliğinden doğru çıkar.
TaskbarEdge edgeOf(const RECT& button, const RECT& monitor) {
    LONG distances[4] = {button.left - monitor.left, button.top - monitor.top, monitor.right - button.right, monitor.bottom - button.bottom};
    int best = 0;
    for (int i = 1; i < 4; ++i)
        if (distances[i] < distances[best]) best = i;
    return TaskbarEdge(best);
}
const wchar_t* kPanelClass = L"Berth.Preview";

D2D1_RECT_F d2(const Rect& r) { return D2D1::RectF(float(r.x), float(r.y), float(r.right()), float(r.bottom())); }

std::wstring lower(std::wstring s) {
    std::transform(s.begin(), s.end(), s.begin(), [](wchar_t c) { return wchar_t(towlower(c)); });
    return s;
}

bool endsWith(const std::wstring& text, const std::wstring& tail) {
    return text.size() >= tail.size() && text.compare(text.size() - tail.size(), tail.size(), tail) == 0;
}

/// Pencerenin açık uygulama kimliği; görev çubuğu düğmeleri buna göre gruplanır.
std::wstring windowAppId(HWND hwnd) {
    ComPtr<IPropertyStore> store;
    std::wstring id;
    if (SUCCEEDED(SHGetPropertyStoreForWindow(hwnd, IID_PPV_ARGS(&store)))) {
        PROPVARIANT value;
        PropVariantInit(&value);
        if (SUCCEEDED(store->GetValue(PKEY_AppUserModel_ID, &value)) && value.vt == VT_LPWSTR && value.pwszVal) id = value.pwszVal;
        PropVariantClear(&value);
    }
    return id;
}

LRESULT CALLBACK panelProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    auto* self = reinterpret_cast<TaskbarPreview*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    return self ? self->handle(hwnd, msg, wp, lp) : DefWindowProcW(hwnd, msg, wp, lp);
}

} // namespace

bool TaskbarPreview::init(HINSTANCE instance, ID2D1Factory1* d2d, IDWriteFactory* dwrite, IWICImagingFactory* wic,
                          VirtualDesktops* desktops, PreviewCallbacks callbacks) {
    d2d_ = d2d;
    dwrite_ = dwrite;
    wic_ = wic;
    desktops_ = desktops;
    callbacks_ = std::move(callbacks);
    CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER, __uuidof(IUIAutomation), reinterpret_cast<void**>(&automation_));

    WNDCLASSW wc{};
    wc.lpfnWndProc = panelProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kPanelClass;
    RegisterClassW(&wc);
    panel_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE, kPanelClass, L"", WS_POPUP, 0, 0, 1, 1,
                             nullptr, nullptr, instance, nullptr);
    SetWindowLongPtrW(panel_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    // Windows 11'in kendi açılır pencereleri gibi: koyu, yuvarlak köşeli.
    BOOL dark = TRUE;
    DwmSetWindowAttribute(panel_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof dark);
    DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
    DwmSetWindowAttribute(panel_, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof corner);
    return automation_ != nullptr;
}

void TaskbarPreview::trace(const std::wstring& line) const {
    wchar_t* base = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) return;
    std::wstring folder = std::wstring(base) + L"\\Berth";
    CoTaskMemFree(base);
    if (GetFileAttributesW((folder + L"\\trace.on").c_str()) == INVALID_FILE_ATTRIBUTES) return;
    std::ofstream out(folder + L"\\taskbar.log", std::ios::app);
    out << toUtf8(line) << '\n';
}

bool TaskbarPreview::buttonUnderCursor(POINT p, Button& out) {
    if (!automation_) return false;
    ComPtr<IUIAutomationElement> element;
    if (FAILED(automation_->ElementFromPoint(p, element.GetAddressOf())) || !element) return false;
    ComPtr<IUIAutomationTreeWalker> walker;
    automation_->get_ControlViewWalker(walker.GetAddressOf());
    // Simgenin içindeki bir öğeye denk gelinmiş olabilir: düğmeye kadar yukarı çık.
    for (int depth = 0; element && depth < 4; ++depth) {
        BSTR cls = nullptr;
        element->get_CurrentClassName(&cls);
        bool isButton = cls && wcscmp(cls, L"Taskbar.TaskListButtonAutomationPeer") == 0;
        SysFreeString(cls);
        if (isButton) {
            BSTR id = nullptr, name = nullptr;
            element->get_CurrentAutomationId(&id);
            element->get_CurrentName(&name);
            out.id = id ? id : L"";
            out.name = name ? name : L"";
            SysFreeString(id);
            SysFreeString(name);
            if (out.id.rfind(L"Appid: ", 0) == 0) out.id.erase(0, 7);
            element->get_CurrentBoundingRectangle(&out.rect);
            return true;
        }
        if (!walker) break;
        ComPtr<IUIAutomationElement> parent;
        walker->GetParentElement(element.Get(), parent.GetAddressOf());
        element = parent;
    }
    return false;
}

std::vector<SceneWindow> TaskbarPreview::windowsFor(const Button& button, std::wstring& appName, std::wstring& appPath) {
    Snapshot snapshot = readSnapshot(*desktops_);
    std::wstring id = lower(button.id);
    // "{bilinen klasör}\yol\uygulama.exe": klasör kısmı atılıp yolun sonu karşılaştırılır.
    std::wstring relative;
    if (auto brace = id.find(L"}\\"); brace != std::wstring::npos) relative = id.substr(brace + 1);
    std::wstring label = button.name.substr(0, button.name.find(L" - "));

    std::vector<SceneWindow> result;
    for (const auto& [key, app] : snapshot.apps) {
        std::wstring path = lower(app.path);
        bool appMatches = id == path || (!relative.empty() && endsWith(path, relative)) ||
                          (!label.empty() && lower(label) == lower(app.name));
        for (const auto& window : app.windows) {
            std::wstring explicitId = lower(windowAppId(window.hwnd));
            bool matches = explicitId.empty() ? appMatches : explicitId == id;
            if (!matches) continue;
            result.push_back(window);
            appName = app.name;
            appPath = app.path;
        }
    }
    trace(L"dugme id=" + button.id + L" ad=" + label + L" -> " + std::to_wstring(result.size()) + L" pencere");
    return result;
}

void TaskbarPreview::tick() {
    if (callbacks_.blocked && callbacks_.blocked()) {
        if (visible_) hide();
        hasCandidate_ = false;
        return;
    }
    POINT p;
    GetCursorPos(&p);
    ULONGLONG now = GetTickCount64();
    RECT panelRect{};
    if (visible_) GetWindowRect(panel_, &panelRect);
    bool inPanel = visible_ && PtInRect(&panelRect, p);

    HWND tray = FindWindowW(L"Shell_TrayWnd", nullptr);
    RECT trayRect{};
    if (tray) GetWindowRect(tray, &trayRect);
    bool inTray = tray && PtInRect(&trayRect, p);

    if (inTray && (p.x != lastCursor_.x || p.y != lastCursor_.y || !hasCandidate_)) {
        Button button;
        if (buttonUnderCursor(p, button)) {
            if (!hasCandidate_ || !(button == candidate_)) {
                candidate_ = button;
                hasCandidate_ = true;
                candidateSince_ = now;
            }
        } else {
            hasCandidate_ = false;
        }
    } else if (!inTray) {
        hasCandidate_ = false;
    }
    lastCursor_ = p;

    if (!hasCandidate_) hasEmpty_ = false;
    if (hasCandidate_ && now - candidateSince_ >= kDwellMs && !(visible_ && candidate_ == shown_) && !(hasEmpty_ && candidate_ == empty_)) {
        show(candidate_);
    }

    // Windows'un kendi önizlemesi de bu sırada açılıp panelin üstüne biniyor (ölçüldü).
    // Paneli her turda en üste çıkarmak, onu arkada bırakır.
    if (visible_) SetWindowPos(panel_, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);

    // Simgeyle panel arasındaki boşluk için kısa bir süre tanınır.
    bool onShownButton = visible_ && PtInRect(&shown_.rect, p);
    // Simgeden panele giderken imleç Windows'un önizlemesinin üstünden geçer: o koridor da panelden sayılır.
    if (visible_ && !inPanel && !onShownButton) {
        // Panel ile simgeyi kapsayan dikdörtgen; görev çubuğu hangi kenarda olursa olsun aradaki
        // Windows önizlemesini içine alır.
        RECT corridor;
        UnionRect(&corridor, &panelRect, &shown_.rect);
        if (PtInRect(&corridor, p)) inPanel = true;
    }
    if (visible_ && !inPanel && !onShownButton && !(hasCandidate_ && candidate_ == shown_)) {
        if (!outsideSince_) outsideSince_ = now;
        else if (now - outsideSince_ >= kLeaveGraceMs) hide();
    } else {
        outsideSince_ = 0;
    }
}

void TaskbarPreview::clearCards() {
    for (auto& card : cards_) {
        if (card.handle) DwmUnregisterThumbnail(card.handle);
    }
    cards_.clear();
}

void TaskbarPreview::hide() {
    if (!visible_) return;
    visible_ = false;
    outsideSince_ = 0;
    clearCards();
    ShowWindow(panel_, SW_HIDE);
    target_.Reset();
    shown_ = {};
}

namespace {

/// Windows'un görev çubuğu yalnızca bulunulan masaüstündeki pencereleri mi gösteriyor?
/// Windows 11 varsayılanı bu; değer yoksa da öyledir.
bool taskbarShowsCurrentDesktopOnly() {
    DWORD value = 1, size = sizeof value;
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                     L"VirtualDesktopTaskbarFilter", RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) return true;
    return value != 0;
}

bool appsUseLightTheme() {
    DWORD value = 1, size = sizeof value;
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
    return value != 0;
}

} // namespace

void TaskbarPreview::show(const Button& button) {
    std::vector<SceneWindow> windows = windowsFor(button, appName_, appPath_);
    if (windows.empty()) {
        hide();
        empty_ = button;
        hasEmpty_ = true;
        return;
    }
    // Windows'un kendi önizlemesi bulunulan masaüstünü zaten gösteriyor: panel yalnızca diğer
    // masaüstlerindeki pencereler için açılır. Hepsi buradaysa hiçbir şey eklenmez.
    std::vector<SceneWindow> others;
    if (taskbarShowsCurrentDesktopOnly())
        for (const auto& w : windows)
            if (w.hasDesktop && !w.onCurrentDesktop) others.push_back(w);
    if (others.empty()) {
        hide();
        empty_ = button;
        hasEmpty_ = true;
        return;
    }
    shown_ = button;
    clearCards();

    HMONITOR monitor = MonitorFromRect(&button.rect, MONITOR_DEFAULTTONEAREST);
    UINT dpiX = 96, dpiY = 96;
    typedef HRESULT(WINAPI * GetDpi)(HMONITOR, int, UINT*, UINT*);
    if (HMODULE shcore = LoadLibraryW(L"shcore.dll"))
        if (auto fn = reinterpret_cast<GetDpi>(GetProcAddress(shcore, "GetDpiForMonitor"))) fn(monitor, 0, &dpiX, &dpiY);
    scale_ = dpiX / 96.0;
    const double s = scale_;
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);

    // Windows'un kartlarına yakın ölçüler.
    const double cardW = 168 * s, caption = 24 * s, thumbH = 96 * s, gap = 6 * s, pad = 8 * s, header = 6 * s, section = 20 * s;
    double maxW = (info.rcWork.right - info.rcWork.left) - 40 * s;
    int columns = std::max(1, std::min({int(others.size()), 5, int((maxW - 2 * pad + gap) / (cardW + gap))}));
    size_t count = std::min(others.size(), size_t(columns * 2));
    int rows = int((count + columns - 1) / columns);
    double cellH = caption + thumbH;
    width_ = int(std::max(columns * cardW + (columns - 1) * gap + 2 * pad, 200 * s));
    height_ = int(header + section + rows * cellH + (rows - 1) * gap + pad);
    sectionTop_ = header;

    for (size_t i = 0; i < count; ++i) {
        Card card;
        card.window = others[i];
        double x = pad + (i % columns) * (cardW + gap), y = header + section + (i / columns) * (cellH + gap);
        card.frame = {x, y, cardW, cellH};
        Rect area{x + 4 * s, y + caption, cardW - 8 * s, thumbH - 4 * s};
        double aspect = others[i].aspect();
        double w = std::min(area.w, area.h * aspect), h = w / aspect;
        card.thumb = {area.midX() - w / 2, area.y, w, h};
        card.close = {x + cardW - 24 * s, y + 3 * s, 20 * s, 18 * s};
        cards_.push_back(card);
    }

    // Windows'un önizlemesinin ötesinde, simgeye hizalı; çalışma alanının içinde tutulur.
    const RECT& b = button.rect;
    const RECT& work = info.rcWork;
    double centerX = (b.left + b.right) / 2.0 - width_ / 2.0, centerY = (b.top + b.bottom) / 2.0 - height_ / 2.0;
    double x = centerX, y = 0;
    switch (edgeOf(b, info.rcMonitor)) {
    case TaskbarEdge::Bottom: y = b.top - height_ - (kNativePreviewHeight + kNativePreviewGap) * s; break;
    case TaskbarEdge::Top: y = b.bottom + (kNativePreviewHeight + kNativePreviewGap) * s; break;
    case TaskbarEdge::Left: x = b.right + (kNativePreviewWidth + kNativePreviewGap) * s; y = centerY; break;
    case TaskbarEdge::Right: x = b.left - width_ - (kNativePreviewWidth + kNativePreviewGap) * s; y = centerY; break;
    }
    int px = int(std::clamp(x, double(work.left + 8), double(std::max<LONG>(work.left + 8, work.right - width_ - 8))));
    int py = int(std::clamp(y, double(work.top + 8), double(std::max<LONG>(work.top + 8, work.bottom - height_ - 8))));
    SetWindowPos(panel_, HWND_TOPMOST, px, py, width_, height_, SWP_NOACTIVATE);

    light_ = appsUseLightTheme();
    BOOL dark = light_ ? FALSE : TRUE;
    DwmSetWindowAttribute(panel_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof dark);

    target_.Reset();
    d2d_->CreateHwndRenderTarget(D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(), 96, 96),
                                 D2D1::HwndRenderTargetProperties(panel_, D2D1::SizeU(width_, height_)), target_.GetAddressOf());
    float fs = float(s);
    dwrite_->CreateTextFormat(L"Segoe UI Variable Text", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 12 * fs, text::locale(), titleFormat_.ReleaseAndGetAddressOf());
    dwrite_->CreateTextFormat(L"Segoe UI Variable Text", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, 11 * fs, text::locale(), smallFormat_.ReleaseAndGetAddressOf());
    for (auto* f : {titleFormat_.Get(), smallFormat_.Get()}) {
        if (!f) continue;
        f->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        f->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        ComPtr<IDWriteInlineObject> ellipsis;
        dwrite_->CreateEllipsisTrimmingSign(f, ellipsis.GetAddressOf());
        f->SetTrimming(&trim, ellipsis.Get());
    }
    hoverCard_ = -1;
    hoverClose_ = false;
    ShowWindow(panel_, SW_SHOWNOACTIVATE);
    for (auto& card : cards_) {
        if (FAILED(DwmRegisterThumbnail(panel_, card.window.hwnd, &card.handle))) continue;
        DWM_THUMBNAIL_PROPERTIES p{};
        p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_SOURCECLIENTAREAONLY;
        p.rcDestination = {LONG(card.thumb.x), LONG(card.thumb.y), LONG(card.thumb.right()), LONG(card.thumb.bottom())};
        p.fVisible = TRUE;
        p.fSourceClientAreaOnly = FALSE;
        DwmUpdateThumbnailProperties(card.handle, &p);
    }
    visible_ = true;
    outsideSince_ = 0;
    render();
    trace(L"gosterildi " + appName_ + L" " + std::to_wstring(windows.size()) + L" pencere, " + std::to_wstring(cards_.size()) + L" kart");
}

void TaskbarPreview::render() {
    if (!target_) return;
    const double s = scale_;
    // Windows 11 açılır pencerelerinin renkleri.
    D2D1_COLOR_F background = light_ ? D2D1::ColorF(0.953f, 0.953f, 0.953f) : D2D1::ColorF(0.169f, 0.169f, 0.169f);
    D2D1_COLOR_F text = light_ ? D2D1::ColorF(0.1f, 0.1f, 0.1f) : D2D1::ColorF(1, 1, 1);
    D2D1_COLOR_F secondary = light_ ? D2D1::ColorF(0, 0, 0, 0.55f) : D2D1::ColorF(1, 1, 1, 0.6f);
    D2D1_COLOR_F hoverColor = light_ ? D2D1::ColorF(0, 0, 0, 0.06f) : D2D1::ColorF(1, 1, 1, 0.08f);
    target_->BeginDraw();
    target_->Clear(background);
    ComPtr<ID2D1SolidColorBrush> ink, soft, hover, red, white;
    target_->CreateSolidColorBrush(text, ink.GetAddressOf());
    target_->CreateSolidColorBrush(secondary, soft.GetAddressOf());
    target_->CreateSolidColorBrush(hoverColor, hover.GetAddressOf());
    target_->CreateSolidColorBrush(D2D1::ColorF(0.77f, 0.17f, 0.11f), red.GetAddressOf());
    target_->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1), white.GetAddressOf());

    if (!cards_.empty()) {
        std::wstring label = tx(L"Diğer masaüstlerinde", L"On other desktops");
        target_->DrawText(label.c_str(), UINT32(label.size()), smallFormat_.Get(),
                          D2D1::RectF(float(12 * s), float(sectionTop_), float(width_ - 12 * s), float(sectionTop_ + 20 * s)), soft.Get());
    }

    auto desktops = desktops_->list();
    for (size_t i = 0; i < cards_.size(); ++i) {
        const Card& card = cards_[i];
        bool hovered = int(i) == hoverCard_;
        if (hovered) target_->FillRoundedRectangle(D2D1::RoundedRect(d2(card.frame), float(6 * s), float(6 * s)), hover.Get());

        std::wstring place;
        for (size_t d = 0; d < desktops.size(); ++d)
            if (card.window.hasDesktop && IsEqualGUID(desktops[d].id, card.window.desktop))
                place = !desktops[d].name.empty() ? desktops[d].name : tx(L"Masaüstü ", L"Desktop ") + std::to_wstring(d + 1);
        double right = card.frame.right() - 8 * s;
        if (!place.empty() && !hovered) {
            ComPtr<IDWriteTextLayout> layout;
            dwrite_->CreateTextLayout(place.c_str(), UINT32(place.size()), smallFormat_.Get(), float(80 * s), float(24 * s), layout.GetAddressOf());
            DWRITE_TEXT_METRICS m{};
            layout->GetMetrics(&m);
            target_->DrawTextLayout(D2D1::Point2F(float(right - m.width), float(card.frame.y)), layout.Get(), soft.Get());
            right -= m.width + 6 * s;
        }
        if (hovered) right = card.close.x - 4 * s;
        const std::wstring& t = card.window.title;
        target_->DrawText(t.c_str(), UINT32(t.size()), smallFormat_.Get(),
                          D2D1::RectF(float(card.frame.x + 6 * s), float(card.frame.y), float(right), float(card.frame.y + 24 * s)), ink.Get());
        if (hovered) {
            if (hoverClose_) target_->FillRoundedRectangle(D2D1::RoundedRect(d2(card.close), float(4 * s), float(4 * s)), red.Get());
            float cx = float(card.close.midX()), cy = float(card.close.midY()), x = float(4 * s);
            ID2D1Brush* glyph = hoverClose_ ? white.Get() : ink.Get();
            target_->DrawLine(D2D1::Point2F(cx - x, cy - x), D2D1::Point2F(cx + x, cy + x), glyph, float(1.1 * s));
            target_->DrawLine(D2D1::Point2F(cx + x, cy - x), D2D1::Point2F(cx - x, cy + x), glyph, float(1.1 * s));
        }
    }
    target_->EndDraw();
}

int TaskbarPreview::cardAt(int x, int y) const {
    for (size_t i = 0; i < cards_.size(); ++i)
        if (cards_[i].frame.contains(x, y)) return int(i);
    return -1;
}

LRESULT TaskbarPreview::handle(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    int x = short(LOWORD(lp)), y = short(HIWORD(lp));
    switch (msg) {
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_MOUSEMOVE: {
        if (!tracking_) {
            TRACKMOUSEEVENT t{sizeof t, TME_LEAVE, hwnd, 0};
            TrackMouseEvent(&t);
            tracking_ = true;
        }
        int card = cardAt(x, y);
        bool onClose = card >= 0 && cards_[card].close.contains(x, y);
        if (card != hoverCard_ || onClose != hoverClose_) {
            hoverCard_ = card;
            hoverClose_ = onClose;
            render();
        }
        return 0;
    }
    case WM_MOUSELEAVE:
        tracking_ = false;
        hoverCard_ = -1;
        hoverClose_ = false;
        render();
        return 0;
    case WM_LBUTTONDOWN:
        pressCard_ = cardAt(x, y);
        pressClose_ = pressCard_ >= 0 && cards_[pressCard_].close.contains(x, y);
        return 0;
    case WM_LBUTTONUP: {
        int card = cardAt(x, y);
        bool onClose = card >= 0 && cards_[card].close.contains(x, y);
        // Tıklama, basılan yerde bırakmaktır.
        if (card >= 0 && card == pressCard_ && onClose && pressClose_) {
            SceneWindow window = cards_[card].window;
            Button again = shown_;
            PostMessageW(window.hwnd, WM_CLOSE, 0, 0);
            Sleep(250);
            hide();
            if (IsWindow(window.hwnd) && IsWindowVisible(window.hwnd)) {
                // Kapanmadıysa kaydet sorusu çıkmış olabilir: panelin arkasında kalmasın.
                if (callbacks_.activate) callbacks_.activate(window);
            } else {
                show(again);
            }
        } else if (card >= 0 && card == pressCard_ && !onClose) {
            SceneWindow window = cards_[card].window;
            hide();
            if (callbacks_.activate) callbacks_.activate(window);
        }
        pressCard_ = -1;
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}
