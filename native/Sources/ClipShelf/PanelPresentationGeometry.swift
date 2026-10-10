import Foundation

/// Presentation geometry is independent of NSScreen so screen changes can be
/// checked without ordering a window onto the user's desktop.
enum PanelPresentationGeometry {
    static let minimumHeight: CGFloat = 240
    static let defaultVisibleFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)

    static func usable(_ frame: CGRect) -> CGRect {
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite,
              frame.height.isFinite, frame.width > 0, frame.height > 0 else { return defaultVisibleFrame }
        return frame
    }

    static func preferredHeight(_ value: CGFloat, compact: Bool) -> CGFloat {
        guard value.isFinite, value > 0 else { return compact ? minimumHeight : 330 }
        return max(minimumHeight, value)
    }

    static func shelf(in rawFrame: CGRect, preferredHeight: CGFloat) -> CGRect {
        let visible = usable(rawFrame)
        let horizontalMargin = min(20, visible.width / 8)
        let verticalMargin = min(18, visible.height / 8)
        let width = min(1180, visible.width - 2 * horizontalMargin)
        let height = min(preferredHeight, visible.height - 2 * verticalMargin)
        return CGRect(x: visible.midX - width / 2, y: visible.minY + verticalMargin,
                      width: width, height: height)
    }

    static func detail(size: CGSize, in rawFrame: CGRect) -> CGRect {
        let visible = usable(rawFrame)
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                      width: width, height: height)
    }
}
