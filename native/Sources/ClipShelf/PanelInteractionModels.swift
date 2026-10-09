import Foundation
import ClipShelfCore

struct PanelPageAnchor: Sendable, Equatable {
    let recordID: UUID
    /// Zero reveals this record; -1/+1 moves to its immediate neighbour.
    let displacement: Int
}

struct PanelPageRequest: Sendable {
    let id: UUID
    let query: HistoryQuery
    let offset: Int
    let anchor: PanelPageAnchor?
    var boundary: HistoryPageBoundary? = nil
}

struct PanelHistoryPage: Sendable {
    let records: [ClipboardRecordMetadata]
    let offset: Int
    let hasMore: Bool
    let focusID: UUID?
}

/// A bounded window, independent of how far the target is from the beginning.
struct PanelPageWindow: Equatable {
    static let size = 300
    private(set) var offset = 0
    private(set) var count = 0
    private(set) var hasMore = false
    var hasPrevious: Bool { offset > 0 }
    var previousOffset: Int { max(0, offset - Self.size) }
    var nextOffset: Int { offset + count }
    var rangeDescription: String { count == 0 ? "0 条" : "第 \(offset + 1)–\(offset + count) 条" }

    mutating func update(offset: Int, count: Int, hasMore: Bool) {
        self.offset = max(0, offset)
        self.count = min(max(0, count), Self.size)
        self.hasMore = hasMore
    }

    static func centeredOffset(for targetIndex: Int) -> Int { max(0, targetIndex - Self.size / 2) }
}

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
    static func insertion(movingIDs: Set<UUID>, visibleIDs: [UUID], at index: Int, hasMore: Bool, hasPrevious: Bool = false) throws -> Self {
        guard !movingIDs.isEmpty, movingIDs.isSubset(of: Set(visibleIDs)), (0...visibleIDs.count).contains(index) else {
            throw PlanningError.staleSelection
        }
        let moving = visibleIDs.filter { movingIDs.contains($0) }
        if index == 0, hasPrevious { throw PlanningError.unloadedBoundary }
        let before = visibleIDs.dropFirst(index).first { !movingIDs.contains($0) }
        if before == nil, hasMore { throw PlanningError.unloadedBoundary }
        let remaining = visibleIDs.filter { !movingIDs.contains($0) }
        let destination = before.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
        var result = remaining
        result.insert(contentsOf: moving, at: destination)
        if result == visibleIDs { throw PlanningError.noMovement }
        return Self(movingIDs: moving, beforeID: before)
    }

    /// Cross-page selections carry their full frozen order, while the insertion target stays visible.
    static func insertion(references: [ClipboardSelectionReference], visibleIDs: [UUID], at index: Int,
                          hasMore: Bool, hasPrevious: Bool) throws -> Self {
        let movingIDs = references.map(\.id), selected = Set(movingIDs)
        guard !selected.isEmpty, selected.count == references.count,
              (0...visibleIDs.count).contains(index) else { throw PlanningError.staleSelection }
        if index == 0, hasPrevious { throw PlanningError.unloadedBoundary }
        let before = visibleIDs.dropFirst(index).first { !selected.contains($0) }
        if before == nil, hasMore { throw PlanningError.unloadedBoundary }
        if selected.isSubset(of: Set(visibleIDs)) {
            return try insertion(movingIDs: selected, visibleIDs: visibleIDs, at: index,
                                 hasMore: hasMore, hasPrevious: hasPrevious)
        }
        return Self(movingIDs: movingIDs, beforeID: before)
    }

    static func step(movingIDs: Set<UUID>, visibleIDs: [UUID], forward: Bool, hasMore: Bool, hasPrevious: Bool = false) throws -> Self {
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
                throw hasPrevious ? PlanningError.unloadedBoundary : PlanningError.noMovement
            }
            target = previous
        }
        return try insertion(movingIDs: movingIDs, visibleIDs: visibleIDs, at: target, hasMore: hasMore, hasPrevious: hasPrevious)
    }
}
