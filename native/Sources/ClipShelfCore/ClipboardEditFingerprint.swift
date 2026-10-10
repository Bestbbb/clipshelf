import CryptoKit
import Foundation

/// Length-delimited, streaming hash of every persisted record field except revision. Avoids
/// a second base64-encoded copy of a potentially 512 MiB edit/Undo payload. Revision is checked
/// separately and may change only through a store-authenticated Undo receipt.
enum ClipboardEditFingerprint {
    static func digest(_ record: ClipboardRecord, canonicalIdentity: UUID? = nil) -> String {
        var writer = Writer()
        writer.string((canonicalIdentity ?? record.id).uuidString)
        writer.string(record.text); writer.string(record.sourceApp); writer.string(record.sourceBundleID)
        let timestamp = record.copiedAt.timeIntervalSinceReferenceDate
        writer.integer((timestamp == 0 ? 0.0 : timestamp).bitPattern)
        writer.data(record.rtf); writer.data(record.html)
        writer.integer(UInt64(record.parts.count))
        for part in record.parts {
            writer.integer(UInt64(part.representations.count))
            for representation in part.representations {
                writer.string(representation.typeIdentifier); writer.data(representation.data)
            }
        }
        writer.string(record.renamedTitle); writer.string(record.ocrText)
        writer.string(record.pinboardID?.uuidString)
        writer.string((record.pinboardOrderIdentity ?? canonicalIdentity ?? record.id).uuidString)
        if let order = record.pinboardOrder { writer.integer(1); writer.integer(UInt64(bitPattern: order)) }
        else { writer.integer(0) }
        writer.integer(record.isInHistory ? 1 : 0)
        writer.string(record.originDeviceID?.uuidString); writer.string(record.originDeviceName)
        writer.integer(record.originDeviceConflict ? 1 : 0)
        return writer.hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Writer {
        var hasher = SHA256()
        mutating func integer(_ value: UInt64) {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { hasher.update(bufferPointer: $0) }
        }
        mutating func string(_ value: String?) { data(value.map { Data($0.utf8) }) }
        mutating func data(_ value: Data?) {
            guard let value else { integer(0); return }
            integer(1); integer(UInt64(value.count)); hasher.update(data: value)
        }
    }
}
