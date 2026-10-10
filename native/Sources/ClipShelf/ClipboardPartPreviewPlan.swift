import AppKit
import ClipShelfCore
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A read-only view of exactly one original pasteboard object. This is deliberately
/// independent of ClipboardEditPlan: attachments and unknown types remain inspectable
/// even when replacing their contents would be unsafe.
///
/// Decode on one worker, then transfer the result to the UI. The AppKit/PDF objects
/// in `content` must never be mutated or accessed concurrently across those threads.
struct ClipboardPartPreviewPlan: @unchecked Sendable {
    struct RepresentationSummary: Equatable, Sendable {
        let typeIdentifier: String
        let byteCount: Int
    }

    enum Content {
        case richText(NSAttributedString)
        case text(String)
        /// Literal source only; consumers must not pass it to a HTML importer or web view.
        case htmlSource(String)
        case image(NSImage)
        case pdf(PDFDocument)
        /// Stored URL metadata only. Creating this preview does not stat/open/repair it.
        case file(URL)
        case unavailable
    }

    let partIndex: Int
    let representations: [RepresentationSummary]
    let content: Content
    let isTruncated: Bool

    static let maximumTextBytes = 1_048_576
    static let maximumRichTextBytes = 8 * 1_048_576
    static let maximumBinaryBytes = 32 * 1_048_576
    static let maximumImagePixelDimension = 2_048
    static let maximumSourceImagePixels: Int64 = 100_000_000
    static let maximumPDFPageCount = 500

    /// A cheap admission check before the UI asks the existing edit planner for its
    /// definitive structural validation. It never parses documents or other objects.
    static func isPotentiallyEditable(original: ClipboardRecord, partIndex: Int) -> Bool {
        guard original.parts.indices.contains(partIndex) else { return false }
        let representations = original.parts[partIndex].representations
        guard !representations.isEmpty, representations.count <= 100 else { return false }
        var hasText = false
        for value in representations {
            guard value.data.count <= maximumTextBytes else { return false }
            let type = UTType(value.typeIdentifier)
            if value.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue
                || value.typeIdentifier == NSPasteboard.PasteboardType.html.rawValue
                || type?.conforms(to: .plainText) == true || type == .url
                || browserURLListTypes.contains(value.typeIdentifier) {
                hasText = true
            } else if !browserMetadataTypes.contains(value.typeIdentifier)
                        && !webArchiveTypes.contains(value.typeIdentifier) {
                return false
            }
        }
        return hasText
    }

