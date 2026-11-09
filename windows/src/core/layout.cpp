#include "layout.h"
#include <algorithm>
#include <cmath>
#include <optional>

namespace {

double unitWidth(int unitsPerRow, const Rect& stage, const StageMetrics& m) {
    return (stage.w - (unitsPerRow - 1) * m.gap) / unitsPerRow;
}

double slotWidth(int units, double unit, double gap) {
    return units * unit + (units - 1) * gap;
}

std::vector<std::vector<SlotSpec>> pack(const std::vector<SlotSpec>& slots, int unitsPerRow) {
    std::vector<std::vector<SlotSpec>> rows;
    std::vector<SlotSpec> current;
    int used = 0;
    for (const auto& slot : slots) {
        int units = slotUnits(slot.size);
        if (used + units > unitsPerRow && !current.empty()) {
            rows.push_back(current);
            current.clear();
            used = 0;
        }
        current.push_back(slot);
        used += units;
    }
    if (!current.empty()) rows.push_back(current);
    return rows;
}

/// Küçük bir hücreye 16:10 pencere sığdığında alacağı genişlik: düzenlerin karşılaştırma ölçütü.
double tileWidth(int unitsPerRow, size_t rowCount, const Rect& stage, const StageMetrics& m) {
    double width = slotWidth(slotUnits(SlotSize::Small), unitWidth(unitsPerRow, stage, m), m.gap);
    double rows = static_cast<double>(rowCount);
    double rowHeight = (stage.h - (rows - 1) * m.rowGap) / rows;
    return std::min(width, (rowHeight - m.labelHeight) * 1.6);
}

struct Size { double w, h; };

Size fit(double aspect, Size cell) {
    double width = std::min(cell.w, cell.h * aspect);
    return {width, width / aspect};
}

Size cellSize(const Rect& r, int columns, int rows, double overlap) {
    double c = columns, n = rows;
    return {r.w / (c - (c - 1) * overlap), r.h / (n - (n - 1) * overlap)};
}

} // namespace

std::vector<PlacedSlot> placeSlots(const std::vector<SlotSpec>& slots, const Rect& stage, const StageMetrics& m) {
    if (slots.empty() || stage.w <= 0 || stage.h <= 0) return {};

    int total = 0, widest = 2;
    for (const auto& s : slots) {
        total += slotUnits(s.size);
        widest = std::max(widest, slotUnits(s.size));
    }

    struct Best {
        double score;
        std::vector<std::vector<SlotSpec>> rows;
        int unitsPerRow;
    };
    std::optional<Best> best;
    int maxTarget = std::min<int>(static_cast<int>(slots.size()), m.maxRows);
    for (int target = 1; target <= maxTarget; ++target) {
        int unitsPerRow = std::max(widest, static_cast<int>(std::ceil(static_cast<double>(total) / target)));
        auto rows = pack(slots, unitsPerRow);
        while (static_cast<int>(rows.size()) > target) {
            ++unitsPerRow;
            rows = pack(slots, unitsPerRow);
        }
        double score = tileWidth(unitsPerRow, rows.size(), stage, m);
        if (!best || score > best->score + 0.5) best = Best{score, rows, unitsPerRow};
    }

    double unit = unitWidth(best->unitsPerRow, stage, m);
    double widestSlot = slotWidth(widest, unit, m.gap);
    double rowCount = static_cast<double>(best->rows.size());
    double available = (stage.h - (rowCount - 1) * m.rowGap) / rowCount;
    // Çok az uygulama varken hücreler ekranı dikine doldurmasın.
    double rowHeight = std::min(available, widestSlot * 0.72 + m.labelHeight);
    double blockHeight = rowCount * rowHeight + (rowCount - 1) * m.rowGap;
    double y = stage.y + (stage.h - blockHeight) / 2;

    std::vector<PlacedSlot> placed;
    for (const auto& row : best->rows) {
        double rowWidth = (static_cast<double>(row.size()) - 1) * m.gap;
        for (const auto& slot : row) rowWidth += slotWidth(slotUnits(slot.size), unit, m.gap);
        double x = stage.x + (stage.w - rowWidth) / 2;
        for (const auto& slot : row) {
            double width = slotWidth(slotUnits(slot.size), unit, m.gap);
            placed.push_back({slot.id, slot.size, {x, y, width, rowHeight}, {x, y, width, rowHeight - m.labelHeight}});
            x += width + m.gap;
        }
        y += rowHeight + m.rowGap;
    }
    return placed;
}

std::vector<PlacedSlot> placeSlotsFlowing(const std::vector<SlotSpec>& slots, double x, double width, double top,
                                          double viewportHeight, const StageMetrics& metrics) {
    constexpr int slotsPerPage = 12;
    int pages = std::max(1, (static_cast<int>(slots.size()) + slotsPerPage - 1) / slotsPerPage);
    StageMetrics flowing = metrics;
    flowing.maxRows = metrics.maxRows * pages;
    auto placed = placeSlots(slots, {x, top, width, viewportHeight * pages}, flowing);
    if (placed.empty()) return placed;
    double shift = top - placed.front().frame.y;
    for (auto& slot : placed) {
        slot.frame.y += shift;
        slot.pile.y += shift;
    }
    return placed;
}

