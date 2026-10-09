import Foundation
import ClipShelfCore

/// Owned value data from one pasteboard interaction. No pasteboard items or
/// providers escape to the background decoder or persistence queue.
struct ClipboardCaptureSnapshot: Sendable {
    let parts: [ClipboardPart]
    var sourceApp: String?
    var sourceBundleID: String?
    let copiedAt: Date
    let byteCount: Int

    init(parts: [ClipboardPart], sourceApp: String? = nil, sourceBundleID: String? = nil,
         copiedAt: Date = Date(), byteCount: Int) {
        self.parts = parts
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.copiedAt = copiedAt
        self.byteCount = byteCount
    }
}
