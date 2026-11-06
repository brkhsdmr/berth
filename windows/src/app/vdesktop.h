// Windows'un sanal masaüstü arayüzleri. Belgesizin tamamı bu dosya çiftindedir.
// Arayüz bulunamazsa (Windows güncellemesi kimlikleri değiştirirse) available() false döner,
// uygulama çalışmaya devam eder, yalnızca masaüstü şeridi kaybolur.
#pragma once
#include <windows.h>
#include <string>
#include <vector>

struct DesktopInfo {
    GUID id{};
    std::wstring name;
    bool current = false;
};

class VirtualDesktops {
public:
    bool init();
    bool available() const { return internal_ != nullptr; }
    std::vector<DesktopInfo> list();
    bool switchTo(const GUID& id);
    /// Pencerenin masaüstü kimliği; bulunamazsa false.
    bool desktopOf(HWND window, GUID& out) const;
    bool isOnCurrent(HWND window) const;
    /// Başka sürecin penceresini de taşır (Windows 11 25H2'de ölçüldü).
    bool moveWindow(HWND window, const GUID& desktop);
    bool moveDesktop(const GUID& desktop, UINT index);
    bool create(GUID& out);
    bool remove(const GUID& desktop, const GUID& fallback);
private:
    struct IVDMI* internal_ = nullptr;
    struct IAVC* views_ = nullptr;
    struct IVirtualDesktopManager* public_ = nullptr;
};