    static func make(original: ClipboardRecord, partIndex: Int) throws -> Self {
        try Task.checkCancellation()
        guard original.parts.indices.contains(partIndex) else { throw ClipboardEditPlanError.invalidPartIndex }
        let values = original.parts[partIndex].representations
        let summaries = values.map { RepresentationSummary(typeIdentifier: $0.typeIdentifier, byteCount: $0.data.count) }
        func plan(_ content: Content, truncated: Bool = false) -> Self {
            Self(partIndex: partIndex, representations: summaries, content: content, isTruncated: truncated)
        }

        // File objects often carry icons and names as alternate representations.
        // Their stored location is the primary content; never touch its filesystem.
        for value in values where ClipboardFileAccess.isFileURLType(value.typeIdentifier) {
            try Task.checkCancellation()
            if value.data.count <= maximumTextBytes, let url = ClipboardFileAccess.url(from: value.data) {
                return plan(.file(url))
            }
        }

        for value in values where isRTFD(value.typeIdentifier) {
            try Task.checkCancellation()
            guard value.data.count <= maximumRichTextBytes,
                  let rich = NSAttributedString(rtfd: value.data, documentAttributes: nil) else { continue }
            try Task.checkCancellation()
            return richTextPlan(rich, makePlan: plan)
        }
        for value in values where value.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue {
            try Task.checkCancellation()
            guard value.data.count <= maximumRichTextBytes, value.data.starts(with: #"{\rtf"#.utf8),
                  let rich = NSAttributedString(rtf: value.data, documentAttributes: nil) else { continue }
            try Task.checkCancellation()
            return richTextPlan(rich, makePlan: plan)
        }

        for value in values where UTType(value.typeIdentifier)?.conforms(to: .pdf) == true {
            try Task.checkCancellation()
            guard value.data.count <= maximumBinaryBytes, let document = PDFDocument(data: value.data),
                  !document.isLocked, document.pageCount > 0, document.pageCount <= maximumPDFPageCount else { continue }
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                for annotation in document.page(at: index)?.annotations ?? [] {
                    annotation.isReadOnly = true
                    if !(annotation.action is PDFActionGoTo) { annotation.action = nil }
                }
            }
            try Task.checkCancellation()
            return plan(.pdf(document))
        }
        for value in values where UTType(value.typeIdentifier)?.conforms(to: .image) == true && !isRTFD(value.typeIdentifier) {
            try Task.checkCancellation()
            if let thumbnail = thumbnail(value.data) {
                try Task.checkCancellation()
                return plan(.image(thumbnail.image), truncated: thumbnail.isPartial)
            }
        }

        // Prefer a represented address to the plain-text title of a copied link.
        for value in values where value.typeIdentifier == NSPasteboard.PasteboardType.URL.rawValue {
            try Task.checkCancellation()
            if let decoded = text(value.data, encoding: .utf8) { return plan(.text(decoded.value), truncated: decoded.truncated) }
        }
        for value in values where browserURLListTypes.contains(value.typeIdentifier) {
            try Task.checkCancellation()
            guard value.data.count <= maximumTextBytes,
                  let list = try? PropertyListSerialization.propertyList(from: value.data, format: nil) as? [[String]],
                  list.count == 2, list[0].count == list[1].count, !list[0].isEmpty else { continue }
            // Binary plists can reference one long string many times. Bound the
            // expanded display as well as the serialized input before joining it.
            var joined = Data()
            for address in list[0] {
                try Task.checkCancellation()
                if !joined.isEmpty { joined.append(10) }
                joined.append(contentsOf: address.utf8.prefix(maximumTextBytes + 1 - joined.count))
                if joined.count > maximumTextBytes { break }
            }
            if let decoded = text(joined, encoding: .utf8) { return plan(.text(decoded.value), truncated: decoded.truncated) }
        }
        for value in values where UTType(value.typeIdentifier)?.conforms(to: .plainText) == true {
            try Task.checkCancellation()
            let encoding: String.Encoding
            if value.typeIdentifier == "public.utf16-plain-text" || value.typeIdentifier == "public.utf16-external-plain-text" {
                let prefix = Array(value.data.prefix(2))
                encoding = prefix == [0xff, 0xfe] || prefix == [0xfe, 0xff] ? .utf16
                    : value.typeIdentifier == "public.utf16-plain-text" ? .utf16LittleEndian : .utf16BigEndian
            } else { encoding = .utf8 }
            if let decoded = text(value.data, encoding: encoding) { return plan(.text(decoded.value), truncated: decoded.truncated) }
        }
        for value in values where value.typeIdentifier == NSPasteboard.PasteboardType.html.rawValue {
            try Task.checkCancellation()
            let prefix = Array(value.data.prefix(2))
            let encoding: String.Encoding = prefix == [0xff, 0xfe] || prefix == [0xfe, 0xff] ? .utf16 : .utf8
            if let decoded = text(value.data, encoding: encoding) { return plan(.htmlSource(decoded.value), truncated: decoded.truncated) }
        }
        try Task.checkCancellation()
        return plan(.unavailable)
    }

    private static func richTextPlan(_ rich: NSAttributedString,
                                     makePlan: (Content, Bool) -> Self) -> Self {
        // NSTextView also needs a bounded layout size after native decoding. Keep
        // character boundaries and attributes, including embedded attachments.
        let length = min(rich.length, maximumTextBytes)
        if length == rich.length { return makePlan(.richText(rich), false) }
        let range = (rich.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: length))
        return makePlan(.richText(rich.attributedSubstring(from: range)), true)
    }

    private static func text(_ data: Data, encoding: String.Encoding) -> (value: String, truncated: Bool)? {
        let truncated = data.count > maximumTextBytes
        let bytes = Data(data.prefix(maximumTextBytes))
        if let value = String(data: bytes, encoding: encoding) { return (value, truncated) }
        guard truncated else { return nil }
        // A bounded prefix can end within one UTF-8 scalar / UTF-16 surrogate pair.
        // Only trim that incomplete tail, never replace malformed interior bytes.
        let tail = encoding == .utf8 ? 3 : 2
        for count in 1...tail {
            if let value = String(data: bytes.dropLast(count), encoding: encoding) { return (value, true) }
        }
        return nil
    }

    private static func thumbnail(_ data: Data) -> (image: NSImage, isPartial: Bool)? {
        guard data.count <= maximumBinaryBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0, width <= maximumSourceImagePixels / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumImagePixelDimension,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return (NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))),
                CGImageSourceGetCount(source) > 1)
    }

    private static func isRTFD(_ identifier: String) -> Bool {
        identifier == NSPasteboard.PasteboardType.rtfd.rawValue || UTType(identifier)?.conforms(to: .rtfd) == true
    }

    private static let browserURLListTypes: Set<String> = [
        "WebURLsWithTitlesPboardType", "dyn.ah62d4rv4gu8zs3pcnzme2641rf4guzdmsv0gn64uqm10c6xenv61a3k",
    ]
    private static let browserMetadataTypes: Set<String> = [
        "public.url-name", "org.chromium.source-url", "org.chromium.content-disposition",
        "NeXT smart paste pasteboard type",
        "dyn.ah62d4rv4gu8y63n2nuuhg5pbsm4ca6dbsr4gnkduqf31k3pcr7u1e3basv61a3k",
    ]
    private static let webArchiveTypes: Set<String> = ["com.apple.webarchive", "Apple Web Archive pasteboard type"]
}
