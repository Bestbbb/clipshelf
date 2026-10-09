import Foundation

/// An explicit board filter survives text edits; navigation remains a global-search shortcut.
struct PanelBoardScope: Equatable {
    private(set) var navigationID: UUID?
    private(set) var filteredIDs: Set<UUID> = []
    var queryIDs: Set<UUID> { filteredIDs.isEmpty ? Set(navigationID.map { [$0] } ?? []) : filteredIDs }
    var singleBoardID: UUID? { queryIDs.count == 1 ? queryIDs.first : nil }
    mutating func navigate(to id: UUID?) { navigationID = id; filteredIDs = [] }
    mutating func filter(_ ids: Set<UUID>) { navigationID = nil; filteredIDs = ids }
    mutating func beginTextSearch() { navigationID = nil }
    mutating func retain(_ ids: Set<UUID>) {
        if let navigationID, !ids.contains(navigationID) { self.navigationID = nil }
        filteredIDs.formIntersection(ids)
    }
}

struct PanelReorderPlan: Equatable {
    let movingIDs: [UUID]
    let beforeID: UUID?

    enum PlanningError: Error, Equatable { case staleSelection, unloadedBoundary, noMovement }

    /// Only an insertion anchor is sent to storage. Unloaded records never become a replacement list.
    static func insertion(movingIDs: Set<UUID>, visibleIDs: [UUID], at index: Int, hasMore: Bool) throws -> Self {
        guard !movingIDs.isEmpty, movingIDs.isSubset(of: Set(visibleIDs)), (0...visibleIDs.count).contains(index) else {
            throw PlanningError.staleSelection
        }
        let moving = visibleIDs.filter { movingIDs.contains($0) }
        let before = visibleIDs.dropFirst(index).first { !movingIDs.contains($0) }
        if before == nil, hasMore { throw PlanningError.unloadedBoundary }
        let remaining = visibleIDs.filter { !movingIDs.contains($0) }
        let destination = before.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
        var result = remaining
        result.insert(contentsOf: moving, at: destination)
        if result == visibleIDs { throw PlanningError.noMovement }
        return Self(movingIDs: moving, beforeID: before)
    }

    static func step(movingIDs: Set<UUID>, visibleIDs: [UUID], forward: Bool, hasMore: Bool) throws -> Self {
        let selected = visibleIDs.indices.filter { movingIDs.contains(visibleIDs[$0]) }
        guard let first = selected.first, let last = selected.last else { throw PlanningError.staleSelection }
        let target: Int
        if forward {
            guard let next = visibleIDs.indices.dropFirst(last + 1).first(where: { !movingIDs.contains(visibleIDs[$0]) }) else {
                throw hasMore ? PlanningError.unloadedBoundary : PlanningError.noMovement
            }
            target = next + 1
        } else {
            guard let previous = visibleIDs.indices.prefix(first).last(where: { !movingIDs.contains(visibleIDs[$0]) }) else {
                throw PlanningError.noMovement
            }
            target = previous
        }
        return try insertion(movingIDs: movingIDs, visibleIDs: visibleIDs, at: target, hasMore: hasMore)
    }
}
