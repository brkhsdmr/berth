// Yerleşim kurallarının testleri; Mac'teki LayoutTests'in karşılığı. Windows ve Mac'te derlenir.
#include <cmath>
#include <cstdio>
#include <string>
#include "../src/core/gesture.h"
#include "../src/core/layout.h"

static int failures = 0, checks = 0;
#define CHECK(cond) do { ++checks; if (!(cond)) { ++failures; std::printf("HATA %s:%d %s\n", __FILE__, __LINE__, #cond); } } while (0)
static bool near(double a, double b, double t = 0.5) { return std::fabs(a - b) <= t; }

int main() {
    const Rect stage{40, 170, 1570, 800};
    const std::vector<SlotSpec> specs = {
        {"finder", SlotSize::Medium}, {"chrome", SlotSize::Large}, {"claude", SlotSize::Medium},
        {"terminal", SlotSize::Small}, {"windows", SlotSize::Small}, {"whatsapp", SlotSize::Small},
        {"github", SlotSize::Small}, {"notes", SlotSize::Small}, {"xcode", SlotSize::Small},
    };
    auto placed = placeSlots(specs, stage);

    CHECK(placed.size() == specs.size());
    for (size_t i = 0; i < placed.size(); ++i) CHECK(placed[i].id == specs[i].id);
    for (const auto& s : placed) {
        CHECK(s.frame.x >= stage.x - 0.5 && s.frame.right() <= stage.right() + 0.5);
        CHECK(s.frame.y >= stage.y - 0.5 && s.frame.bottom() <= stage.bottom() + 0.5);
        CHECK(near(s.frame.h - s.pile.h, StageMetrics{}.labelHeight, 0.01));
    }
    for (size_t i = 0; i < placed.size(); ++i)
        for (size_t j = i + 1; j < placed.size(); ++j) CHECK(!placed[i].frame.intersects(placed[j].frame));

    CHECK(placed[1].frame.w > placed[0].frame.w && placed[0].frame.w > placed[3].frame.w);

    // Aynı girdi aynı yer: pencere sayısı girdi bile değil.
    auto again = placeSlots(specs, stage);
    for (size_t i = 0; i < placed.size(); ++i) CHECK(placed[i].frame == again[i].frame);

    CHECK(placeSlots({}, stage).empty());
    CHECK(placeSlots(specs, Rect{}).empty());
    auto single = placeSlots({{"a", SlotSize::Small}}, stage);
    CHECK(single[0].pile.h < single[0].pile.w);

    CHECK(initialSlotSize(0) == SlotSize::Small && initialSlotSize(1) == SlotSize::Small);
    CHECK(initialSlotSize(3) == SlotSize::Medium && initialSlotSize(4) == SlotSize::Large);

    const Rect rect{100, 50, 460, 300};
    auto one = pileFrames(rect, {1.6});
    CHECK(near(one[0].w / one[0].h, 1.6, 0.01));
    CHECK(near(one[0].midX(), rect.midX()));
    CHECK(near(one[0].bottom(), rect.bottom()));
    for (int n = 1; n <= kMaxVisiblePile; ++n) {
        std::vector<double> aspects;
        for (int i = 0; i < n; ++i) aspects.push_back(0.5 + i * 0.3);
        auto frames = pileFrames(rect, aspects);
        CHECK(static_cast<int>(frames.size()) == n);
        for (int i = 0; i < n; ++i) {
            CHECK(frames[i].x >= rect.x - 0.5 && frames[i].right() <= rect.right() + 0.5);
            CHECK(frames[i].y >= rect.y - 0.5 && frames[i].bottom() <= rect.bottom() + 0.5);
            CHECK(near(frames[i].w / frames[i].h, aspects[i], 0.01));
        }
    }
    CHECK(pileFrames(rect, {0}).size() == 1);
    CHECK(pileFrames(rect, {}).empty());
    auto six = pileFrames(rect, std::vector<double>(6, 1.6));
    CHECK(six[0].w < one[0].w && six[0].w > rect.w / 4);

    const Rect area{0, 34, 1643, 1073};
    auto left = snapFrame(SnapPosition::LeftHalf, area), right = snapFrame(SnapPosition::RightHalf, area);
    CHECK(left.right() == right.x && right.right() == area.right() && left.h == area.h);
    CHECK(snapFrame(SnapPosition::Fill, area) == area);
    CHECK(snapFrame(SnapPosition::Fill, Rect{}) == Rect{});

    // Mağaza uygulaması sürüm değiştirince kimliği değişmez.
    CHECK(stableAppPath(L"c:\\program files\\windowsapps\\claude_4.16336.0.0_x64__pzs8sxrjxfjjc\\app\\claude.exe") ==
          stableAppPath(L"c:\\program files\\windowsapps\\claude_4.23118.0.0_x64__pzs8sxrjxfjjc\\app\\claude.exe"));
    CHECK(stableAppPath(L"c:\\program files\\windowsapps\\claude_4.23118.0.0_x64__pzs8sxrjxfjjc\\app\\claude.exe") ==
          L"c:\\program files\\windowsapps\\claude__pzs8sxrjxfjjc\\app\\claude.exe");
    CHECK(stableAppPath(L"c:\\windows\\notepad.exe") == L"c:\\windows\\notepad.exe");

    // Kaydırılan bölüm yukarıdan başlar, uygulama çoğaldıkça uzar.
    std::vector<SlotSpec> many;
    for (int i = 0; i < 48; ++i) many.push_back({"app" + std::to_string(i), SlotSize::Small});
    auto flowing = placeSlotsFlowing(many, 0, 1600, 1000, 800);
    CHECK(flowing.size() == 48 && near(flowing.front().frame.y, 1000) && near(flowing.front().pile.y, 1000));
    CHECK(flowing.back().frame.bottom() > 1800);
    CHECK(placeSlotsFlowing({}, 0, 1600, 0, 800).empty());

    // Sürükleme aralığı: a b c / d e
    auto dropSlot = [](const char* id, double x, double y) {
        Rect frame{x, y, 100, 100};
        return PlacedSlot{id, SlotSize::Small, frame, frame};
    };
    std::vector<PlacedSlot> grid{dropSlot("a", 0, 0), dropSlot("b", 120, 0), dropSlot("c", 240, 0), dropSlot("d", 0, 120), dropSlot("e", 120, 120)};
    CHECK(slotDropAt(200, 50, 4, grid, 20)->gap == 2);
    CHECK(!slotDropAt(110, 50, 1, grid, 20) && !slotDropAt(200, 50, 1, grid, 20));
    auto rowEnd = slotDropAt(400, 50, 0, grid, 20);
    CHECK(rowEnd->gap == 3 && near(rowEnd->markX, 350));
    CHECK(slotDropAt(10, 300, 0, grid, 20)->gap == 3);
    CHECK(!slotDropAt(0, 0, 9, grid, 20));

    std::vector<int> order{0, 1, 2, 3, 4};
    moveToGap(order, 0, 3);
    CHECK((order == std::vector<int>{1, 2, 0, 3, 4}));
    order = {0, 1, 2, 3, 4};
    moveToGap(order, 4, 2);
    CHECK((order == std::vector<int>{0, 1, 4, 2, 3}));
    order = {0, 1, 2};
    moveToGap(order, 0, 3);
    CHECK((order == std::vector<int>{1, 2, 0}));

    // Uygulama pencereleri ızgarası
    {
        const Rect area{0, 0, 1600, 900};
        CHECK(exposeFrames(area, {}, 20).empty());
        auto one = exposeFrames(area, {16.0 / 9}, 20);
        CHECK(one.size() == 1 && near(one[0].w, 1600) && near(one[0].h, 900));
        auto two = exposeFrames(area, {1.6, 1.6}, 20);
        CHECK(two.size() == 2 && near(two[0].y, two[1].y) && two[0].right() <= two[1].x);
        auto five = exposeFrames(area, {1.6, 1.6, 1.6, 1.6, 1.6}, 20);
        CHECK(five.size() == 5);
        for (const auto& r : five) CHECK(r.x >= -0.5 && r.right() <= 1600.5 && r.y >= -0.5 && r.bottom() <= 900.5);
        for (size_t i = 0; i < five.size(); ++i)
            for (size_t j = i + 1; j < five.size(); ++j) CHECK(!five[i].intersects(five[j]));
        // Eksik son satır ortalanır.
        CHECK(near(five[3].midX() + five[4].midX(), 1600, 1));
        // Dar pencere en-boy oranını korur.
        auto tall = exposeFrames(area, {0.5}, 20);
        CHECK(near(tall[0].h, 900) && near(tall[0].w, 450) && near(tall[0].midX(), 800));
    }

    // Dokunmatik yüzeyde üç parmakla kaydırma
    {
        auto frame = [](double y, int count = 3) {
            std::vector<TouchPoint> points;
            for (int i = 0; i < count; ++i) points.push_back({0.4 + 0.1 * i, y});
            return points;
        };
        SwipeRecognizer up;
        CHECK(up.feed(frame(0.7)) == SwipeAction::None);
        CHECK(up.feed(frame(0.65)) == SwipeAction::None);
        CHECK(up.feed(frame(0.5)) == SwipeAction::Up);
        CHECK(up.feed(frame(0.3)) == SwipeAction::None); // Oturumda bir kez.
        CHECK(up.feed({}) == SwipeAction::None);
        CHECK(up.feed(frame(0.3)) == SwipeAction::None);
        CHECK(up.feed(frame(0.5)) == SwipeAction::Down); // Yeni oturum.

        SwipeRecognizer four;
        CHECK(four.feed(frame(0.7, 4)) == SwipeAction::None);
        CHECK(four.feed(frame(0.7)) == SwipeAction::None);
        CHECK(four.feed(frame(0.4)) == SwipeAction::None); // Dört parmak değdi: bu oturum bizim değil.

        SwipeRecognizer sideways;
        sideways.feed({{0.2, 0.5}, {0.3, 0.5}, {0.4, 0.5}});
        CHECK(sideways.feed({{0.5, 0.6}, {0.6, 0.6}, {0.7, 0.6}}) == SwipeAction::None); // Yatay ağır basıyor.

        SwipeRecognizer two;
        two.feed(frame(0.7, 2));
        CHECK(two.feed(frame(0.3, 2)) == SwipeAction::None);
    }

    std::printf("%d kontrol, %d hata\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
