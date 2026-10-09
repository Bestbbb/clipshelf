import AppKit

/// Convert physical input and insertion geometry without changing history order,
/// selection identity, the clipboard payload, or user-defined logical shortcuts.
enum PanelLayoutDirection {
    static func step(towardRight: Bool, direction: NSUserInterfaceLayoutDirection) -> Int {
        towardRight == (direction == .leftToRight) ? 1 : -1
    }

    static func insertionIndex(at x: CGFloat, frames: [NSRect], direction: NSUserInterfaceLayoutDirection) -> Int {
        frames.firstIndex { direction == .rightToLeft ? x > $0.midX : x < $0.midX } ?? frames.count
    }

    static func insertionLineX(frame: NSRect, before: Bool, direction: NSUserInterfaceLayoutDirection) -> CGFloat {
        before == (direction == .leftToRight) ? frame.minX - 6 : frame.maxX + 4
    }

    static func insertionLineFrame(frame: NSRect, before: Bool, direction: NSUserInterfaceLayoutDirection, contentWidth: CGFloat) -> NSRect {
        let width: CGFloat = min(3, max(0, contentWidth))
        let x = insertionLineX(frame: frame, before: before, direction: direction)
        return NSRect(x: min(max(0, x), max(0, contentWidth - width)), y: frame.minY, width: width, height: frame.height)
    }
}
