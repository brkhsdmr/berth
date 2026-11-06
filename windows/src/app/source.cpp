#include "source.h"
#include "../core/layout.h"
#include <appmodel.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <propkey.h>
#include <propvarutil.h>
#pragma comment(lib, "shell32")
#pragma comment(lib, "ole32")
#pragma comment(lib, "propsys")
#include <dwmapi.h>
#include <algorithm>
#include <cwctype>
#include <set>

double SceneWindow::aspect() const {
    double w = frame.right - frame.left, h = frame.bottom - frame.top;
    return h > 0 ? w / h : 1.6;
}

std::string toUtf8(const std::wstring& s) {
    if (s.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
    std::string out(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n, nullptr, nullptr);
    return out;
}

void launchApp(const std::wstring& path, const std::wstring& aumid) {
    std::wstring target = aumid.empty() ? path : L"shell:AppsFolder\\" + aumid;
    ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

std::wstring fromUtf8(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring out(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
    return out;
}

static std::wstring processPath(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return {};
    wchar_t buffer[MAX_PATH];
    DWORD size = MAX_PATH;
    std::wstring path;
    if (QueryFullProcessImageNameW(h, 0, buffer, &size)) path.assign(buffer, size);
    CloseHandle(h);
    return path;
}

std::wstring appDisplayName(const std::wstring& path) {
    DWORD ignored = 0;
    DWORD size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
    if (size) {
        std::vector<BYTE> data(size);
        if (GetFileVersionInfoW(path.c_str(), 0, size, data.data())) {
            struct Lang { WORD lang, code; }* langs = nullptr;
            UINT len = 0;
            if (VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation", reinterpret_cast<void**>(&langs), &len) && len >= sizeof(Lang)) {
                wchar_t key[64];
                swprintf_s(key, L"\\StringFileInfo\\%04x%04x\\FileDescription", langs[0].lang, langs[0].code);
                wchar_t* text = nullptr;
                if (VerQueryValueW(data.data(), key, reinterpret_cast<void**>(&text), &len) && len > 1) return text;
            }
        }
    }
    auto slash = path.find_last_of(L'\\');
    std::wstring base = slash == std::wstring::npos ? path : path.substr(slash + 1);
    auto dot = base.find_last_of(L'.');
    return dot == std::wstring::npos ? base : base.substr(0, dot);
}

namespace {

/// Pencerenin bildirdiği uygulama kimliği (AUMID). Store uygulamalarının çerçevesi
/// (ApplicationFrameWindow) gerçek süreç askıdayken de kimliği taşır.
std::wstring windowAumid(HWND w) {
    std::wstring id;
    IPropertyStore* store = nullptr;
    if (SUCCEEDED(SHGetPropertyStoreForWindow(w, IID_PPV_ARGS(&store)))) {
        PROPVARIANT value;
        PropVariantInit(&value);
        if (SUCCEEDED(store->GetValue(PKEY_AppUserModel_ID, &value)) && value.vt == VT_LPWSTR && value.pwszVal) id = value.pwszVal;
        PropVariantClear(&value);
        store->Release();
    }
    return id;
}

/// Başlat menüsündeki ad ("Settings", "Terminal"); bulunamazsa boş.
std::wstring aumidDisplayName(const std::wstring& aumid) {
    std::wstring name;
    IShellItem* item = nullptr;
    if (SUCCEEDED(SHCreateItemFromParsingName((L"shell:AppsFolder\\" + aumid).c_str(), nullptr, IID_PPV_ARGS(&item)))) {
        PWSTR text = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_NORMALDISPLAY, &text)) && text) name = text;
        CoTaskMemFree(text);
        item->Release();
    }
    return name;
}

struct Context {
    Snapshot* snapshot;
    VirtualDesktops* desktops;
    DWORD ownPid;
    int rank = 0;
    std::map<std::wstring, std::wstring> names;
};

/// Mağaza uygulamaları ApplicationFrameHost içinde çalışır; asıl süreç çocuk penceredir.
BOOL CALLBACK findCoreChild(HWND child, LPARAM param) {
    wchar_t cls[64];
    GetClassNameW(child, cls, 64);
    if (wcscmp(cls, L"Windows.UI.Core.CoreWindow") == 0) {
        GetWindowThreadProcessId(child, reinterpret_cast<DWORD*>(param));
        return FALSE;
    }
    return TRUE;
}

BOOL CALLBACK onWindow(HWND w, LPARAM param) {
    auto& c = *reinterpret_cast<Context*>(param);
    if (!IsWindowVisible(w) || GetWindow(w, GW_OWNER)) return TRUE;
    LONG_PTR ex = GetWindowLongPtrW(w, GWL_EXSTYLE);
    if ((ex & WS_EX_TOOLWINDOW) && !(ex & WS_EX_APPWINDOW)) return TRUE;
    if (ex & WS_EX_NOACTIVATE) return TRUE;

    wchar_t title[256]{};
    GetWindowTextW(w, title, 256);
    if (!title[0]) return TRUE;

    wchar_t cls[64];
    GetClassNameW(w, cls, 64);
    if (!wcscmp(cls, L"Progman") || !wcscmp(cls, L"WorkerW") || !wcscmp(cls, L"Windows.UI.Core.CoreWindow") ||
        !wcscmp(cls, L"Shell_TrayWnd") || !wcscmp(cls, L"Shell_SecondaryTrayWnd")) return TRUE;

    // Kabuğun gizlediği pencere başka masaüstündedir (ölçüldü: cloak=2); uygulamanın gizlediği elenir.
    DWORD cloak = 0;
    DwmGetWindowAttribute(w, DWMWA_CLOAKED, &cloak, sizeof cloak);
    if (cloak & (DWM_CLOAKED_APP | DWM_CLOAKED_INHERITED)) return TRUE;

    SceneWindow window;
    window.hwnd = w;
    window.title = title;
    window.zRank = c.rank++;
    window.minimized = IsIconic(w) != FALSE;
    window.hasDesktop = c.desktops->desktopOf(w, window.desktop);
    // Görünmez kabuk pencereleri masaüstü kimliği vermez.
    if (cloak && (!window.hasDesktop || IsEqualGUID(window.desktop, GUID{}))) return TRUE;
    window.onCurrentDesktop = c.desktops->isOnCurrent(w);

    if (window.minimized) {
        WINDOWPLACEMENT p{sizeof p};
        GetWindowPlacement(w, &p);
        window.frame = p.rcNormalPosition;
    } else if (FAILED(DwmGetWindowAttribute(w, DWMWA_EXTENDED_FRAME_BOUNDS, &window.frame, sizeof window.frame))) {
        GetWindowRect(w, &window.frame);
    }
    if (window.frame.right - window.frame.left < 80 || window.frame.bottom - window.frame.top < 60) return TRUE;

    DWORD pid = 0;
    GetWindowThreadProcessId(w, &pid);
    if (pid == c.ownPid) return TRUE;
    // Store uygulaması küçültülüp askıya alınınca çocuk pencere yok olur; kimlik çerçeveden okunur.
    // Yoksa tüm böyle uygulamalar "Application Frame Host" adıyla tek uygulamada birleşiyordu.
    std::wstring frameAumid;
    if (!wcscmp(cls, L"ApplicationFrameWindow")) {
        DWORD child = 0;
        EnumChildWindows(w, findCoreChild, reinterpret_cast<LPARAM>(&child));
        if (child) pid = child;
        else frameAumid = windowAumid(w);
    }
    std::wstring path = processPath(pid);
    if (path.empty()) return TRUE; // Yönetici olarak çalışan süreç de buraya düşmez, yetkimiz yeterse okunur.

    std::wstring lower = path;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](wchar_t ch) { return static_cast<wchar_t>(towlower(ch)); });
    window.appId = toUtf8(stableAppPath(lower));
    if (!frameAumid.empty()) {
        std::wstring key = frameAumid;
        std::transform(key.begin(), key.end(), key.begin(), [](wchar_t ch) { return static_cast<wchar_t>(towlower(ch)); });
        window.appId = toUtf8(L"aumid:" + key);
    }

    auto& app = c.snapshot->apps[window.appId];
    if (app.id.empty()) {
        app.id = window.appId;
        app.path = path;
        auto found = c.names.find(lower);
        if (found != c.names.end()) {
            app.name = found->second;
        } else {
            app.name = appDisplayName(path);
            c.names[lower] = app.name;
        }
        app.running = true;
        if (!frameAumid.empty()) {
            app.aumid = frameAumid;
        } else if (HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)) {
            wchar_t id[APPLICATION_USER_MODEL_ID_MAX_LENGTH];
            UINT32 length = APPLICATION_USER_MODEL_ID_MAX_LENGTH;
            if (GetApplicationUserModelId(process, &length, id) == ERROR_SUCCESS) app.aumid = id;
            CloseHandle(process);
        }
        // Paketli uygulamanın adı Başlat menüsündeki addır: dosya açıklaması çoğu zaman yardımcı
        // sürecin adı ("Windows Terminal Host", "Application Frame Host").
        if (!app.aumid.empty()) {
            auto cached = c.names.find(L"aumid:" + app.aumid);
            std::wstring shellName = cached != c.names.end() ? cached->second : aumidDisplayName(app.aumid);
            c.names[L"aumid:" + app.aumid] = shellName;
            if (!shellName.empty()) app.name = shellName;
        }
    }
    app.windows.push_back(window);
    return TRUE;
}

} // namespace

Snapshot readSnapshot(VirtualDesktops& desktops) {
    Snapshot snapshot;
    snapshot.desktops = desktops.list();
    Context context{&snapshot, &desktops, GetCurrentProcessId()};
    EnumWindows(onWindow, reinterpret_cast<LPARAM>(&context));
    // Yığındaki sıra kullanımla değişmesin: pencere tanıtıcısı açılış sırasına yakındır.
    for (auto& [id, app] : snapshot.apps) {
        std::sort(app.windows.begin(), app.windows.end(), [](const SceneWindow& a, const SceneWindow& b) {
            return reinterpret_cast<UINT_PTR>(a.hwnd) < reinterpret_cast<UINT_PTR>(b.hwnd);
        });
    }
    return snapshot;
}
