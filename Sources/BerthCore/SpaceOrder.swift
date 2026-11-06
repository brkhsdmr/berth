import CoreGraphics

/// Bir alanı şeritteki iki alanın arasına yerleştirme kuralları.
///
/// Hedef sıra numarasıyla değil **sonraki alanın kimliğiyle** tutulur: pencere tam ekrana
/// geçerken listeye yeni bir alan girer ve sıra numaraları kayar, kimlikler kaymaz.
public enum SpaceOrder {

    /// İmlecin düştüğü aralık: solunda kaç küçük resmin ortası kalıyorsa o.
    public static func gapIndex(forX x: CGFloat, midXs: [CGFloat]) -> Int {
        midXs.filter { $0 < x }.count
    }

    /// `moving` zaten istenen yerde mi? `before` nil ise en sağda olmalı.
    public static func isPlaced(order: [UInt64], moving: UInt64, before: UInt64?) -> Bool {
        guard let index = order.firstIndex(of: moving) else { return false }
        let next = index + 1 < order.count ? order[index + 1] : nil
        return next == before
    }

    /// Mevcut sıradaki hedef aralık. Taşımaya gerek yoksa ya da hedef yoksa nil.
    public static func destinationGap(order: [UInt64], moving: UInt64, before: UInt64?) -> Int? {
        guard order.contains(moving), !isPlaced(order: order, moving: moving, before: before) else { return nil }
        guard let before else { return order.count }
        return order.firstIndex(of: before)
    }

    public struct Move: Equatable, Sendable {
        public var space: UInt64
        public var before: UInt64?
        public init(space: UInt64, before: UInt64?) {
            self.space = space
            self.before = before
        }
    }

    /// İstenen sıra için gereken sürüklemeler.
    ///
    /// En sola doğrudan bırakılmaz: Mission Control şeridinde ilk küçük resmin solu bırakma alanı
    /// değil, oraya bırakılan alan listeden düşüyor (ölçüldü). Bu yüzden alan önce ilk iki alanın
    /// arasına konur, sonra ilk alan onun sağına alınır. Diğer alanların sırası değişmez.
    public static func plan(order: [UInt64], moving: UInt64, before: UInt64?) -> [Move] {
        guard order.contains(moving), !isPlaced(order: order, moving: moving, before: before) else { return [] }
        guard let first = order.first, before == first, order.count >= 2 else {
            return [Move(space: moving, before: before)]
        }
        var moves: [Move] = []
        if order[1] != moving { moves.append(Move(space: moving, before: order[1])) }
        var next = order.filter { $0 != moving }
        next.insert(moving, at: 1)
        moves.append(Move(space: first, before: next.count > 2 ? next[2] : nil))
        return moves
    }

    /// Bir plan uygulandığında oluşacak sıra.
    public static func applying(_ moves: [Move], to order: [UInt64]) -> [UInt64] {
        var result = order
        for move in moves {
            result.removeAll { $0 == move.space }
            let index = move.before.flatMap { result.firstIndex(of: $0) } ?? result.count
            result.insert(move.space, at: index)
        }
        return result
    }

    /// Aralığın ekrandaki x konumu. Uçlarda küçük resmin dışına, ama ona yakın düşer.
    public static func dropX(gap: Int, frames: [CGRect], margin: CGFloat = 14) -> CGFloat? {
        guard !frames.isEmpty, gap >= 0, gap <= frames.count else { return nil }
        if gap == 0 { return frames[0].minX - margin }
        if gap == frames.count { return frames[gap - 1].maxX + margin }
        return (frames[gap - 1].maxX + frames[gap].minX) / 2
    }
}
