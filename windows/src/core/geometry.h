// Platformdan bağımsız geometri. Birim fiziksel piksel değil, çağıran ne verirse odur.
#pragma once

struct Rect {
    double x = 0, y = 0, w = 0, h = 0;
    double right() const { return x + w; }
    double bottom() const { return y + h; }
    double midX() const { return x + w / 2; }
    double midY() const { return y + h / 2; }
    bool contains(double px, double py) const { return px >= x && px < right() && py >= y && py < bottom(); }
    bool intersects(const Rect& o) const { return x < o.right() && o.x < right() && y < o.bottom() && o.y < bottom(); }
    bool operator==(const Rect& o) const { return x == o.x && y == o.y && w == o.w && h == o.h; }
};
