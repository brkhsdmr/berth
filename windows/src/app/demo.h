// Yalnızca debug derlemesi: tanıtım görüntüleri için pencere içerikleri yerine iskelet çizilir.
// %APPDATA%\Berth\skeleton.on dosyası varsa DWM önizlemesi kaydedilmez, başlık yerine uygulama adı
// görünür. Mac'teki `skeletonPreviews` ayarının karşılığı.
#pragma once
#ifdef DEBUG
#include <windows.h>
#include <shlobj.h>
#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace demo {

inline bool skeletons() {
    static const bool on = [] {
        wchar_t* base = nullptr;
        bool found = false;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) {
            found = GetFileAttributesW((std::wstring(base) + L"\\Berth\\skeleton.on").c_str()) != INVALID_FILE_ATTRIBUTES;
            CoTaskMemFree(base);
        }
        return found;
    }();
    return on;
}

struct Image {
    int width = 0, height = 0;
    std::vector<uint32_t> pixels; // BGRA
};

/// Pencerenin en-boy oranında iskelet: gerçek görüntüden yalnızca boyutu alınır. Üç düzen var, aynı
/// pencere hep aynısını alır. Mac'teki karşılığı `DemoMode.skeleton`; değişiklik ikisine de yapılır.
inline Image skeleton(HWND hwnd) {
    Image result;
    RECT r{};
    GetWindowRect(hwnd, &r);
    int w = r.right - r.left, h = r.bottom - r.top;
    if (w <= 0 || h <= 0) return result;
    const int W = 960, H = (std::max)(1, 960 * h / w);
    result.width = W;
    result.height = H;
    result.pixels.assign(size_t(W) * H, 0xFFFFFFFF);
    const uint32_t blue = 0xFF2954F5, ink = 0xFF333640, soft = 0xFFCCCFD6, panel = 0xFFF2F5F7;

    uint32_t seed = uint32_t(reinterpret_cast<uintptr_t>(hwnd) >> 2);
    uint32_t state = (seed * 2654435761u) | 1;
    auto random = [&] {
        state = state * 1664525u + 1013904223u;
        return double((state >> 16) & 0xFFFF) / 65535;
    };
    auto put = [&](int x, int y, uint32_t color) {
        if (x >= 0 && x < W && y >= 0 && y < H) result.pixels[size_t(y) * W + x] = color;
    };
    auto rect = [&](double x, double y, double length, double height, uint32_t color) {
        for (int py = int(y); py < int(y + height); ++py)
            for (int px = int(x); px < int(x + length); ++px) put(px, py, color);
    };
    auto dot = [&](double x, double y, double size, uint32_t color) {
        double radius = size / 2, cx = x + radius, cy = y + radius;
        for (int py = int(y); py <= int(y + size); ++py)
            for (int px = int(x); px <= int(x + size); ++px)
                if ((px - cx) * (px - cx) + (py - cy) * (py - cy) <= radius * radius) put(px, py, color);
    };
    const double t = 8;
    auto line = [&](double x, double y, double length, uint32_t color) {
        rect(x + t / 2, y, length - t, t, color);
        dot(x, y, t, color);
        dot(x + length - t, y, t, color);
    };
    const double pad = 60;
    switch (seed % 3) {
    case 0: // Sol başlık, üç sütun
        dot(pad, pad, 34, blue);
        line(pad, pad + 62, 130, blue);
        line(pad, pad + 92, 90, ink);
        for (double y = pad; y < H - pad - 120; y += 190) {
            for (double x : {0.36, 0.58, 0.8}) {
                line(W * x, y, 130, ink);
                for (int row = 1; row <= 3; ++row) line(W * x, y + row * 34, 90 + random() * 50, soft);
            }
        }
        break;
    case 1: { // Belge
        dot(pad, pad, 34, blue);
        line(pad + 56, pad + 12, 260, ink);
        double y = pad + 90;
        for (int row = 0; y < H - pad; ++row) {
            line(pad, y, (W - 2 * pad) * (row % 4 == 3 ? 0.3 + random() * 0.3 : 0.8 + random() * 0.2), soft);
            y += row % 4 == 3 ? 72 : 36;
        }
        break;
    }
    default: // Kenar çubuğu
        rect(0, 0, W * 0.26, H, panel);
        dot(pad / 2 + 10, pad, 34, blue);
        for (double y = pad + 70; y < H - pad; y += 44) line(pad / 2 + 10, y, 70 + random() * 90, soft);
        line(W * 0.32, pad + 12, 240, ink);
        for (double y = pad + 76; y < H - pad; y += 136) {
            line(W * 0.32, y, 170, blue);
            line(W * 0.32, y + 32, W * 0.62 * (0.6 + random() * 0.4), soft);
            line(W * 0.32, y + 64, W * 0.62 * (0.4 + random() * 0.4), soft);
        }
        break;
    }
    return result;
}

} // namespace demo
#endif
