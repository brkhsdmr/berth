// Kaydedilmiş çalışma düzenleri: pencerelerin masaüstü, yer, boyut ve küçültülme durumu.
// Dosya: %APPDATA%\Berth\layouts.txt
#pragma once
#include <windows.h>
#include <string>
#include <vector>
#include "source.h"
#include "vdesktop.h"

struct SavedWindow {
    std::string appId;
    std::wstring title;
    RECT frame{};        // Görünen kenarlar.
    int desktop = -1;    // Şeritteki sıra; bilinmiyorsa -1.
    bool minimized = false;
    /// Kaydedildiği andaki pencere; hâlâ açıksa eşleştirmede önce o seçilir (aynı başlıklı
    /// pencereler karışmasın). Yeniden başlatmadan sonra geçersizdir, uygulama denetlenir.
    unsigned long long handle = 0;
    /// Uygulama kapalıysa açmak için.
    std::wstring path, aumid;
};

struct SavedLayout {
    std::wstring name;
    /// Düzeni yükleyen kısayol (MOD_*, sanal tuş); 0 ise yok.
    UINT hotkeyMods = 0, hotkeyKey = 0;
    std::vector<SavedWindow> windows;  // Arkadan öne.
};

std::vector<SavedLayout> loadLayouts();
void saveLayouts(const std::vector<SavedLayout>& layouts);
std::wstring nextLayoutName(const std::vector<SavedLayout>& layouts);
SavedLayout captureLayout(const Snapshot& snapshot, const std::wstring& name);
/// Düzende olup çalışmayan uygulamaları başlatır; başlatılan sayı.
int launchMissingApps(const SavedLayout& layout, const Snapshot& snapshot);
/// Taşınan pencere sayısı.
int restoreLayout(const SavedLayout& layout, const Snapshot& snapshot, VirtualDesktops& desktops);
