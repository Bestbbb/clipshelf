import AppKit
import ClipShelfCore

/// Keeps file URLs alive after their receiver leaves this process. Publications
/// are durable; stopping observation or completing a paste never retires them.
@MainActor
final class OwnedFilePublicationCoordinator {
    static let pasteboardType = NSPasteboard.PasteboardType("io.github.bestbbb.clipshelf.owned-publication")
    private let store: HistoryStore
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    var onError: ((Error) -> Void)?

    init(store: HistoryStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
    }

    func retain(_ records: [ClipboardRecord], purpose: OwnedAssetRetentionPurpose = .output) throws -> OwnedAssetLease {
        let lease = try store.retainCapturedOwnedFiles(records, purpose: purpose)
        // Retention alone does not approve an unsafe or missing projection.
        try store.validateCapturedFileOutput(records)
        return lease
    }

    func publish(_ records: [ClipboardRecord], purpose: OwnedAssetPublicationPurpose) throws -> OwnedAssetPublication {
        try publish(lease: retain(records), purpose: purpose)
    }

    func publish(lease: OwnedAssetLease, purpose: OwnedAssetPublicationPurpose) throws -> OwnedAssetPublication {
        try store.publishOwnedFiles(lease: lease, purpose: purpose)
    }

    /// A URL already validated by the preview/open flow still needs its own
    /// durable publication before Launch Services can hand it to another app.
    func publish(fileURL: URL, purpose: OwnedAssetPublicationPurpose) throws -> OwnedAssetPublication {
        let record = ClipboardRecord(text: fileURL.lastPathComponent, parts: [ClipboardPart(representations: [
            ClipboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue,
                                    data: Data(fileURL.absoluteString.utf8))
        ])])
        return try publish([record], purpose: purpose)
    }

    func startObserving() {
        guard timer == nil else { return }
        reconcileClipboard()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileClipboard() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopObserving() {
        timer?.invalidate()
        timer = nil
    }

    /// changeCount is a consistency check, not identity: its values can be
    /// reused after a restart. A retained URL without our token also remains live.
    func reconcileClipboard() {
        do {
            let publications = try store.ownedPublications(purpose: .clipboard)
            guard !publications.isEmpty else { return }
            let before = pasteboard.changeCount
            // A nil read is ambiguous (including unavailable/locked pasteboard).
            // Conservatively wait for a complete readable observation.
            guard let items = pasteboard.pasteboardItems else { return }
            var tokens = Set<String>(), paths = Set<String>()
            for item in items {
                if item.types.contains(Self.pasteboardType) {
                    guard let token = item.string(forType: Self.pasteboardType) else { return }
                    tokens.insert(token)
                }
                for type in item.types where ClipboardFileAccess.isFileURLType(type.rawValue) {
                    guard let data = item.data(forType: type), let url = ClipboardFileAccess.url(from: data) else { return }
                    paths.insert(url.standardizedFileURL.path)
                }
            }
            guard pasteboard.changeCount == before else { return }
            for publication in publications {
                guard !tokens.contains(publication.id.uuidString),
                      !publication.fileURLs.contains(where: { paths.contains($0.standardizedFileURL.path) }) else { continue }
                // Recheck immediately before each mutation, including after a
                // prior SQLite call. Unknown or racing observations retain roots.
                guard pasteboard.changeCount == before else { return }
                try store.releaseOwnedPublication(publication)
            }
        } catch { onError?(error) }
    }
}
