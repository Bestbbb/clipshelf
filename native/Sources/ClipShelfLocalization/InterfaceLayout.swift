import AppKit

/// Set each owned view explicitly: an extension may be hosted by an app with a
/// different language, and AppKit does not consistently inherit a parent's value.
/// This changes interface geometry only, never the writing direction of user text.
@MainActor
public enum InterfaceLayout {
    public static var direction: NSUserInterfaceLayoutDirection {
        L10n.language.isRightToLeft ? .rightToLeft : .leftToRight
    }

    public static func apply(to root: NSView?, direction: NSUserInterfaceLayoutDirection? = nil) {
        guard let root else { return }
        let resolved = direction ?? self.direction
        root.userInterfaceLayoutDirection = resolved
        for child in root.subviews { apply(to: child, direction: resolved) }
    }
}
