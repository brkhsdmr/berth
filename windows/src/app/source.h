// Sistemden o anki pencere ve masaüstü durumunu okur. Yalnızca sahne açılırken çağrılır.
#pragma once
#include <windows.h>
#include <map>
#include <string>
#include <vector>
#include "vdesktop.h"

struct SceneWindow {
    HWND hwnd = nullptr;
    std::string appId;
    std::wstring title;
    RECT frame{};       // Ekran koordinatı, görünen kenarlar.
    bool minimized = false;
    bool onCurrentDesktop = true;
    GUID desktop{};
    bool hasDesktop = false;
    int zRank = 0;      // 0 en önde.
    double aspect() const;
};

struct SceneApp {
    std::string id;            // Küçük harfli çalıştırılabilir yol.
    std::wstring path;
    std::wstring name;
    /// Mağaza uygulamasının kimliği; doğrudan yolu çalıştırılamadığı için "shell:AppsFolder\<kimlik>" ile açılır.
    std::wstring aumid;
    bool running = false;
    std::vector<SceneWindow> windows;
};

struct Snapshot {
    std::map<std::string, SceneApp> apps;
    std::vector<DesktopInfo> desktops;
};

Snapshot readSnapshot(VirtualDesktops& desktops);
std::string toUtf8(const std::wstring& s);
/// Uygulamayı başlatır: mağaza uygulamasıysa kimliğiyle, değilse yoluyla.
void launchApp(const std::wstring& path, const std::wstring& aumid);
std::wstring fromUtf8(const std::string& s);
std::wstring appDisplayName(const std::wstring& path);
