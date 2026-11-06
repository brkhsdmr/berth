#define NOMINMAX
#include "text.h"
#include "layouts.h"
#include <dwmapi.h>
#include <shlobj.h>
#include <algorithm>
#include <fstream>
#include <set>
#include <sstream>

#pragma comment(lib, "dwmapi")

namespace {

std::wstring layoutsPath() {
    PWSTR base = nullptr;
    std::wstring path;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) {
        path = std::wstring(base) + L"\\Berth";
        CreateDirectoryW(path.c_str(), nullptr);
        path += L"\\layouts.txt";
    }
    CoTaskMemFree(base);
    return path;
}

std::vector<std::string> split(const std::string& line) {
    std::vector<std::string> parts;
    std::string part;
    std::istringstream in(line);
    while (std::getline(in, part, '\t')) parts.push_back(part);
    return parts;
}

std::string clean(std::string s) {
    std::replace(s.begin(), s.end(), '\t', ' ');
    std::replace(s.begin(), s.end(), '\n', ' ');
    return s;
}

} // namespace

// Biçim: "L<TAB>ad" satırından sonra o düzenin pencereleri
// "W<TAB>masaüstü<TAB>küçük<TAB>sol<TAB>üst<TAB>sağ<TAB>alt<TAB>uygulama<TAB>başlık".
std::vector<SavedLayout> loadLayouts() {
    std::vector<SavedLayout> layouts;
    std::ifstream in(layoutsPath());
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto parts = split(line);
        if (parts.size() >= 2 && parts[0] == "L") {
            SavedLayout layout;
            layout.name = fromUtf8(parts[1]);
            if (parts.size() >= 4) {
                layout.hotkeyMods = UINT(std::strtoul(parts[2].c_str(), nullptr, 10));
                layout.hotkeyKey = UINT(std::strtoul(parts[3].c_str(), nullptr, 10));
            }
            layouts.push_back(layout);
        } else if (parts.size() >= 8 && parts[0] == "W" && !layouts.empty()) {
            SavedWindow w;
            w.desktop = std::atoi(parts[1].c_str());
            w.minimized = parts[2] == "1";
            w.frame = {std::atoi(parts[3].c_str()), std::atoi(parts[4].c_str()), std::atoi(parts[5].c_str()), std::atoi(parts[6].c_str())};
            w.appId = parts[7];
            w.title = parts.size() > 8 ? fromUtf8(parts[8]) : L"";
            w.handle = parts.size() > 9 ? std::strtoull(parts[9].c_str(), nullptr, 10) : 0;
            if (parts.size() > 10) w.path = fromUtf8(parts[10]);
            if (parts.size() > 11) w.aumid = fromUtf8(parts[11]);
            layouts.back().windows.push_back(w);
        }
    }
    return layouts;
}

void saveLayouts(const std::vector<SavedLayout>& layouts) {
    std::ofstream out(layoutsPath(), std::ios::trunc);
    for (const auto& layout : layouts) {
        out << "L\t" << clean(toUtf8(layout.name)) << '\t' << layout.hotkeyMods << '\t' << layout.hotkeyKey << '\n';
        for (const auto& w : layout.windows)
            out << "W\t" << w.desktop << '\t' << (w.minimized ? 1 : 0) << '\t' << w.frame.left << '\t' << w.frame.top << '\t'
                << w.frame.right << '\t' << w.frame.bottom << '\t' << clean(w.appId) << '\t' << clean(toUtf8(w.title)) << '\t' << w.handle
                << '\t' << clean(toUtf8(w.path)) << '\t' << clean(toUtf8(w.aumid)) << '\n';
    }
}

std::wstring nextLayoutName(const std::vector<SavedLayout>& layouts) {
    for (int n = 1;; ++n) {
        std::wstring name = tx(L"Düzen ", L"Layout ") + std::to_wstring(n);
        if (std::none_of(layouts.begin(), layouts.end(), [&](const SavedLayout& l) { return l.name == name; })) return name;
    }
}

