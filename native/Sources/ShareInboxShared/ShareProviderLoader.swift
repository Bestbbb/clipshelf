import AppKit
import UniformTypeIdentifiers

/// NSItemProvider temporary files are consumed inside their completion block.
/// No provider URL survives the callback and no data enters the Inbox until Save.
public final class ShareProviderLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [Progress] = []
    private var cancelled = false
    private struct Loaded { let data: Data; let name: String? }

    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let pending = progress; progress.removeAll(); lock.unlock()
        pending.forEach { $0.cancel() }
    }
    private func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || Task.isCancelled { throw ShareInboxError.cancelled }
    }
    private func track(_ value: Progress) {
        lock.lock(); if cancelled { lock.unlock(); value.cancel() } else { progress.append(value); lock.unlock() }
    }
    public func load(_ providers: [NSItemProvider], into draft: ShareInboxDraft) async throws {
        guard providers.count <= ShareInboxDirectory.maximumItems else { throw ShareInboxError.tooLarge }
        // Reject the entire share before reading any bytes if any item advertises a marker.
        guard providers.allSatisfy({ ShareInboxDirectory.confidentialTypes.isDisjoint(with: $0.registeredTypeIdentifiers) }) else {
            throw ShareInboxError.confidential
        }
        try await withTaskCancellationHandler {
            for (index, provider) in providers.enumerated() {
                try check()
                let types = provider.registeredTypeIdentifiers
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let loaded = try await loadFileURL(provider)
                    try check()
                    try draft.append(data: loaded.data, typeIdentifier: "io.github.bestbbb.clipshelf.shared-file", itemIndex: index, originalFilename: loaded.name)
                    continue
                }
                var selected: [(input: String, output: String)] = []
                if let text = types.first(where: { UTType($0)?.conforms(to: .plainText) == true }) {
                    // Request a canonical UTF-8 representation when the provider can convert it.
                    selected.append((provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) ? UTType.utf8PlainText.identifier : text, UTType.utf8PlainText.identifier))
                }
                for type in [UTType.rtf.identifier, UTType.html.identifier] where types.contains(type) { selected.append((type, type)) }
                if selected.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { selected.append((UTType.url.identifier, UTType.url.identifier)) }
                if selected.isEmpty, let image = types.first(where: { UTType($0)?.conforms(to: .image) == true }) { selected.append((image, image)) }
                if selected.isEmpty, let file = types.first(where: { UTType($0)?.conforms(to: .data) == true && $0 != UTType.fileURL.identifier }) {
                    let loaded = try await loadRepresentation(provider, identifier: file)
                    try check()
                    try draft.append(data: loaded.data, typeIdentifier: "io.github.bestbbb.clipshelf.shared-file", itemIndex: index, originalFilename: provider.suggestedName ?? loaded.name ?? "Shared file")
                    continue
                }
                guard !selected.isEmpty else { throw ShareInboxError.invalidData }
                for type in selected {
                    let loaded = try await loadRepresentation(provider, identifier: type.input)
                    try check()
                    var data = loaded.data
                    if type.output == UTType.utf8PlainText.identifier && String(data: data, encoding: .utf8) == nil {
                        guard let text = String(data: data, encoding: .utf16) else { throw ShareInboxError.invalidData }
                        data = Data(text.utf8)
                    }
                    try draft.append(data: data, typeIdentifier: type.output, itemIndex: index)
                }
            }
        } onCancel: { self.cancel(); draft.cancel() }
    }
    private func loadRepresentation(_ provider: NSItemProvider, identifier: String) async throws -> Loaded {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let pending = provider.loadFileRepresentation(forTypeIdentifier: identifier) { [self] url, error in
                    do {
                        try check()
                        guard let url else { throw error ?? ShareInboxError.invalidData }
                        let data = try ShareInboxDirectory.boundedData(url, limit: ShareInboxDirectory.maximumBytes)
                        continuation.resume(returning: Loaded(data: data, name: url.lastPathComponent))
                    } catch { continuation.resume(throwing: error) }
                }
                track(pending)
            }
        } catch {
            try check()
            if let known = error as? ShareInboxError {
                switch known {
                case .tooLarge, .confidential, .cancelled: throw known
                default: break
                }
            }
            // Some text/image providers implement data but not a file representation.
            // NSItemProvider allocates that data; it is bounded before staging it.
            let suggestedName = provider.suggestedName
            return try await withCheckedThrowingContinuation { continuation in
                let pending = provider.loadDataRepresentation(forTypeIdentifier: identifier) { [self] data, error in
                    do {
                        try check()
                        guard let data else { throw error ?? ShareInboxError.invalidData }
                        guard data.count <= ShareInboxDirectory.maximumBytes else { throw ShareInboxError.tooLarge }
                        continuation.resume(returning: Loaded(data: data, name: suggestedName))
                    } catch { continuation.resume(throwing: error) }
                }
                track(pending)
            }
        }
    }
    private func loadFileURL(_ provider: NSItemProvider) async throws -> Loaded {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [self] item, error in
                do {
                    try check()
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                    else if let value = item as? String { url = URL(string: value) }
                    else { url = nil }
                    guard let url, url.isFileURL else { throw error ?? ShareInboxError.invalidData }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try ShareInboxDirectory.boundedData(url, limit: ShareInboxDirectory.maximumBytes)
                    continuation.resume(returning: Loaded(data: data, name: url.lastPathComponent))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
