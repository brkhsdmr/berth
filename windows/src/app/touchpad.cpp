#include "touchpad.h"
#include <hidsdi.h>
#include <hidpi.h>
#include <algorithm>

#pragma comment(lib, "hid")

namespace {
constexpr USHORT kDigitizerPage = 0x0D, kTouchPad = 0x05;
constexpr USHORT kTipSwitch = 0x42, kContactCount = 0x54;
constexpr USHORT kDesktopPage = 0x01, kX = 0x30, kY = 0x31;
}

bool TouchpadReader::start(HWND target) {
    if (running_) return true;
    RAWINPUTDEVICE rid{kDigitizerPage, kTouchPad, RIDEV_INPUTSINK, target};
    running_ = RegisterRawInputDevices(&rid, 1, sizeof rid) != FALSE;
    target_ = target;
    return running_;
}

void TouchpadReader::stop() {
    if (!running_) return;
    RAWINPUTDEVICE rid{kDigitizerPage, kTouchPad, RIDEV_REMOVE, nullptr};
    RegisterRawInputDevices(&rid, 1, sizeof rid);
    running_ = false;
    devices_.clear();
}

TouchpadReader::Device& TouchpadReader::device(HANDLE handle) {
    auto found = devices_.find(handle);
    if (found != devices_.end()) return found->second;
    Device& d = devices_[handle];
    UINT size = 0;
    if (GetRawInputDeviceInfoW(handle, RIDI_PREPARSEDDATA, nullptr, &size) != 0 || size == 0) return d;
    d.preparsed.resize(size);
    if (GetRawInputDeviceInfoW(handle, RIDI_PREPARSEDDATA, d.preparsed.data(), &size) == UINT(-1)) return d;
    auto preparsed = reinterpret_cast<PHIDP_PREPARSED_DATA>(d.preparsed.data());
    HIDP_CAPS caps{};
    if (HidP_GetCaps(preparsed, &caps) != HIDP_STATUS_SUCCESS || caps.NumberInputValueCaps == 0) return d;
    std::vector<HIDP_VALUE_CAPS> values(caps.NumberInputValueCaps);
    USHORT count = caps.NumberInputValueCaps;
    if (HidP_GetValueCaps(HidP_Input, values.data(), &count, preparsed) != HIDP_STATUS_SUCCESS) return d;
    // Her parmak: X ve Y'si olan bir bağlantı koleksiyonu.
    std::map<USHORT, Finger> fingers;
    for (USHORT i = 0; i < count; ++i) {
        const auto& v = values[i];
        if (v.UsagePage != kDesktopPage || v.IsRange) continue;
        USHORT usage = v.NotRange.Usage;
        if (usage != kX && usage != kY) continue;
        Finger& f = fingers[v.LinkCollection];
        f.link = v.LinkCollection;
        if (usage == kX) { f.minX = v.LogicalMin; f.maxX = v.LogicalMax; }
        else { f.minY = v.LogicalMin; f.maxY = v.LogicalMax; }
    }
    for (auto& [link, f] : fingers)
        if (f.maxX > f.minX && f.maxY > f.minY) d.fingers.push_back(f);
    d.usable = !d.fingers.empty();
    return d;
}

bool TouchpadReader::read(LPARAM input, std::vector<TouchPoint>& contacts) {
    UINT size = 0;
    if (GetRawInputData(HRAWINPUT(input), RID_INPUT, nullptr, &size, sizeof(RAWINPUTHEADER)) != 0 || size == 0) return false;
    if (buffer_.size() < size) buffer_.resize(size);
    if (GetRawInputData(HRAWINPUT(input), RID_INPUT, buffer_.data(), &size, sizeof(RAWINPUTHEADER)) == UINT(-1)) return false;
    auto* raw = reinterpret_cast<RAWINPUT*>(buffer_.data());
    if (raw->header.dwType != RIM_TYPEHID) return false;
    Device& d = device(raw->header.hDevice);
    if (!d.usable) return false;
    auto preparsed = reinterpret_cast<PHIDP_PREPARSED_DATA>(d.preparsed.data());

    bool complete = false;
    const DWORD reportSize = raw->data.hid.dwSizeHid;
    for (DWORD r = 0; r < raw->data.hid.dwCount; ++r) {
        auto* report = reinterpret_cast<PCHAR>(raw->data.hid.bRawData + r * reportSize);
        ULONG count = 0;
        if (HidP_GetUsageValue(HidP_Input, kDigitizerPage, 0, kContactCount, &count, preparsed, report, reportSize) != HIDP_STATUS_SUCCESS)
            count = 0;
        if (count > 0) {
            // Yeni çerçeve.
            d.expected = count;
            d.received = 0;
            d.pending.clear();
        } else if (d.received >= d.expected) {
            continue; // Çerçevesi belli olmayan rapor.
        }
        ULONG slots = std::min<ULONG>(ULONG(d.fingers.size()), d.expected - d.received);
        for (ULONG i = 0; i < slots; ++i) {
            const Finger& f = d.fingers[i];
            USAGE usages[16];
            ULONG length = 16;
            bool tip = false;
            if (HidP_GetUsages(HidP_Input, kDigitizerPage, f.link, usages, &length, preparsed, report, reportSize) == HIDP_STATUS_SUCCESS)
                for (ULONG u = 0; u < length; ++u) tip = tip || usages[u] == kTipSwitch;
            if (!tip) continue;
            ULONG x = 0, y = 0;
            if (HidP_GetUsageValue(HidP_Input, kDesktopPage, f.link, kX, &x, preparsed, report, reportSize) != HIDP_STATUS_SUCCESS) continue;
            if (HidP_GetUsageValue(HidP_Input, kDesktopPage, f.link, kY, &y, preparsed, report, reportSize) != HIDP_STATUS_SUCCESS) continue;
            d.pending.push_back({double(LONG(x) - f.minX) / double(f.maxX - f.minX), double(LONG(y) - f.minY) / double(f.maxY - f.minY)});
        }
        d.received += slots;
        if (d.received >= d.expected) {
            contacts = d.pending;
            complete = true;
        }
    }
    return complete;
}
