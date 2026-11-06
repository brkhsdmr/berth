#define NOMINMAX
#include "icon.h"
#include <dwmapi.h>
#include <algorithm>
#include <d2d1.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <vector>

#pragma comment(lib, "d2d1")
#pragma comment(lib, "windowscodecs")
#pragma comment(lib, "dwmapi")
#pragma comment(lib, "advapi32")

using Microsoft::WRL::ComPtr;

namespace {

bool taskbarIsLight() {
    DWORD value = 0, size = sizeof value;
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
    return value != 0;
}

} // namespace

/// Simgeyi çizer. `brand`: dağıtılan dosyalar için sabit marka rengi (vurgu rengi makineye göre değişir).
static ComPtr<IWICBitmap> renderIcon(IWICImagingFactory* wic, int size, bool tray, bool brand) {
    ComPtr<ID2D1Factory> d2d;
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf()))) return nullptr;
    ComPtr<IWICBitmap> bitmap;
    wic->CreateBitmap(size, size, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, bitmap.GetAddressOf());
    ComPtr<ID2D1RenderTarget> rt;
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    if (!bitmap || FAILED(d2d->CreateWicBitmapRenderTarget(bitmap.Get(), props, rt.GetAddressOf()))) return nullptr;

    const float u = size / 16.0f;
    D2D1_COLOR_F ink;
    rt->BeginDraw();
    rt->Clear(D2D1::ColorF(0, 0, 0, 0));
    if (tray) {
        ink = taskbarIsLight() ? D2D1::ColorF(0.1f, 0.1f, 0.1f) : D2D1::ColorF(1, 1, 1);
    } else {
        DWORD color = 0x0067C0; // Windows 11 mavisi
        BOOL opaque = FALSE;
        if (!brand) DwmGetColorizationColor(&color, &opaque);
        ComPtr<ID2D1SolidColorBrush> back;
        rt->CreateSolidColorBrush(D2D1::ColorF(float((color >> 16) & 255) / 255, float((color >> 8) & 255) / 255, float(color & 255) / 255), back.GetAddressOf());
        rt->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(0, 0, float(size), float(size)), 3.5f * u, 3.5f * u), back.Get());
        ink = D2D1::ColorF(1, 1, 1);
    }
    ComPtr<ID2D1SolidColorBrush> brush;
    rt->CreateSolidColorBrush(ink, brush.GetAddressOf());
    // Arkadaki iki pencere çizgi, öndeki dolu: sahnedeki yığın.
    float inset = tray ? 0.0f : 2.0f * u;
    float span = size - 2 * inset;
    float w = span * 0.62f, h = span * 0.5f, step = span * 0.19f, stroke = std::max(1.0f, 1.1f * u);
    for (int i = 0; i < 3; ++i) {
        float x = inset + step * (2 - i) + stroke / 2, y = inset + step * i + stroke / 2;
        D2D1_ROUNDED_RECT r = D2D1::RoundedRect(D2D1::RectF(x, y, x + w, y + h), 1.6f * u, 1.6f * u);
        if (i == 2) rt->FillRoundedRectangle(r, brush.Get());
        else rt->DrawRoundedRectangle(r, brush.Get(), stroke);
    }
    rt->EndDraw();
    return bitmap;
}

HICON makeAppIcon(int size, bool tray) {
    ComPtr<IWICImagingFactory> wic;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))))
        return LoadIconW(nullptr, IDI_APPLICATION);
    ComPtr<IWICBitmap> bitmap = renderIcon(wic.Get(), size, tray, false);
    if (!bitmap) return LoadIconW(nullptr, IDI_APPLICATION);

    std::vector<BYTE> pixels(size_t(size) * size * 4);
    bitmap->CopyPixels(nullptr, size * 4, UINT(pixels.size()), pixels.data());
    BITMAPV5HEADER bi{};
    bi.bV5Size = sizeof bi;
    bi.bV5Width = size;
    bi.bV5Height = -size;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void* bits = nullptr;
    HDC dc = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, dc);
    if (!color) return LoadIconW(nullptr, IDI_APPLICATION);
    memcpy(bits, pixels.data(), pixels.size());
    HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO info{TRUE, 0, 0, mask, color};
    HICON icon = CreateIconIndirect(&info);
    DeleteObject(color);
    DeleteObject(mask);
    return icon ? icon : LoadIconW(nullptr, IDI_APPLICATION);
}

