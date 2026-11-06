// Görev çubuğu simgesinin üstüne gelince açılan, uygulamanın tüm masaüstlerindeki
// pencerelerini gösteren panel. Mac'teki Dock önizlemesinin karşılığı.
#pragma once
#include <windows.h>
#include <d2d1_1.h>
#include <dwmapi.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <functional>
#include <map>
#include <string>
#include <vector>
#include "../core/geometry.h"
#include "source.h"
#include "vdesktop.h"

struct PreviewCallbacks {
    std::function<void(const SceneWindow&)> activate;
    /// Sahne açıkken panel açılmaz.
    std::function<bool()> blocked;
};

class TaskbarPreview {
public:
    bool init(HINSTANCE instance, ID2D1Factory1* d2d, IDWriteFactory* dwrite, IWICImagingFactory* wic,
              VirtualDesktops* desktops, PreviewCallbacks callbacks);
    /// Ana zamanlayıcıdan çağrılır; imleç görev çubuğunda değilse yalnızca konum karşılaştırır.
    void tick();
    void hide();
    LRESULT handle(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);

private:
    struct Button {
        std::wstring id;    // "Appid: ..." öneki atılmış.
        std::wstring name;  // "Google Chrome - 1 running window" gibi.
        RECT rect{};
        bool operator==(const Button& o) const { return id == o.id && EqualRect(&rect, &o.rect); }
    };
    struct Card {
        SceneWindow window;
        Rect frame, thumb, close;
        HTHUMBNAIL handle = nullptr;
    };

    bool buttonUnderCursor(POINT p, Button& out);
    std::vector<SceneWindow> windowsFor(const Button& button, std::wstring& appName, std::wstring& appPath);
    void show(const Button& button);
    void layoutAndRender();
    void render();
    void clearCards();
    int cardAt(int x, int y) const;
    void trace(const std::wstring& line) const;

    HWND panel_ = nullptr;
    ID2D1Factory1* d2d_ = nullptr;
    IDWriteFactory* dwrite_ = nullptr;
    IWICImagingFactory* wic_ = nullptr;
    VirtualDesktops* desktops_ = nullptr;
    PreviewCallbacks callbacks_;
    struct IUIAutomation* automation_ = nullptr;

    Microsoft::WRL::ComPtr<ID2D1HwndRenderTarget> target_;
    Microsoft::WRL::ComPtr<IDWriteTextFormat> titleFormat_, smallFormat_;

    POINT lastCursor_{-1, -1};
    Button candidate_, shown_;
    bool hasCandidate_ = false, visible_ = false;
    ULONGLONG candidateSince_ = 0, outsideSince_ = 0;
    std::vector<Card> cards_;
    /// Diğer masaüstünde penceresi olmadığı için panel açılmayan simge; imleç ayrılana kadar yeniden sorulmaz.
    Button empty_;
    bool hasEmpty_ = false;
    std::wstring appName_, appPath_;
    /// Uygulamanın tüm pencereleri: başlık düğmeleri hepsine uygulanır, kartlar yalnızca bir kısmını gösterir.
    bool light_ = false;
    double sectionTop_ = 0;
    double scale_ = 1;
    int width_ = 0, height_ = 0;
    int hoverCard_ = -1;
    bool hoverClose_ = false;
    int pressCard_ = -1;
    bool pressClose_ = false;
    bool tracking_ = false;
};
