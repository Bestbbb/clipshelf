import AppKit
import ClipShelfCore
import UniformTypeIdentifiers

enum ClipboardEditPlanError: LocalizedError, Equatable {
    case multipleObjects
    case unsupportedRepresentation(String)
    case attachments
    case invalidRichText
    case invalidLink
    case invalidColor
    case richTextEncodingFailed

    var errorDescription: String? {
        switch self {
        case .multipleObjects: return "此条目包含多个对象，暂不支持原位文本编辑；原内容已保留。"
        case .unsupportedRepresentation(let type): return "此条目包含暂不支持编辑的格式（\(type)）；原内容已保留。"
        case .attachments: return "此条目包含附件或非文本对象，不能作为纯文本保存；原内容已保留。"
        case .invalidRichText: return "原富文本无法完整读取，不能覆盖保存；可继续查看原条目。"
        case .invalidLink: return "请输入完整的 http、https、mailto 或 ftp 链接，链接内部不能含空白。"
        case .invalidColor: return "请输入六位 RGB 十六进制颜色，例如 #12ABEF；不支持透明度或缩写。"
        case .richTextEncodingFailed: return "无法保存富文本格式，草稿已保留，请重试。"
        }
    }
}

/// A text edit replaces alternate encodings of one text object, never arbitrary clipboard objects.
/// Browser source/title/smart-paste metadata is intentionally discarded with the old HTML/URL data.
@MainActor
enum ClipboardEditPlan {
    static func makeRecord(
        original: ClipboardRecord,
        contents: NSAttributedString,
        encodeRTF: @MainActor (NSAttributedString) throws -> Data = encodeNativeRTF
    ) throws -> ClipboardRecord {
        if let error = editingError(original: original) { throw error }
        if let error = validationError(original: original, text: contents.string) { throw error }
        guard !containsAttachment(contents) else { throw ClipboardEditPlanError.attachments }

        let edited = NSMutableAttributedString(attributedString: contents)
        var link: URL?
        if isLinkRecord(original) {
            guard let url = canonicalLink(contents.string) else { throw ClipboardEditPlanError.invalidLink }
            link = url
            replaceText(in: edited, with: url.absoluteString)
            let range = NSRange(location: 0, length: edited.length)
            edited.removeAttribute(.link, range: range)
            edited.addAttribute(.link, value: url, range: range)
        } else if original.kind == .color {
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