namespace {

/// Bitmap'i PNG olarak belleğe kodlar.
std::vector<BYTE> encodePng(IWICImagingFactory* wic, IWICBitmap* bitmap) {
    std::vector<BYTE> bytes;
    ComPtr<IStream> stream;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, stream.GetAddressOf()))) return bytes;
    ComPtr<IWICBitmapEncoder> encoder;
    wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.GetAddressOf());
    if (!encoder || FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) return bytes;
    ComPtr<IWICBitmapFrameEncode> frame;
    encoder->CreateNewFrame(frame.GetAddressOf(), nullptr);
    frame->Initialize(nullptr);
    UINT w = 0, h = 0;
    bitmap->GetSize(&w, &h);
    frame->SetSize(w, h);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    frame->SetPixelFormat(&format);
    frame->WriteSource(bitmap, nullptr);
    frame->Commit();
    encoder->Commit();
    HGLOBAL memory = nullptr;
    GetHGlobalFromStream(stream.Get(), &memory);
    STATSTG stat{};
    stream->Stat(&stat, STATFLAG_NONAME);
    bytes.resize(size_t(stat.cbSize.QuadPart));
    if (void* data = GlobalLock(memory)) {
        memcpy(bytes.data(), data, bytes.size());
        GlobalUnlock(memory);
    }
    return bytes;
}

bool writeFile(const std::wstring& path, const std::vector<BYTE>& bytes) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    BOOL ok = WriteFile(file, bytes.data(), DWORD(bytes.size()), &written, nullptr);
    CloseHandle(file);
    return ok && written == bytes.size();
}

} // namespace

bool writeIconAssets(const std::wstring& folder) {
    ComPtr<IWICImagingFactory> wic;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)))) return false;

    // .ico: her boyut PNG olarak gömülür (Vista'dan beri desteklenir).
    const int sizes[] = {16, 20, 24, 32, 40, 48, 64, 256};
    std::vector<std::vector<BYTE>> images;
    for (int size : sizes) {
        auto bitmap = renderIcon(wic.Get(), size, false, true);
        if (!bitmap) return false;
        images.push_back(encodePng(wic.Get(), bitmap.Get()));
    }
    std::vector<BYTE> ico;
    auto put16 = [&](WORD v) { ico.push_back(BYTE(v)); ico.push_back(BYTE(v >> 8)); };
    auto put32 = [&](DWORD v) { for (int i = 0; i < 4; ++i) ico.push_back(BYTE(v >> (8 * i))); };
    put16(0); put16(1); put16(WORD(images.size()));
    DWORD offset = 6 + 16 * DWORD(images.size());
    for (size_t i = 0; i < images.size(); ++i) {
        ico.push_back(BYTE(sizes[i] >= 256 ? 0 : sizes[i]));
        ico.push_back(BYTE(sizes[i] >= 256 ? 0 : sizes[i]));
        ico.push_back(0); ico.push_back(0);
        put16(1); put16(32);
        put32(DWORD(images[i].size()));
        put32(offset);
        offset += DWORD(images[i].size());
    }
    for (const auto& image : images) ico.insert(ico.end(), image.begin(), image.end());
    if (!writeFile(folder + L"\\app.ico", ico)) return false;

    // Mağaza paketi logoları.
    struct Logo { const wchar_t* name; int size; } logos[] = {
        {L"Square44x44Logo.png", 44}, {L"Square150x150Logo.png", 150}, {L"StoreLogo.png", 50},
        {L"Square44x44Logo.targetsize-256_altform-unplated.png", 256},
    };
    for (const auto& logo : logos) {
        auto bitmap = renderIcon(wic.Get(), logo.size, false, true);
        if (!bitmap || !writeFile(folder + L"\\" + logo.name, encodePng(wic.Get(), bitmap.Get()))) return false;
    }
    return true;
}
