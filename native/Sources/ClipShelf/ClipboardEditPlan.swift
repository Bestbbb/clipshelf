import ClipShelfLocalization
import AppKit
import ClipShelfCore
import UniformTypeIdentifiers

enum ClipboardEditPlanError: LocalizedError, Equatable {
    case invalidPartIndex
    case unreadableText
    case multipleObjects
    case unsupportedRepresentation(String)
    case attachments
    case invalidRichText
    case invalidLink
    case invalidColor
    case richTextEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPartIndex: return L10n.text("所选对象已变化，请重新打开条目；原内容已保留。")
        case .unreadableText: return L10n.text("此对象没有可完整读取的文本表示；原内容已保留。")
        case .multipleObjects: return L10n.text("此条目包含多个对象，暂不支持原位文本编辑；原内容已保留。")
        case .unsupportedRepresentation(let type): return L10n.text("此条目包含暂不支持编辑的格式（\(type)）；原内容已保留。")
        case .attachments: return L10n.text("此条目包含附件或非文本对象，不能作为纯文本保存；原内容已保留。")
        case .invalidRichText: return L10n.text("原富文本无法完整读取，不能覆盖保存；可继续查看原条目。")
        case .invalidLink: return L10n.text("请输入完整的 http、https、mailto 或 ftp 链接，链接内部不能含空白。")
        case .invalidColor: return L10n.text("请输入六位 RGB 十六进制颜色，例如 #12ABEF；不支持透明度或缩写。")
        case .richTextEncodingFailed: return L10n.text("无法保存富文本格式，草稿已保留，请重试。")
        }
    }
}

/// A text edit replaces alternate encodings of one text object, never arbitrary clipboard objects.
/// Browser source/title/smart-paste metadata is intentionally discarded with the old HTML/URL data.
@MainActor
enum ClipboardEditPlan {
    /// Uses only this object's representations. A record's aggregate summary and kind
    /// cannot identify the address, color or contents of one of its objects.
    static func partRecord(original: ClipboardRecord, partIndex: Int) throws -> ClipboardRecord {
        guard original.parts.indices.contains(partIndex) else { throw ClipboardEditPlanError.invalidPartIndex }
        let part = original.parts[partIndex]
        var projected = original
        projected.parts = [part]
        projected.rtf = part.representations.first { $0.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue }?.data
        projected.html = part.representations.first { $0.typeIdentifier == NSPasteboard.PasteboardType.html.rawValue }?.data
        projected.ocrText = nil
        // Validate before decoding a document, and never import HTML through AppKit.
        if let error = editingError(original: projected) { throw error }
        try ClipboardPartEdit.validateEditablePart(part)
        guard let text = representedText(in: part) else { throw ClipboardEditPlanError.unreadableText }
        projected.text = text
        return projected
    }

    static func editablePartIndices(original: ClipboardRecord) -> [Int] {
        original.parts.indices.filter { (try? partRecord(original: original, partIndex: $0)) != nil }
    }

    /// Rich text preserves its native attributes. URL/title objects load the actual
    /// address, including Safari's URL list, instead of an unrelated display title.
    static func partContents(original: ClipboardRecord, partIndex: Int) throws -> NSAttributedString {
        let projected = try partRecord(original: original, partIndex: partIndex)
        let contents = projected.rtf.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
            ?? NSAttributedString(string: projected.text)
        guard isLinkRecord(projected) else { return contents }
        let addressed = NSMutableAttributedString(attributedString: contents)
        replaceText(in: addressed, with: projected.text)
        let range = NSRange(location: 0, length: addressed.length)
        addressed.removeAttribute(.link, range: range)
        if let url = canonicalLink(projected.text) { addressed.addAttribute(.link, value: url, range: range) }
        return addressed
    }

    static func makePartEdit(
        original: ClipboardRecord,
        partIndex: Int,
        contents: NSAttributedString,
        encodeRTF: @MainActor (NSAttributedString) throws -> Data = encodeNativeRTF
    ) throws -> ClipboardPartEdit {
        let projected = try partRecord(original: original, partIndex: partIndex)
        let edited = try makeRecord(original: projected, contents: contents, encodeRTF: encodeRTF)
        let replacement = edited.parts[0]
        var parts = original.parts
        parts[partIndex] = replacement
        let summaries = parts.enumerated().map { index, part in
            index == partIndex ? edited.text : summaryText(in: part)
        }
        // Like capture, only a single object's formats can describe the whole record.
        // Keep the aggregate projection separate from per-object output; the first
        // object's RTF cannot describe the complete contents of a multi-object record.
        return ClipboardPartEdit(partIndex: partIndex, replacement: replacement,
                                 text: summaries.joined(separator: "\n"),
                                 rtf: parts.count == 1 ? edited.rtf : nil,
                                 html: parts.count == 1 ? edited.html : nil)
    }