std::optional<SlotDrop> slotDropAt(double x, double y, size_t moving, const std::vector<PlacedSlot>& slots, double gap) {
    if (moving >= slots.size()) return std::nullopt;
    size_t bestStart = 0, bestEnd = 0;
    double bestDistance = 1e18;
    for (size_t start = 0; start < slots.size();) {
        size_t end = start + 1;
        while (end < slots.size() && slots[end].frame.y == slots[start].frame.y) ++end;
        const Rect& frame = slots[start].frame;
        double distance = std::max({frame.y - y, y - frame.bottom(), 0.0});
        if (distance < bestDistance) {
            bestDistance = distance;
            bestStart = start;
            bestEnd = end;
        }
        start = end;
    }
    size_t target = bestEnd;
    for (size_t i = bestStart; i < bestEnd; ++i) {
        if (x < slots[i].frame.midX()) {
            target = i;
            break;
        }
    }
    if (target == moving || target == moving + 1) return std::nullopt;
    double markX = target < bestEnd ? slots[target].frame.x - gap / 2 : slots[bestEnd - 1].frame.right() + gap / 2;
    const Rect& row = slots[bestStart].frame;
    return SlotDrop{target, markX, row.y, row.bottom()};
}

std::vector<Rect> pileFrames(const Rect& rect, const std::vector<double>& input, double overlap) {
    int count = static_cast<int>(input.size());
    if (count == 0 || rect.w <= 0 || rect.h <= 0) return {};
    std::vector<double> aspects;
    for (double a : input) aspects.push_back(a > 0.01 ? a : 1.6);

    int bestColumns = 1;
    double bestScore = -1;
    for (int columns = 1; columns <= count; ++columns) {
        int rows = (count + columns - 1) / columns;
        Size cell = cellSize(rect, columns, rows, overlap);
        double score = 1e18;
        for (double a : aspects) {
            Size f = fit(a, cell);
            score = std::min(score, f.w * f.h);
        }
        if (score > bestScore * 1.001) {
            bestScore = score;
            bestColumns = columns;
        }
    }

    int columns = bestColumns;
    int rows = (count + columns - 1) / columns;
    Size cell = cellSize(rect, columns, rows, overlap);
    double stepX = cell.w * (1 - overlap);
    double stepY = cell.h * (1 - overlap);
    double tallest = 0;
    for (double a : aspects) tallest = std::max(tallest, fit(a, cell).h);
    double gridTop = rect.bottom() - (stepY * (rows - 1) + tallest);

    std::vector<Rect> result;
    for (int i = 0; i < count; ++i) {
        int row = i / columns, column = i % columns;
        int inRow = row == rows - 1 ? count - row * columns : columns;
        double rowWidth = stepX * (inRow - 1) + cell.w;
        double originX = rect.x + (rect.w - rowWidth) / 2 + column * stepX;
        double originY = gridTop + row * stepY;
        Size size = fit(aspects[i], cell);
        Rect frame{originX + (cell.w - size.w) / 2, originY + tallest - size.h, size.w, size.h};
        // Çoklu dizilimde hafif kademe yığın hissi verir.
        if (count > 1 && inRow > 1) frame.y += (column % 2 == 0 ? -1 : 1) * cell.h * 0.03;
        frame.x = std::min(std::max(frame.x, rect.x), rect.right() - frame.w);
        frame.y = std::min(std::max(frame.y, rect.y), rect.bottom() - frame.h);
        result.push_back(frame);
    }
    return result;
}

Rect snapFrame(SnapPosition position, const Rect& a) {
    if (a.w <= 0 || a.h <= 0) return {};
    double split = std::round(a.w / 2);
    switch (position) {
    case SnapPosition::LeftHalf: return {a.x, a.y, split, a.h};
    case SnapPosition::RightHalf: return {a.x + split, a.y, a.w - split, a.h};
    default: return a;
    }
}

std::vector<Rect> exposeFrames(const Rect& area, const std::vector<double>& aspects, double gap) {
    std::vector<Rect> frames;
    const size_t n = aspects.size();
    if (n == 0 || area.w <= 0 || area.h <= 0) return frames;
    auto fit = [](double aspect, double w, double h) {
        aspect = aspect > 0 ? aspect : 1.6;
        return w / h > aspect ? std::pair<double, double>{h * aspect, h} : std::pair<double, double>{w, w / aspect};
    };
    // Kapladığı toplam alanı en büyük olan sütun sayısı; eşitlikte az sütun (büyük hücre).
    size_t bestColumns = 1;
    double bestArea = -1;
    for (size_t columns = 1; columns <= n; ++columns) {
        size_t rows = (n + columns - 1) / columns;
        double cw = (area.w - double(columns - 1) * gap) / double(columns);
        double ch = (area.h - double(rows - 1) * gap) / double(rows);
        if (cw <= 0 || ch <= 0) break;
        double total = 0;
        for (double aspect : aspects) {
            auto [w, h] = fit(aspect, cw, ch);
            total += w * h;
        }
        if (total > bestArea + 0.5) {
            bestArea = total;
            bestColumns = columns;
        }
    }
    const size_t columns = bestColumns, rows = (n + columns - 1) / columns;
    const double cw = (area.w - double(columns - 1) * gap) / double(columns);
    const double ch = (area.h - double(rows - 1) * gap) / double(rows);
    for (size_t i = 0; i < n; ++i) {
        size_t row = i / columns, column = i % columns;
        size_t inRow = row + 1 < rows ? columns : n - row * columns;
        double rowWidth = double(inRow) * cw + double(inRow - 1) * gap;
        double x = area.x + (area.w - rowWidth) / 2 + double(column) * (cw + gap);
        double y = area.y + double(row) * (ch + gap);
        auto [w, h] = fit(aspects[i], cw, ch);
        frames.push_back({x + (cw - w) / 2, y + (ch - h) / 2, w, h});
    }
    return frames;
}
