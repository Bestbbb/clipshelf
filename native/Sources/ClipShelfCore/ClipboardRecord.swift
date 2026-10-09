import Foundation
import UniformTypeIdentifiers

public struct ClipboardRepresentation: Equatable, Codable, Sendable {
    public var typeIdentifier: String
    public var data: Data
    public init(typeIdentifier: String, data: Data) {
        self.typeIdentifier = typeIdentifier
        self.data = data
    }
}

public struct ClipboardPart: Equatable, Codable, Sendable {
    public var representations: [ClipboardRepresentation]
    public init(representations: [ClipboardRepresentation]) { self.representations = representations }
}

public enum ClipboardContentKind: String, Codable, CaseIterable, Sendable {
    case text, link, image, file, color
}

/// One captured clipboard item. Original text and rich representations are never normalized.
public struct ClipboardRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var text: String
    public var sourceApp: String?
    public var sourceBundleID: String?
    public var copiedAt: Date
    public var rtf: Data?
    public var html: Data?
    public var parts: [ClipboardPart]
    public var renamedTitle: String?
    public var ocrText: String?
    public var pinboardID: UUID?
    public var pinboardOrder: Int64?
    public var isInHistory: Bool
    public var revision: Int
    public var originDeviceID: UUID?
    public var originDeviceName: String?
    public var originDeviceConflict: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        sourceApp: String? = nil,
        sourceBundleID: String? = nil,
        copiedAt: Date = Date(),
        rtf: Data? = nil,
        html: Data? = nil,
        parts: [ClipboardPart] = [],
        renamedTitle: String? = nil,
        ocrText: String? = nil,
        pinboardID: UUID? = nil,
        isInHistory: Bool = true,
        revision: Int = 1,
        pinboardOrder: Int64? = nil,
        originDeviceID: UUID? = nil,
        originDeviceName: String? = nil,
        originDeviceConflict: Bool = false
    ) {
        self.id = id
        self.text = text
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.copiedAt = copiedAt
        self.rtf = rtf
        self.html = html
        self.parts = parts
        self.renamedTitle = renamedTitle
        self.ocrText = ocrText
        self.pinboardID = pinboardID
        self.pinboardOrder = pinboardOrder
        self.isInHistory = isInHistory
        self.revision = revision
        self.originDeviceID = originDeviceID
        self.originDeviceName = originDeviceName
        self.originDeviceConflict = originDeviceConflict
    }

    public var title: String {
        if let renamedTitle, !renamedTitle.isEmpty { return renamedTitle }
        let first = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        if first.isEmpty { return kind == .image ? "Image" : kind == .file ? "Files" : "Clipboard item" }
        return String(first.prefix(120))
    }

    public var preview: String { String(text.prefix(1_000)) }

    public var kind: ClipboardContentKind {
        let types = parts.flatMap(\.representations).compactMap { UTType($0.typeIdentifier) }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .file }
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), ["http", "https", "mailto", "ftp"].contains(url.scheme?.lowercased() ?? ""),
           !value.contains(where: \.isWhitespace), url.host != nil || url.scheme == "mailto" { return .link }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 6, hex.allSatisfy(\.isHexDigit),
           value.hasPrefix("#") || hex.contains(where: { "abcdefABCDEF".contains($0) }) { return .color }
        return .text
    }

    /// Ignores capture time and identity, but preserves source and representation distinctions.
    public func hasSameContents(as other: ClipboardRecord) -> Bool {
        text == other.text && sourceApp == other.sourceApp
            && sourceBundleID == other.sourceBundleID && rtf == other.rtf && html == other.html
            && parts == other.parts
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, sourceApp, sourceBundleID, copiedAt, rtf, html, parts
        case renamedTitle, ocrText, pinboardID, isInHistory, revision, pinboardOrder
        case originDeviceID, originDeviceName, originDeviceConflict
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        sourceApp = try values.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceBundleID = try values.decodeIfPresent(String.self, forKey: .sourceBundleID)
        copiedAt = try values.decode(Date.self, forKey: .copiedAt)
        rtf = try values.decodeIfPresent(Data.self, forKey: .rtf)
        html = try values.decodeIfPresent(Data.self, forKey: .html)
        parts = try values.decodeIfPresent([ClipboardPart].self, forKey: .parts) ?? []
        renamedTitle = try values.decodeIfPresent(String.self, forKey: .renamedTitle)
        ocrText = try values.decodeIfPresent(String.self, forKey: .ocrText)
        pinboardID = try values.decodeIfPresent(UUID.self, forKey: .pinboardID)
        pinboardOrder = try values.decodeIfPresent(Int64.self, forKey: .pinboardOrder)
        originDeviceID = try values.decodeIfPresent(UUID.self, forKey: .originDeviceID)
        originDeviceName = try values.decodeIfPresent(String.self, forKey: .originDeviceName)
        originDeviceConflict = try values.decodeIfPresent(Bool.self, forKey: .originDeviceConflict) ?? false
        isInHistory = try values.decodeIfPresent(Bool.self, forKey: .isInHistory) ?? true
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    }
}
