import Foundation

/// A tab gesture replaces a complete personal board order, never a visible subset.
struct PinboardTabReorderPlan: Equatable {
    let ids: [UUID]
    let expectedOrder: [UUID]

    static func moving(_ id: UUID, in order: [UUID], toInsertionIndex index: Int) -> Self? {
        guard Set(order).count == order.count, let origin = order.firstIndex(of: id),
              (0...order.count).contains(index) else { return nil }
        var result = order
        result.remove(at: origin)
        result.insert(id, at: index > origin ? index - 1 : index)
        guard result != order else { return nil }
        return Self(ids: result, expectedOrder: order)
    }
}
