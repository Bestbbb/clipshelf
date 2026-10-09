import Foundation
import ClipShelfCore

/// Membership and order are independent of the currently painted metadata window.
struct PanelSelectionState {
    enum SelectionError: LocalizedError {
        case missingUniverse, staleSelection, outsideUniverse, malformedSnapshot
        var errorDescription: String? {
            switch self {
            case .missingUniverse: return "无法取得完整选择范围。"
            case .staleSelection: return "其中一条内容已经改变。"
            case .outsideUniverse: return "目标不再属于当前搜索范围。"
            case .malformedSnapshot: return "无法验证完整选择。"
            }
        }
    }
    private(set) var universe: [ClipboardSelectionReference]?
    private var universeIndex: [UUID: Int] = [:]
    private(set) var references: [ClipboardSelectionReference] = []
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var focusID: UUID?
    private(set) var anchorID: UUID?
    private(set) var generation = UUID()
    private(set) var isInvalid = false

    mutating func clear() { self = Self() }
    /// A new asynchronous selection intent immediately retires callbacks for the previous one.
    mutating func beginChange() { generation = UUID() }

    mutating func selectSingle(_ ref: ClipboardSelectionReference) {
        clear()
        guard ref.revision > 0 else { invalidate(); return }
        references = [ref]; selectedIDs = [ref.id]; focusID = ref.id; anchorID = ref.id
    }

    mutating func installUniverse(_ refs: [ClipboardSelectionReference]) throws {
        let index = try Self.index(refs)
        guard !isInvalid, references.allSatisfy({ ref in index[ref.id].map { refs[$0] == ref } == true }) else {
            throw SelectionError.staleSelection
        }
        universe = refs; universeIndex = index
        references = refs.filter { selectedIDs.contains($0.id) }
        generation = UUID()
    }

    mutating func selectAll(_ refs: [ClipboardSelectionReference]) throws {
        let index = try Self.index(refs)
        universe = refs; universeIndex = index; references = refs; selectedIDs = Set(index.keys)
        if focusID.flatMap({ index[$0] }) == nil { focusID = refs.first?.id }
        anchorID = focusID
        isInvalid = false; generation = UUID()
    }

    mutating func select(ref: ClipboardSelectionReference, toggle: Bool, extend: Bool) throws {
        guard !isInvalid else { throw SelectionError.staleSelection }
        if !toggle && !extend { selectSingle(ref); return }
        guard let universe else { throw SelectionError.missingUniverse }
        guard let target = universeIndex[ref.id] else { throw SelectionError.outsideUniverse }
        guard universe[target] == ref else { throw SelectionError.staleSelection }
        if extend {
            guard let anchor = anchorID ?? focusID, let start = universeIndex[anchor] else { throw SelectionError.outsideUniverse }
            references = Array(universe[min(start, target)...max(start, target)])
            selectedIDs = Set(references.map(\.id)); anchorID = anchor; focusID = ref.id
        } else {
            if selectedIDs.contains(ref.id) { selectedIDs.remove(ref.id) } else { selectedIDs.insert(ref.id) }
            references = universe.filter { selectedIDs.contains($0.id) }
            focusID = selectedIDs.contains(ref.id) ? ref.id : references.first?.id
            anchorID = focusID
        }
        generation = UUID()
    }

    mutating func moveFocus(to id: UUID) {
        guard reference(id) != nil else { return }
        focusID = id; generation = UUID()
    }

    mutating func invalidate() { isInvalid = true; generation = UUID() }

    mutating func adoptCommitted(_ refs: [ClipboardSelectionReference]) throws {
        let index = try Self.index(refs)
        guard Set(index.keys) == selectedIDs, refs.count == references.count,
              references.allSatisfy({ old in index[old.id].map { refs[$0].revision >= old.revision } == true }) else { throw SelectionError.staleSelection }
        // The mutation retains the original frozen output order but invalidates old board positions.
        references = references.compactMap { old in index[old.id].map { refs[$0] } }
        universe = nil; universeIndex = [:]; isInvalid = false; generation = UUID()
    }

    func rangeTarget(delta: Int) -> UUID? {
        guard let universe, let focusID, let index = universeIndex[focusID], !universe.isEmpty else { return nil }
        return universe[max(0, min(universe.count - 1, index + delta))].id
    }

    func reference(_ id: UUID) -> ClipboardSelectionReference? {
        if let index = universeIndex[id], let universe { return universe[index] }
        return references.first { $0.id == id }
    }

    private static func index(_ refs: [ClipboardSelectionReference]) throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(refs.count)
        for (index, ref) in refs.enumerated() {
            guard ref.revision > 0, result.updateValue(index, forKey: ref.id) == nil else { throw SelectionError.malformedSnapshot }
        }
        return result
    }
}
