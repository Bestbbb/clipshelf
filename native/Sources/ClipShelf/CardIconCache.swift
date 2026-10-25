import AppKit
import UniformTypeIdentifiers

/// Launch Services and icon decoding must never run in a card's main-thread initializer.
/// An immutable raster is transferred only after the serial loader has finished with it.
@MainActor final class CardIconCache {
    enum Key: Hashable, Sendable {
        case application(String)
        case fileType(String)

        var cacheKey: NSString {
            switch self {
            case .application(let id): return "app:\(id)" as NSString
            case .fileType(let id): return "type:\(id)" as NSString
            }
        }
    }

    final class Icon: NSObject, @unchecked Sendable {
        let image: NSImage?
        let tint: NSColor?
        let cost: Int

        init(image: NSImage? = nil, tint: NSColor? = nil, cost: Int = 1) {
            self.image = image; self.tint = tint; self.cost = cost
        }
    }

    static let shared = CardIconCache()
    typealias Loader = @Sendable (Key) -> Icon
    private let cache = NSCache<NSString, Icon>()
    private let queue = DispatchQueue(label: "ClipShelf.card-icons", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    private let loader: Loader
    private var pending: [Key: [(Icon) -> Void]] = [:]

    init(loader: @escaping Loader = { key in CardIconCache.load(key) }) {
        self.loader = loader
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1_024 * 1_024
    }

    func request(_ key: Key, completion: ((Icon) -> Void)? = nil) {
        if let icon = cache.object(forKey: key.cacheKey) { completion?(icon); return }
        if pending[key] != nil {
            if let completion { pending[key]?.append(completion) }
            return
        }
        pending[key] = completion.map { [$0] } ?? []
        let load = loader
        queue.async { [weak self] in
            let icon = autoreleasepool { load(key) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Cache misses too: uninstalled source apps must not be looked up on every scroll.
                self.cache.setObject(icon, forKey: key.cacheKey, cost: icon.cost)
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(icon) }
            }
        }
    }

    private nonisolated static func load(_ key: Key) -> Icon {
        let original: NSImage
        let side: Int
        let hasTint: Bool
        switch key {
        case .application(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return Icon() }
            original = NSWorkspace.shared.icon(forFile: url.path)
            side = 68; hasTint = true
        case .fileType(let id):
            original = NSWorkspace.shared.icon(for: UTType(id) ?? .data)
            side = 512; hasTint = false
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return Icon() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        original.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero,
                      operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else { return Icon() }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
        return Icon(image: image, tint: hasTint ? ClipboardCardView.headerTint(for: image) : nil,
                    cost: cgImage.bytesPerRow * cgImage.height)
    }
}
