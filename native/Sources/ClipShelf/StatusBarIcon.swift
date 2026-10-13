import AppKit

/// Menu bar glyph matching the app icon: three cards standing on a shelf.
/// Drawn as a template so macOS tints it for light, dark and highlighted states.
enum StatusBarIcon {
    static func image(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // Same composition as the app icon: shorter cards peek out behind a
            // larger front card, all standing on one shelf.
            NSBezierPath(roundedRect: NSRect(x: 0.8, y: 1.4, width: 16.4, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            let left = NSRect(x: 1.2, y: 4.4, width: 6, height: 8.2)
            let right = NSRect(x: 10.8, y: 4.4, width: 6, height: 8.2)
            let front = NSRect(x: 5.2, y: 4.4, width: 7.6, height: 11.2)
            for card in [left, right] { drawCard(card, radius: 1.3) }
            // Clear a 1 pt moat so the front card reads as standing in front.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -1, dy: -1), xRadius: 2.4, yRadius: 2.4).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            drawCard(front, radius: 1.6)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// Outlined card with a solid header band.
    private static func drawCard(_ card: NSRect, radius: CGFloat) {
        let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.6, dy: 0.6), xRadius: radius - 0.3, yRadius: radius - 0.3)
        outline.lineWidth = 1.2
        outline.stroke()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).addClip()
        NSRect(x: card.minX, y: card.maxY - card.height * 0.28, width: card.width, height: card.height * 0.28).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