    static func makeRecord(
        original: ClipboardRecord,
        contents: NSAttributedString,
        encodeRTF: @MainActor (NSAttributedString) throws -> Data = encodeNativeRTF
    ) throws -> ClipboardRecord {
        let source = original.parts.count == 1 ? try partRecord(original: original, partIndex: 0) : original
        if let error = editingError(original: source) { throw error }
        if let error = validationError(original: source, text: contents.string) { throw error }
        guard !containsAttachment(contents) else { throw ClipboardEditPlanError.attachments }

        let edited = NSMutableAttributedString(attributedString: contents)
        var link: URL?
        if isLinkRecord(source) {
            guard let url = canonicalLink(contents.string) else { throw ClipboardEditPlanError.invalidLink }
            link = url
            replaceText(in: edited, with: url.absoluteString)
            let range = NSRange(location: 0, length: edited.length)
            edited.removeAttribute(.link, range: range)
            edited.addAttribute(.link, value: url, range: range)
        } else if source.kind == .color {
            guard let color = color(from: contents.string), let text = hexString(for: color) else {
                throw ClipboardEditPlanError.invalidColor
            }
            replaceText(in: edited, with: text)
            edited.removeAttribute(.link, range: NSRange(location: 0, length: edited.length))
        }
        let richText: Data
        do { richText = try encodeRTF(edited) }
        catch { throw ClipboardEditPlanError.richTextEncodingFailed }

        var representations = [
            ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: Data(edited.string.utf8)),
            ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue, data: richText),
        ]
        if let link {
            representations.append(ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.URL.rawValue,
                                                            data: Data(link.absoluteString.utf8)))
        }
        var record = original
        record.text = edited.string
        record.rtf = richText
        record.html = nil
        record.parts = [ClipboardPart(representations: representations)]
        record.ocrText = nil
        return record
    }

    /// Structural errors are read-only; invalid draft URL/RGB values remain editable.
    static func editingError(original: ClipboardRecord) -> ClipboardEditPlanError? {
        guard original.parts.count <= 1 else { return .multipleObjects }
        if let rtf = original.rtf, let error = richTextError(rtf) { return error }
        if let html = original.html, htmlContainsObjects(html) { return .attachments }
        for representation in original.parts.flatMap(\.representations) {
            let identifier = representation.typeIdentifier
            if identifier == NSPasteboard.PasteboardType.rtf.rawValue {
                if let error = richTextError(representation.data) { return error }
            } else if identifier == NSPasteboard.PasteboardType.html.rawValue {
                if htmlContainsObjects(representation.data) { return .attachments }
            } else if browserMetadataTypes.contains(identifier) {
                continue
            } else if browserURLListTypes.contains(identifier) {
                // Safari's URL/title arrays may contain multiple bookmarks in a single pasteboard item.
                guard let list = try? PropertyListSerialization.propertyList(from: representation.data, format: nil) as? [[String]],
                      list.count == 2, list[0].count == 1, list[1].count == 1 else { return .multipleObjects }
            } else if webArchiveTypes.contains(identifier) {
                if let error = webArchiveError(representation.data) { return error }
            } else if let type = UTType(identifier), type.conforms(to: .plainText) || type == .url {
                continue
            } else {
                return .unsupportedRepresentation(identifier)
            }
        }
        return nil
    }

    /// Cheap draft validation for each keystroke; the editor caches editingError separately.
    static func validationError(original: ClipboardRecord, text: String) -> Error? {
        if isLinkRecord(original), canonicalLink(text) == nil { return ClipboardEditPlanError.invalidLink }
        if original.kind == .color, color(from: text) == nil { return ClipboardEditPlanError.invalidColor }
        return nil
    }

    static func color(from value: String) -> NSColor? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.utf8.count == 6, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let number = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((number >> 16) & 0xff) / 255,
                       green: CGFloat((number >> 8) & 0xff) / 255,
                       blue: CGFloat(number & 0xff) / 255, alpha: 1)
    }

    static func hexString(for color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent == 1 else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        let bytes = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    static func encodeNativeRTF(_ contents: NSAttributedString) throws -> Data {
        try contents.data(from: NSRange(location: 0, length: contents.length),
                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private static func isLinkRecord(_ record: ClipboardRecord) -> Bool {
        record.kind == .link || record.parts.flatMap(\.representations).contains {
            $0.typeIdentifier == NSPasteboard.PasteboardType.URL.rawValue || browserURLListTypes.contains($0.typeIdentifier)
        }
    }

    private static func representedText(in part: ClipboardPart) -> String? {
        // A URL's optional plain-text representation is often its title, not its address.
        if let value = part.representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.URL.rawValue }) {
            return String(data: value.data, encoding: .utf8)
        }
        if let value = part.representations.first(where: { browserURLListTypes.contains($0.typeIdentifier) }),
           let list = try? PropertyListSerialization.propertyList(from: value.data, format: nil) as? [[String]],
           list.count == 2, list[0].count == 1, list[1].count == 1 { return list[0][0] }
        if let data = part.representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue })?.data,
           let rich = NSAttributedString(rtf: data, documentAttributes: nil) { return rich.string }
        for representation in part.representations {
            if let text = plainText(representation) { return text }
        }
        return nil
    }

    private static func plainText(_ representation: ClipboardRepresentation) -> String? {
        let type = representation.typeIdentifier
        guard UTType(type)?.conforms(to: .plainText) == true else { return nil }
        if type == "public.utf16-plain-text" || type == "public.utf16-external-plain-text" {
            let bytes = representation.data
            guard bytes.count.isMultiple(of: 2) else { return nil }
            let prefix = Array(bytes.prefix(2))
            if prefix == [0xff, 0xfe] || prefix == [0xfe, 0xff] { return String(data: bytes, encoding: .utf16) }
            // The internal pasteboard UTF-16 format uses the Mac's native byte order.
            return String(data: bytes, encoding: type == "public.utf16-plain-text" ? .utf16LittleEndian : .utf16BigEndian)
        }
        return String(data: representation.data, encoding: .utf8)
    }

    private static func summaryText(in part: ClipboardPart) -> String {
        if let file = part.representations.first(where: { ClipboardFileAccess.isFileURLType($0.typeIdentifier) }),
           let url = ClipboardFileAccess.url(from: file.data) { return url.path }
        if let text = representedText(in: part) {
            let isURL = part.representations.contains {
                $0.typeIdentifier == NSPasteboard.PasteboardType.URL.rawValue || browserURLListTypes.contains($0.typeIdentifier)
            }
            // Keep an untouched URL object's display text searchable as well as its address.
            if isURL, let title = part.representations.compactMap(plainText).first,
               !title.isEmpty, title != text { return title + "\n" + text }
            return text
        }
        // For image/PDF/opaque siblings, reuse capture's bounded metadata-only summary.
        // The original object bytes remain untouched even when no text can be decoded.
        let snapshot = ClipboardCaptureSnapshot(parts: [part], byteCount: 0)
        return (try? ClipboardCodec.record(from: snapshot).text) ?? L10n.text("Clipboard item")
    }

    private static func canonicalLink(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp"].contains(scheme),
              scheme == "mailto" || !(url.host ?? "").isEmpty else { return nil }
        return url
    }

    private static func replaceText(in contents: NSMutableAttributedString, with text: String) {
        guard contents.string != text else { return }
        let attributes = contents.length == 0 ? [:] : contents.attributes(at: 0, effectiveRange: nil)
        contents.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func containsAttachment(_ contents: NSAttributedString) -> Bool {
        if contents.string.contains("\u{FFFC}") { return true }
        var found = false
        contents.enumerateAttribute(.attachment, in: NSRange(location: 0, length: contents.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private static func richTextError(_ data: Data) -> ClipboardEditPlanError? {
        guard let contents = NSAttributedString(rtf: data, documentAttributes: nil) else { return .invalidRichText }
        return containsAttachment(contents) ? .attachments : nil
    }

    /// Avoid importing HTML through AppKit (which can resolve external resources). This conservative
    /// check keeps embedded objects out of a text-only editor; text HTML is explicitly converted.
    private static func htmlContainsObjects(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else { return true }
        return text.range(of: #"<\s*(?:img|svg|math|object|embed|video|audio|canvas|iframe)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func webArchiveError(_ data: Data) -> ClipboardEditPlanError? {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let resource = archive["WebMainResource"] as? [String: Any],
              let content = resource["WebResourceData"] as? Data,
              let mime = resource["WebResourceMIMEType"] as? String, mime.lowercased() == "text/html" else {
            return .unsupportedRepresentation("com.apple.webarchive")
        }
        if htmlContainsObjects(content) { return .attachments }
        if let value = archive["WebSubframeArchives"] {
            guard let frames = value as? [Any] else { return .unsupportedRepresentation("com.apple.webarchive") }
            if !frames.isEmpty { return .attachments }
        }
        if let value = archive["WebSubresources"] {
            guard let resources = value as? [[String: Any]] else { return .unsupportedRepresentation("com.apple.webarchive") }
            if resources.contains(where: {
                guard let mime = $0["WebResourceMIMEType"] as? String, $0["WebResourceData"] is Data else { return true }
                return !mime.lowercased().hasPrefix("text/")
            }) { return .attachments }
        }
        return nil
    }

    // Explicit ancillary formats, not an org.chromium/com.apple prefix allow-list. The URL/title
    // and smart-paste dynamic UTIs are published in Chromium's clipboard_constants_mac.mm.
    private static let browserMetadataTypes: Set<String> = [
        "public.url-name", "org.chromium.source-url", "org.chromium.content-disposition",
        "NeXT smart paste pasteboard type",
        "dyn.ah62d4rv4gu8y63n2nuuhg5pbsm4ca6dbsr4gnkduqf31k3pcr7u1e3basv61a3k",
    ]
    private static let browserURLListTypes: Set<String> = [
        "WebURLsWithTitlesPboardType", "dyn.ah62d4rv4gu8zs3pcnzme2641rf4guzdmsv0gn64uqm10c6xenv61a3k",
    ]
    private static let webArchiveTypes: Set<String> = ["com.apple.webarchive", "Apple Web Archive pasteboard type"]
}
