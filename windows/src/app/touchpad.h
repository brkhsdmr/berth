// Hassas dokunmatik yüzeyin (Precision Touchpad) ham dokunmaları. Windows'un kendi üç parmak
// hareketlerinden bağımsız: Berth hareketi parmak konumlarından kendisi tanır, Windows'un hareketi
// bitirip kısayol göndermesini beklemez. Windows'taki üç parmak hareketleri "Hiçbir şey" yapılmazsa
// ikisi birlikte çalışır.
//
// Raw Input ile digitizer (kullanım sayfası 0x0D, kullanım 0x05) okunur; arka plandayken de gelir
// (RIDEV_INPUTSINK). Raporlar HID ayrıştırıcısıyla (hid.dll) çözülür: her parmak bir bağlantı
// koleksiyonundadır. "Karma" kipte bir çerçevenin parmakları birden çok rapora bölünür; ilk raporun
// parmak sayısı (0x54) çerçevenin kaç parmak süreceğini söyler.
#pragma once
#include <windows.h>
#include <map>
#include <vector>
#include "../core/gesture.h"

class TouchpadReader {
public:
    /// `target` WM_INPUT alır. Dokunmatik yüzey yoksa kayıt yine başarılı olur, hiçbir şey gelmez.
    bool start(HWND target);
    void stop();
    bool running() const { return running_; }

    /// WM_INPUT'un lParam'ı. Bir çerçeve tamamlandıysa true; `contacts` yüzeye değen parmaklardır.
    bool read(LPARAM input, std::vector<TouchPoint>& contacts);

private:
    struct Finger {
        USHORT link = 0;
        LONG minX = 0, maxX = 1, minY = 0, maxY = 1;
    };
    struct Device {
        std::vector<BYTE> preparsed;
        std::vector<Finger> fingers;
        bool usable = false;
        // Süren çerçeve.
        ULONG expected = 0, received = 0;
        std::vector<TouchPoint> pending;
    };
    Device& device(HANDLE handle);

    bool running_ = false;
    HWND target_ = nullptr;
    std::map<HANDLE, Device> devices_;
    std::vector<BYTE> buffer_;
};
