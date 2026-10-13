import CoreFoundation

/// Setting an already-correct AX selection is not necessarily idempotent in a
/// custom editor or WebKit. Preserve the receiver's native caret when its AX
/// focus and range still match the snapshot.
enum PasteFocusRestoration {
    struct Plan: Equatable {
        let restoreFocus: Bool
        let restoreSelection: Bool
    }

    static func plan(focusMatches: Bool, capturedRange: CFRange?, currentRange: CFRange?) -> Plan {
        let rangeMatches: Bool
        if let capturedRange, let currentRange {
            rangeMatches = capturedRange.location == currentRange.location && capturedRange.length == currentRange.length
        } else {
            rangeMatches = capturedRange == nil
        }
        return Plan(restoreFocus: !focusMatches,
                    restoreSelection: capturedRange != nil && (!focusMatches || !rangeMatches))
    }
}
