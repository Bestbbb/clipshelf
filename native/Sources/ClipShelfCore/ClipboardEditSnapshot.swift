import Foundation

/// OCR freshly derived from the first image shown in the clipboard preview.
/// The store binds it to the submitted image bytes before preserving it across an edit.
public struct ClipboardImageOCR: Equatable, Sendable {
    public let text: String
    public let sourceImageDigest: String

    public init(text: String, sourceImageDigest: String) {
        self.text = text
        self.sourceImageDigest = sourceImageDigest
    }
}

/// A frozen original and the account generations under which editing was allowed.
/// Only HistoryStore can bind a snapshot to a live store instance.
public struct ClipboardEditSnapshot: Equatable, Sendable {
    public let record: ClipboardRecord
    public let syncConfiguration: SyncConfiguration
    public let sharingConfiguration: SyncConfiguration
    let storeIdentity: UUID

    /// A display-only local draft; it grants no database mutation capability.
    public init(record: ClipboardRecord) {
        self.init(record: record, syncConfiguration: .init(accountID: nil, generation: 0),
                  sharingConfiguration: .init(accountID: nil, generation: 0))
    }

    /// Display-only input for previews and injected UI tests. A store rejects it on commit.
    public init(record: ClipboardRecord, syncConfiguration: SyncConfiguration,
                sharingConfiguration: SyncConfiguration) {
        self.init(record: record, syncConfiguration: syncConfiguration,
                  sharingConfiguration: sharingConfiguration, storeIdentity: UUID())
    }

    init(record: ClipboardRecord, syncConfiguration: SyncConfiguration,
         sharingConfiguration: SyncConfiguration, storeIdentity: UUID) {
        self.record = record
        self.syncConfiguration = syncConfiguration
        self.sharingConfiguration = sharingConfiguration
        self.storeIdentity = storeIdentity
    }
}
