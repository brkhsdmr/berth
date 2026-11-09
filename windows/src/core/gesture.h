// Dokunmatik yüzeyde çok parmakla dikey kaydırmanın tanınması; Mac'teki MultiFingerSwipe'ın
// karşılığı. Konumlar 0…1 arasıdır, y aşağı doğru artar (dokunmatik yüzeyin kendi ekseni).
#pragma once
#include <cmath>
#include <vector>

struct TouchPoint {
    double x = 0, y = 0;
};

enum class SwipeAction { None, Up, Down };

class SwipeRecognizer {
public:
    /// Yüzey yüksekliğinin oranı: Mac'teki eşikle aynı.
    static constexpr double kDistance = 0.12;

    explicit SwipeRecognizer(int fingers = 3) : fingers_(fingers) {}
    void setFingers(int fingers) { fingers_ = fingers; }
    int fingers() const { return fingers_; }

    /// Bir dokunma çerçevesi: yüzeye değen parmaklar. Boş çerçeve oturumu bitirir. Bir oturumda
    /// en fazla bir kez tetiklenir; oturumda seçilenden fazla parmak değdiyse hiç tetiklenmez
    /// (4 parmak hareketi 3 parmağınkine karışmasın).
    SwipeAction feed(const std::vector<TouchPoint>& contacts) {
        if (contacts.empty()) {
            hasBase_ = false;
            maxCount_ = 0;
            fired_ = false;
            return SwipeAction::None;
        }
        if (int(contacts.size()) > maxCount_) maxCount_ = int(contacts.size());
        if (fingers_ <= 0 || int(contacts.size()) != fingers_ || maxCount_ != fingers_ || fired_) {
            if (int(contacts.size()) != fingers_) hasBase_ = false;
            return SwipeAction::None;
        }
        double cx = 0, cy = 0;
        for (const auto& p : contacts) {
            cx += p.x;
            cy += p.y;
        }
        cx /= double(contacts.size());
        cy /= double(contacts.size());
        if (!hasBase_) {
            hasBase_ = true;
            baseX_ = cx;
            baseY_ = cy;
            return SwipeAction::None;
        }
        double dx = cx - baseX_, dy = cy - baseY_;
        if (std::fabs(dy) < kDistance || std::fabs(dx) >= std::fabs(dy)) return SwipeAction::None;
        fired_ = true;
        return dy < 0 ? SwipeAction::Up : SwipeAction::Down;
    }

private:
    int fingers_;
    bool hasBase_ = false;
    double baseX_ = 0, baseY_ = 0;
    int maxCount_ = 0;
    bool fired_ = false;
};
