#include "text.h"
#include "settings.h"
#include <windows.h>

namespace text {

bool english() {
    // Dil oturum boyunca değişmez: değiştirilen ayar yeniden başlatınca geçerli olur.
    static const bool value = [] {
        int chosen = Settings::load().language;
        if (chosen == Turkish) return false;
        if (chosen == English) return true;
        return PRIMARYLANGID(GetUserDefaultUILanguage()) != LANG_TURKISH;
    }();
    return value;
}

std::wstring windows(size_t n) {
    if (!english()) return std::to_wstring(n) + L" pencere";
    return std::to_wstring(n) + (n == 1 ? L" window" : L" windows");
}

std::wstring apps(size_t n) {
    if (!english()) return std::to_wstring(n) + L" uygulama";
    return std::to_wstring(n) + (n == 1 ? L" app" : L" apps");
}

const wchar_t* locale() { return english() ? L"en-US" : L"tr-TR"; }

} // namespace text
