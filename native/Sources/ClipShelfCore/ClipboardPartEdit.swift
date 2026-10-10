import Foundation
import UniformTypeIdentifiers

/// Replaces one existing text object. Projections describe the complete resulting record;
/// its identity, placement, capture metadata, OCR and all other objects remain unchanged.
public struct ClipboardPartEdit: Sendable {
    public let partIndex: Int
    public let replacement: ClipboardPart
    public let text: String
    public let rtf: Data?
    public let html: Data?

    public init(partIndex: Int, replacement: ClipboardPart, text: String, rtf: Data?, html: Data?) {
        self.partIndex = partIndex; self.replacement = replacement
        self.text = text; self.rtf = rtf; self.html = html
    }

    public func applying(to original: ClipboardRecord) throws -> ClipboardRecord {
        guard original.parts.indices.contains(partIndex) else { throw HistoryStoreError.invalidSelection }
        try Self.validateEditablePart(original.parts[partIndex])
        try Self.validateEditablePart(replacement)
        guard text.utf8.count <= RepresentationStorage.maximumRepresentationBytes,
              (rtf?.count ?? 0) <= RepresentationStorage.maximumRepresentationBytes,
              (html?.count ?? 0) <= RepresentationStorage.maximumRepresentationBytes else { throw HistoryStoreError.valueTooLarge }
        // A record-level rich payload represents the whole clipboard. Borrowing one object's
        // RTF/HTML in a multi-object record would make combined output lose the other objects.
        let expectedRTF = original.parts.count == 1 ? replacement.representations.first(where: { $0.typeIdentifier == "public.rtf" })?.data : nil
        let expectedHTML = original.parts.count == 1 ? replacement.representations.first(where: { $0.typeIdentifier == "public.html" })?.data : nil
        guard rtf == expectedRTF, html == expectedHTML else { throw HistoryStoreError.invalidStoredRecord }
        var result = original
        result.parts[partIndex] = replacement
        result.text = text; result.rtf = rtf; result.html = html
        return result
    }

    /// Shared format boundary for the editor and commit path. Editors additionally validate
    /// that rich text can be decoded without attachments before offering a text draft.
    public static func validateEditablePart(_ part: ClipboardPart) throws {
        guard !part.representations.isEmpty, part.representations.count <= 100,
              Set(part.representations.map(\.typeIdentifier)).count == part.representations.count else { throw HistoryStoreError.invalidStoredRecord }
        var hasTextContent = false
        for representation in part.representations {
            let identifier = representation.typeIdentifier
            guard !identifier.isEmpty, identifier.count <= 1_024,
                  representation.data.count <= RepresentationStorage.maximumRepresentationBytes else { throw HistoryStoreError.valueTooLarge }
            if identifier == "public.rtf" {
                // RTF parsing/encoding belongs to the editor. The Core boundary refuses object
                // destinations rather than allowing an attachment to disappear during a text edit.
                guard representation.data.starts(with: #"{\rtf"#.utf8),
                      !rtfContainsObjects(representation.data) else { throw HistoryStoreError.invalidStoredRecord }
                hasTextContent = true
            } else if identifier == "public.html" {
                guard !htmlContainsObjects(representation.data) else { throw HistoryStoreError.invalidStoredRecord }
                hasTextContent = true
            } else if browserMetadataTypes.contains(identifier) {
                continue
            } else if browserURLListTypes.contains(identifier) {
                guard let list = try? PropertyListSerialization.propertyList(from: representation.data, format: nil) as? [[String]],
                      list.count == 2, list[0].count == 1, list[1].count == 1,
                      let url = URL(string: list[0][0]), url.scheme != nil, !url.isFileURL else { throw HistoryStoreError.invalidStoredRecord }
                hasTextContent = true
            } else if webArchiveTypes.contains(identifier) {
                guard isTextWebArchive(representation.data) else { throw HistoryStoreError.invalidStoredRecord }
                hasTextContent = true
            } else {
                guard let type = UTType(identifier),
                      !type.conforms(to: .fileURL), !type.conforms(to: .image), !type.conforms(to: .pdf),
                      !type.conforms(to: .rtfd),
                      type.conforms(to: .plainText) || type == .url else { throw HistoryStoreError.invalidStoredRecord }
                if type == .url {
                    guard let value = String(data: representation.data, encoding: .utf8), let url = URL(string: value),
                          url.scheme != nil, !url.isFileURL else { throw HistoryStoreError.invalidStoredRecord }
                }
                hasTextContent = true
            }
        }
        guard hasTextContent else { throw HistoryStoreError.invalidStoredRecord }
    }

    /// Inspect RTF control words, not text that happens to spell one after an escaped slash.
    /// Full document decoding remains the editor's responsibility. Binary runs are refused
    /// rather than interpreting their arbitrary bytes as ordinary text or controls.
    private static func rtfContainsObjects(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
            func isHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
            var offset = 0
            while offset < bytes.count {
                guard bytes[offset] == 92 else { offset += 1; continue }
                offset += 1
                guard offset < bytes.count else { return true }
                switch bytes[offset] {
                case 92, 123, 125: // Escaped backslash or brace is one literal character.
                    offset += 1
                case 39: // Hex escapes are literal bytes, including an encoded backslash.
                    guard bytes.count - offset >= 3, isHex(bytes[offset + 1]), isHex(bytes[offset + 2]) else { return true }
                    offset += 3
                default:
                    let start = offset
                    while offset < bytes.count, isLetter(bytes[offset]) { offset += 1 }
                    if offset == start { offset += 1; continue } // Other control symbol.
                    // An optional signed numeric parameter follows the complete word;
                    // it is not part of its name (for example, \bin10 remains forbidden).
                    guard offset - start <= 11 else { continue }
                    let word = String(decoding: bytes[start..<offset], as: UTF8.self).lowercased()
                    switch word {
                    case "pict", "object", "objdata", "nextgraphic", "attachment", "bin": return true
                    default: break
                    }
                }
            }
            return false
        }
    }

    private static func htmlContainsObjects(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else { return true }
        return text.range(of: #"<\s*(?:img|svg|math|object|embed|video|audio|canvas|iframe)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isTextWebArchive(_ data: Data) -> Bool {
        guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let resource = archive["WebMainResource"] as? [String: Any],
              let content = resource["WebResourceData"] as? Data,
              let mime = resource["WebResourceMIMEType"] as? String, mime.lowercased() == "text/html",
              !htmlContainsObjects(content) else { return false }
        if let value = archive["WebSubframeArchives"] {
            guard let frames = value as? [Any], frames.isEmpty else { return false }
        }
        if let value = archive["WebSubresources"] {
            guard let resources = value as? [[String: Any]], resources.allSatisfy({ resource in
                guard let mime = resource["WebResourceMIMEType"] as? String, resource["WebResourceData"] is Data else { return false }
                return mime.lowercased().hasPrefix("text/")
            }) else { return false }
        }
        return true
    }

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
