import AppKit
import ClipShelfCore
import Foundation

/// Synthetic acceptance data. The caller supplies its isolated validation directory;
/// no pasteboard, existing file contents, capture or background integrations are read.
@MainActor
enum EditValidationFixtures {
    static func records(directory: URL) throws -> [ClipboardRecord] {
        let folder = directory.appendingPathComponent("EditValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("synthetic-attachment.txt")
        try Data("Synthetic ClipShelf editing acceptance attachment.\n".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let richText = "QA first object: bold text\nSecond line stays editable."
        let rich = try ClipboardEditPlan.encodeNativeRTF(NSAttributedString(string: richText, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.systemBlue,
        ]))
        let address = "https://qa.example.test/actual-address"
        let link = ClipboardPart(representations: [
            representation("public.utf8-plain-text", "QA display title, not the address"),
            representation("public.url", address),
            representation("public.url-name", "QA display title, not the address"),
        ])
        let lastText = "QA last object: UTF16 中文 🧪"
        let utf16 = Data(lastText.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
        let parts: [ClipboardPart] = [
            .init(representations: [representation("public.utf8-plain-text", richText),
                                    .init(typeIdentifier: "public.rtf", data: rich)]),
            link,
            .init(representations: [representation("public.utf8-plain-text", "#457B9D")]),
            .init(representations: [representation("public.file-url", file.absoluteString)]),
            .init(representations: [.init(typeIdentifier: "io.github.bestbbb.clipshelf.synthetic-opaque", data: Data([0, 1, 2, 255]))]),
            .init(representations: [.init(typeIdentifier: "public.utf16-plain-text", data: utf16)]),
        ]
        return try [("QA Mixed Objects", parts), ("QA URL Title", [link])].map { title, objects in
            let bytes = objects.flatMap(\.representations).reduce(0) { $0 + $1.data.count }
            let snapshot = ClipboardCaptureSnapshot(parts: objects, sourceApp: "Synthetic QA",
                sourceBundleID: "io.github.bestbbb.clipshelf.validation-fixture", byteCount: bytes)
            var record = try ClipboardCodec.record(from: snapshot)
            record.renamedTitle = title
            return record
        }
    }

    private static func representation(_ type: String, _ text: String) -> ClipboardRepresentation {
        .init(typeIdentifier: type, data: Data(text.utf8))
    }
}
