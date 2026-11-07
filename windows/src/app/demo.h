// Yalnızca debug derlemesi: tanıtım görüntüleri için pencere içerikleri kaba bloklara iner.
// %APPDATA%\Berth\mosaic.on dosyası varsa DWM önizlemesi kaydedilmez, başlık yerine uygulama adı
// görünür. Mac'teki `mosaicPreviews` ayarının karşılığı.
#pragma once
#ifdef DEBUG
#include <windows.h>
#include <shlobj.h>
#include <cstdint>
#include <string>
#include <vector>

namespace demo {

inline bool mosaic() {
    static const bool on = [] {
        wchar_t* base = nullptr;
        bool found = false;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) {
            found = GetFileAttributesW((std::wstring(base) + L"\\Berth\\mosaic.on").c_str()) != INVALID_FILE_ATTRIBUTES;
            CoTaskMemFree(base);
        }
        return found;
    }();
    return on;
}

struct Blocks {
    int width = 0, height = 0;
    std::vector<uint32_t> pixels; // BGRA
};

/// Pencereyi `columns` blok genişliğe indirir; yakalanamazsa düz gri kalır.
inline Blocks capture(HWND hwnd, int columns = 25) {
    Blocks result;
    RECT r{};
    GetWindowRect(hwnd, &r);
    int w = r.right - r.left, h = r.bottom - r.top;
    if (w <= 0 || h <= 0) return result;
    result.width = columns;
    result.height = (columns * h + w / 2) / w;
    if (result.height < 1) result.height = 1;
    result.pixels.assign(size_t(result.width) * result.height, 0xFF8C8C8C);

    HDC screen = GetDC(nullptr);
    HDC full = CreateCompatibleDC(screen), tiny = CreateCompatibleDC(screen);
    HBITMAP fullBitmap = CreateCompatibleBitmap(screen, w, h);
    BITMAPINFO info{};
    info.bmiHeader = {sizeof(BITMAPINFOHEADER), result.width, -result.height, 1, 32, BI_RGB};
    void* bits = nullptr;
    HBITMAP tinyBitmap = CreateDIBSection(tiny, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ oldFull = SelectObject(full, fullBitmap), oldTiny = SelectObject(tiny, tinyBitmap);
    if (PrintWindow(hwnd, full, 2 /* PW_RENDERFULLCONTENT */) && bits) {
        SetStretchBltMode(tiny, HALFTONE);
        StretchBlt(tiny, 0, 0, result.width, result.height, full, 0, 0, w, h, SRCCOPY);
        GdiFlush();
        auto* source = static_cast<const uint32_t*>(bits);
        for (size_t i = 0; i < result.pixels.size(); ++i) result.pixels[i] = source[i] | 0xFF000000;
    }
    SelectObject(full, oldFull);
    SelectObject(tiny, oldTiny);
    DeleteObject(fullBitmap);
    DeleteObject(tinyBitmap);
    DeleteDC(full);
    DeleteDC(tiny);
    ReleaseDC(nullptr, screen);
    return result;
}

} // namespace demo
#endif