SavedLayout captureLayout(const Snapshot& snapshot, const std::wstring& name) {
    SavedLayout layout;
    layout.name = name;
    std::vector<const SceneWindow*> all;
    for (const auto& [id, app] : snapshot.apps)
        for (const auto& w : app.windows) all.push_back(&w);
    std::sort(all.begin(), all.end(), [](auto* a, auto* b) { return a->zRank > b->zRank; });
    for (const auto* w : all) {
        SavedWindow saved{w->appId, w->title, w->frame, -1, w->minimized, reinterpret_cast<unsigned long long>(w->hwnd)};
        auto app = snapshot.apps.find(w->appId);
        if (app != snapshot.apps.end()) {
            saved.path = app->second.path;
            saved.aumid = app->second.aumid;
        }
        for (size_t i = 0; i < snapshot.desktops.size(); ++i)
            if (w->hasDesktop && IsEqualGUID(snapshot.desktops[i].id, w->desktop)) saved.desktop = int(i);
        // Küçültülmüş pencerenin konumu anlamsızdır (-32000); geri yüklenince eski yerine döner.
        if (w->minimized) {
            WINDOWPLACEMENT placement{sizeof placement};
            if (GetWindowPlacement(w->hwnd, &placement)) saved.frame = placement.rcNormalPosition;
        }
        layout.windows.push_back(saved);
    }
    return layout;
}

int launchMissingApps(const SavedLayout& layout, const Snapshot& snapshot) {
    std::set<std::string> launched;
    for (const auto& w : layout.windows) {
        if (snapshot.apps.count(w.appId) || launched.count(w.appId) || (w.path.empty() && w.aumid.empty())) continue;
        launchApp(w.path, w.aumid);
        launched.insert(w.appId);
    }
    return int(launched.size());
}

int restoreLayout(const SavedLayout& layout, const Snapshot& snapshot, VirtualDesktops& desktops) {
    std::vector<const SceneWindow*> current;
    for (const auto& [id, app] : snapshot.apps)
        for (const auto& w : app.windows) current.push_back(&w);

    // Mac'teki LayoutMatcher ile aynı kural: önce aynı pencere, sonra uygulama ve başlık, sonra
    // aynı uygulamanın kalanları.
    std::set<size_t> used;
    std::vector<int> match(layout.windows.size(), -1);
    for (int round = 0; round < 3; ++round) {
        for (size_t i = 0; i < layout.windows.size(); ++i) {
            if (match[i] >= 0) continue;
            for (size_t j = 0; j < current.size(); ++j) {
                if (used.count(j) || current[j]->appId != layout.windows[i].appId) continue;
                if (round == 0 && reinterpret_cast<unsigned long long>(current[j]->hwnd) != layout.windows[i].handle) continue;
                if (round == 1 && current[j]->title != layout.windows[i].title) continue;
                match[i] = int(j);
                used.insert(j);
                break;
            }
        }
    }

    int moved = 0;
    for (size_t i = 0; i < layout.windows.size(); ++i) {
        if (match[i] < 0) continue;
        const SavedWindow& saved = layout.windows[i];
        const SceneWindow& window = *current[match[i]];
        HWND hwnd = window.hwnd;
        if (saved.desktop >= 0 && saved.desktop < int(snapshot.desktops.size()))
            desktops.moveWindow(hwnd, snapshot.desktops[saved.desktop].id);
        if (saved.minimized) {
            WINDOWPLACEMENT placement{sizeof placement};
            GetWindowPlacement(hwnd, &placement);
            placement.rcNormalPosition = saved.frame;
            placement.showCmd = SW_SHOWMINNOACTIVE;
            SetWindowPlacement(hwnd, &placement);
            ++moved;
            continue;
        }
        if (IsIconic(hwnd) || IsZoomed(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        // Kayıt görünen kenarlarla; SetWindowPos görünmeyen gölge payı dahil dış çerçeve ister.
        // Pay, geri yüklendikten sonra ölçülür: küçültülmüş pencerenin çerçevesi anlamsızdır.
        RECT outer{}, visible{};
        GetWindowRect(hwnd, &outer);
        if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &visible, sizeof visible))) visible = outer;
        RECT target{saved.frame.left - (visible.left - outer.left), saved.frame.top - (visible.top - outer.top),
                    saved.frame.right + (outer.right - visible.right), saved.frame.bottom + (outer.bottom - visible.bottom)};
        // Arkadan öne sırayla en üste alınır: sonunda kayıttaki sıra oluşur.
        if (SetWindowPos(hwnd, HWND_TOP, target.left, target.top, target.right - target.left, target.bottom - target.top,
                         SWP_NOACTIVATE | SWP_NOOWNERZORDER)) ++moved;
    }
    return moved;
}
