// Mac sürümündeki NavigatorCore'un karşılığı: sabit hücreli sahne yerleşimi.
//
// Hücrenin yeri yalnızca sıra ve hücre boyutundan gelir. Pencere sayısı girdi değildir,
// bu yüzden pencere açmak ya da kapatmak hiçbir hücrenin yerini değiştiremez.
#pragma once
#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>
#include "geometry.h"

enum class SlotSize { Small, Medium, Large };

inline int slotUnits(SlotSize size) {
    switch (size) {
    case SlotSize::Small: return 2;
    case SlotSize::Medium: return 3;
    default: return 4;
    }
}

/// İlk görüldüğünde verilen boyut. Sonra saklanır ve kendiliğinden değişmez.
/// Uygulama kimliği olarak kullanılan küçük harfli yol. Mağaza uygulamalarının klasöründe sürüm
/// vardır ("claude_4.23118.0.0_x64__pzs8sxrjxfjjc"); güncellemede değişir ve sabit uygulama "kapalı"
/// görünür. Klasör paket ailesi adına indirilir: "claude__pzs8sxrjxfjjc".
inline std::wstring stableAppPath(std::wstring lowerPath) {
    const std::wstring marker = L"\\windowsapps\\";
    auto at = lowerPath.find(marker);
    if (at == std::wstring::npos) return lowerPath;
    size_t start = at + marker.size();
    size_t end = lowerPath.find(L'\\', start);
    std::wstring folder = lowerPath.substr(start, end == std::wstring::npos ? std::wstring::npos : end - start);
    auto first = folder.find(L'_'), last = folder.rfind(L'_');
    if (first == std::wstring::npos || last == first) return lowerPath;
    std::wstring family = folder.substr(0, first) + L"__" + folder.substr(last + 1);
    return lowerPath.substr(0, start) + family + (end == std::wstring::npos ? L"" : lowerPath.substr(end));
}

inline SlotSize initialSlotSize(int windowCount) {
    if (windowCount <= 1) return SlotSize::Small;
    if (windowCount <= 3) return SlotSize::Medium;
    return SlotSize::Large;
}

struct SlotSpec {
    std::string id;
    SlotSize size = SlotSize::Small;
};

struct PlacedSlot {
    std::string id;
    SlotSize size = SlotSize::Small;
    Rect frame; // Yığın ve etiket dahil.
    Rect pile;  // Pencerelerin dizildiği alan.
};

struct StageMetrics {
    double gap = 20;
    double rowGap = 18;
    double labelHeight = 32;
    int maxRows = 6;
};

std::vector<PlacedSlot> placeSlots(const std::vector<SlotSpec>& slots, const Rect& stage, const StageMetrics& metrics = {});

/// Kaydırılarak ulaşılan bölüm: hücreler `top`tan başlar, ortalanmaz. Uygulama çoğaldıkça bölüm
/// uzar; hücreler tek ekrana sığsın diye küçülmez.
std::vector<PlacedSlot> placeSlotsFlowing(const std::vector<SlotSpec>& slots, double x, double width, double top,
                                          double viewportHeight, const StageMetrics& metrics = {});

/// Sürüklenen hücrenin bırakılacağı aralık ve aralığı gösteren çizgi.
struct SlotDrop {
    size_t gap = 0;
    double markX = 0, markTop = 0, markBottom = 0;
    bool operator==(const SlotDrop&) const = default;
};

/// İmlecin altındaki aralık. Satır, imlece dikine en yakın olandır; hücrenin yeri değişmeyecekse
/// (kendi iki yanı) boş döner. `slots` yerleşim sırasındadır.
std::optional<SlotDrop> slotDropAt(double x, double y, size_t moving, const std::vector<PlacedSlot>& slots, double gap);

/// Öğeyi iki komşunun arasına taşır. `gap`, taşımadan önceki sıraya göredir: 0 en baş, boyut en son.
template <class T>
void moveToGap(std::vector<T>& items, size_t index, size_t gap) {
    if (index >= items.size()) return;
    gap = (std::min)(gap, items.size());
    T item = std::move(items[index]);
    items.erase(items.begin() + index);
    items.insert(items.begin() + (gap > index ? gap - 1 : gap), std::move(item));
}

/// Yığında gösterilen en fazla pencere; kalanı "+N" olur.
constexpr int kMaxVisiblePile = 6;

/// Pencereleri hücrenin içine dizer; yığın alanın dibine oturur. `aspects` en-boy oranlarıdır.
std::vector<Rect> pileFrames(const Rect& rect, const std::vector<double>& aspects, double overlap = 0.1);

enum class SnapPosition { LeftHalf, RightHalf, Fill };
/// İki yarım tam noktada buluşur: arada çizgi kalmaz, üst üste de binmezler.
Rect snapFrame(SnapPosition position, const Rect& workArea);
