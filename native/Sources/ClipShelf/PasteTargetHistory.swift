/// Remembers the application displaced by ClipShelf's own activation. A new
/// external application always replaces this context; it is never a fallback
/// for a different foreground app or after a session/Space change.
struct PasteTargetHistory<Snapshot> {
    let ownPID: Int32
    private(set) var externalPID: Int32?
    private var snapshot: Snapshot?

    init(ownPID: Int32) { self.ownPID = ownPID }

    mutating func activated(_ pid: Int32) {
        guard pid != ownPID else { return }
        externalPID = pid
        snapshot = nil
    }

    mutating func deactivated(_ pid: Int32, capture: (Int32) -> Snapshot?) {
        guard pid != ownPID, pid == externalPID else { return }
        snapshot = capture(pid)
    }

    mutating func resolve(foregroundPID: Int32?, capture: (Int32) -> Snapshot?) -> Snapshot? {
        guard let foregroundPID else { return nil }
        if foregroundPID != ownPID {
            activated(foregroundPID)
            return capture(foregroundPID)
        }
        guard let externalPID else { return nil }
        return snapshot ?? capture(externalPID)
    }

    mutating func clear() { externalPID = nil; snapshot = nil }
}
