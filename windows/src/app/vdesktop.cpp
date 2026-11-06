#include "vdesktop.h"
#include <objbase.h>
#include <objectarray.h>
#include <servprov.h>
#include <shobjidl_core.h>
#include <winstring.h>

// Kimlikler ve metot sırası Windows 11 25H2 (26200) üzerinde ölçüldü.
struct IVD : IUnknown {
    virtual HRESULT __stdcall IsViewVisible(IUnknown*, UINT*) = 0;
    virtual HRESULT __stdcall GetID(GUID*) = 0;
    virtual HRESULT __stdcall GetName(HSTRING*) = 0;
    virtual HRESULT __stdcall GetWallpaper(HSTRING*) = 0;
};
struct IVDMI : IUnknown {
    virtual HRESULT __stdcall GetCount(UINT*) = 0;
    virtual HRESULT __stdcall MoveView(IUnknown*, IVD*) = 0;
    virtual HRESULT __stdcall CanMove(IUnknown*, int*) = 0;
    virtual HRESULT __stdcall GetCurrent(IVD**) = 0;
    virtual HRESULT __stdcall GetDesktops(IObjectArray**) = 0;
    virtual HRESULT __stdcall GetAdjacent(IVD*, UINT, IVD**) = 0;
    virtual HRESULT __stdcall Switch(IVD*) = 0;
    virtual HRESULT __stdcall SwitchAndMove(IVD*) = 0;
    virtual HRESULT __stdcall Create(IVD**) = 0;
    virtual HRESULT __stdcall MoveDesktop(IVD*, UINT) = 0;
    virtual HRESULT __stdcall Remove(IVD*, IVD*) = 0;
    virtual HRESULT __stdcall Find(const GUID*, IVD**) = 0;
};

struct IAVC : IUnknown {
    virtual HRESULT __stdcall GetViews(void*) = 0;
    virtual HRESULT __stdcall GetViewsByZOrder(void*) = 0;
    virtual HRESULT __stdcall GetViewsByAumid(PCWSTR, void*) = 0;
    virtual HRESULT __stdcall GetViewForHwnd(HWND, IUnknown**) = 0;
};

static const IID kIidAVC = {0x1841c6d7, 0x4f9d, 0x42c0, {0xaf, 0x41, 0x87, 0x47, 0x53, 0x8f, 0x10, 0xe5}};
static const CLSID kShell = {0xC2F03A33, 0x21F5, 0x47FA, {0xB4, 0xBB, 0x15, 0x63, 0x62, 0xA2, 0xF2, 0x39}};
static const GUID kServiceVDMI = {0xC5E0CDCA, 0x7B6E, 0x41B2, {0x9F, 0xC4, 0xD9, 0x39, 0x75, 0xCC, 0x46, 0x7B}};
static const IID kIidVDMI = {0x53F5CA0B, 0x158F, 0x4124, {0x90, 0x0C, 0x05, 0x71, 0x58, 0x06, 0x0B, 0x27}};
static const IID kIidVD = {0x3F07F4BE, 0xB107, 0x441A, {0xAF, 0x0F, 0x39, 0xD8, 0x25, 0x29, 0x07, 0x2C}};
static const CLSID kPublic = {0xAA509086, 0x5CA9, 0x4C25, {0x8F, 0x95, 0x58, 0x9D, 0x3C, 0x07, 0xB4, 0x8A}};

bool VirtualDesktops::init() {
    CoCreateInstance(kPublic, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&public_));
    IServiceProvider* provider = nullptr;
    if (FAILED(CoCreateInstance(kShell, nullptr, CLSCTX_LOCAL_SERVER, IID_PPV_ARGS(&provider)))) return false;
    HRESULT hr = provider->QueryService(kServiceVDMI, kIidVDMI, reinterpret_cast<void**>(&internal_));
    if (FAILED(provider->QueryService(kIidAVC, kIidAVC, reinterpret_cast<void**>(&views_)))) views_ = nullptr;
    provider->Release();
    if (FAILED(hr)) internal_ = nullptr;
    return internal_ != nullptr;
}

std::vector<DesktopInfo> VirtualDesktops::list() {
    std::vector<DesktopInfo> result;
    if (!internal_) return result;
    GUID currentId{};
    IVD* current = nullptr;
    if (SUCCEEDED(internal_->GetCurrent(&current)) && current) {
        current->GetID(&currentId);
        current->Release();
    }
    IObjectArray* desktops = nullptr;
    if (FAILED(internal_->GetDesktops(&desktops)) || !desktops) return result;
    UINT count = 0;
    desktops->GetCount(&count);
    for (UINT i = 0; i < count; ++i) {
        IVD* d = nullptr;
        if (FAILED(desktops->GetAt(i, kIidVD, reinterpret_cast<void**>(&d)))) continue;
        DesktopInfo info;
        d->GetID(&info.id);
        HSTRING name = nullptr;
        if (SUCCEEDED(d->GetName(&name)) && name) {
            info.name = WindowsGetStringRawBuffer(name, nullptr);
            WindowsDeleteString(name);
        }
        info.current = IsEqualGUID(info.id, currentId) != 0;
        result.push_back(info);
        d->Release();
    }
    desktops->Release();
    return result;
}

bool VirtualDesktops::switchTo(const GUID& id) {
    if (!internal_) return false;
    IVD* d = nullptr;
    if (FAILED(internal_->Find(&id, &d)) || !d) return false;
    HRESULT hr = internal_->Switch(d);
    d->Release();
    return SUCCEEDED(hr);
}

bool VirtualDesktops::moveWindow(HWND window, const GUID& desktop) {
    if (!internal_ || !views_) return false;
    IUnknown* view = nullptr;
    IVD* target = nullptr;
    bool ok = false;
    if (SUCCEEDED(views_->GetViewForHwnd(window, &view)) && view && SUCCEEDED(internal_->Find(&desktop, &target)) && target) {
        ok = SUCCEEDED(internal_->MoveView(view, target));
    }
    if (target) target->Release();
    if (view) view->Release();
    return ok;
}

bool VirtualDesktops::moveDesktop(const GUID& desktop, UINT index) {
    if (!internal_) return false;
    IVD* d = nullptr;
    if (FAILED(internal_->Find(&desktop, &d)) || !d) return false;
    HRESULT hr = internal_->MoveDesktop(d, index);
    d->Release();
    return SUCCEEDED(hr);
}

bool VirtualDesktops::create(GUID& out) {
    if (!internal_) return false;
    IVD* d = nullptr;
    if (FAILED(internal_->Create(&d)) || !d) return false;
    d->GetID(&out);
    d->Release();
    return true;
}

bool VirtualDesktops::remove(const GUID& desktop, const GUID& fallback) {
    if (!internal_) return false;
    IVD* d = nullptr;
    IVD* f = nullptr;
    bool ok = false;
    if (SUCCEEDED(internal_->Find(&desktop, &d)) && d && SUCCEEDED(internal_->Find(&fallback, &f)) && f) {
        ok = SUCCEEDED(internal_->Remove(d, f));
    }
    if (d) d->Release();
    if (f) f->Release();
    return ok;
}

bool VirtualDesktops::desktopOf(HWND window, GUID& out) const {
    return public_ && SUCCEEDED(public_->GetWindowDesktopId(window, &out));
}

bool VirtualDesktops::isOnCurrent(HWND window) const {
    BOOL on = TRUE;
    if (public_) public_->IsWindowOnCurrentVirtualDesktop(window, &on);
    return on != FALSE;
}
