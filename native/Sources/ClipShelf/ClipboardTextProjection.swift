import AppKit
import ClipShelfCore
import UniformTypeIdentifiers

/// Explicit format conversion uses represented content, never a card's display summary.
@MainActor
enum ClipboardTextProjection {
    static func text(in record: ClipboardRecord) -> String? {
        guard record.kind != .file, record.kind != .image else { return nil }
        guard !record.parts.isEmpty else { return record.text }
        var values: [String] = []
        for part in record.parts {
            guard let value = text(in: part) else { return nil }
            values.append(value)
        }
        return values.joined(separator: "\n")
    }

    private static func text(in part: ClipboardPart) -> String? {
        // The plain-text representation of a browser bookmark may be its title.
        if let url = part.representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.URL.rawValue }) {
            return String(data: url.data, encoding: .utf8)
        }
        if let links = part.representations.first(where: {
            ["WebURLsWithTitlesPboardType", "dyn.ah62d4rv4gu8zs3pcnzme2641rf4guzdmsv0gn64uqm10c6xenv61a3k"].contains($0.typeIdentifier)
        }) {
            guard let list = try? PropertyListSerialization.propertyList(from: links.data, format: nil) as? [[String]],
                  list.count == 2, !list[0].isEmpty, list[0].count == list[1].count else { return nil }
            return list[0].joined(separator: "\n")
        }
        // Prefer the source application's explicit text conversion over decoding a document.
        for representation in part.representations {
            guard UTType(representation.typeIdentifier)?.conforms(to: .plainText) == true else { continue }
            let data = representation.data
            let type = representation.typeIdentifier
            if type == "public.utf16-plain-text" || type == "public.utf16-external-plain-text" {
                guard data.count.isMultiple(of: 2) else { continue }
                let prefix = Array(data.prefix(2))
                let encoding: String.Encoding = prefix == [0xff, 0xfe] || prefix == [0xfe, 0xff]
                    ? .utf16 : (type == "public.utf16-plain-text" ? .utf16LittleEndian : .utf16BigEndian)
                if let value = String(data: data, encoding: encoding) { return value }
            } else if let value = String(data: data, encoding: .utf8) { return value }
        }
        guard let rtf = part.representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue }) else { return nil }
        // RTF-only objects must have a complete textual projection. Do not emit attachment placeholders.
        do { try ClipboardPartEdit.validateEditablePart(ClipboardPart(representations: [rtf])) }
        catch { return nil }
        guard let value = NSAttributedString(rtf: rtf.data, documentAttributes: nil),
              !value.string.contains("\u{fffc}") else { return nil }
        var hasAttachment = false
        value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, _, stop in
            if attachment != nil { hasAttachment = true; stop.pointee = true }
        }
        return hasAttachment ? nil : value.string
    }
}
