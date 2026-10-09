import Darwin
import Foundation

/// Stable bytes and an independently editable projection live in separate files.
/// Only generated UUIDs and validated leaf names participate in paths.
struct OwnedFileStorage {
    let directory: URL
    static let maximumBytes = 64 * 1_024 * 1_024

    init(databaseURL: URL) throws {
        // Foundation preserves macOS's /var alias even after resolvingSymlinksInPath.
        // Resolve the caller-selected, existing database parent once with realpath;
        // every component below it (attachments/owned/UUID/files) is still no-follow.
        guard let resolved = realpath(databaseURL.deletingLastPathComponent().path, nil) else { throw HistoryStoreError.invalidOwnedFile }
        let parent = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        directory = parent.appendingPathComponent(databaseURL.deletingPathExtension().lastPathComponent + ".attachments", isDirectory: true)
            .appendingPathComponent("owned", isDirectory: true)
        let descriptor = try Self.openDirectory(directory, create: true)
        Darwin.close(descriptor)
    }

    static func validateFilename(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw HistoryStoreError.invalidOwnedFile }
    }

    func assetDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func fileURL(_ asset: OwnedFileAsset) throws -> URL {
        try Self.validateFilename(asset.filename)
        return assetDirectory(asset.id).appendingPathComponent("files", isDirectory: true).appendingPathComponent(asset.filename)
    }

    func create(_ asset: OwnedFileAsset, data: Data, didCreateDirectory: () -> Void) throws {
        try Self.validateFilename(asset.filename)
        guard data.count <= Self.maximumBytes, data.count == asset.byteCount,
              RepresentationStorage.digest(data) == asset.sha256 else { throw HistoryStoreError.invalidOwnedFile }
        let root = try Self.openDirectory(directory, create: false)
        defer { Darwin.close(root) }
        guard mkdirat(root, asset.id.uuidString, 0o700) == 0 else { throw HistoryStoreError.invalidOwnedFile }
        didCreateDirectory()
        let folder = try Self.openDirectory(assetDirectory(asset.id), create: false)
        defer { Darwin.close(folder) }
        try Self.write(data, name: "payload", at: folder)
        guard mkdirat(folder, "files", 0o700) == 0 else { throw HistoryStoreError.invalidOwnedFile }
        let files = openat(folder, "files", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard files >= 0 else { throw HistoryStoreError.invalidOwnedFile }
        defer { Darwin.close(files) }
        try Self.write(data, name: asset.filename, at: files)
        guard fsync(files) == 0, fsync(folder) == 0, fsync(root) == 0 else { throw HistoryStoreError.invalidOwnedFile }
    }

    func read(_ asset: OwnedFileAsset) throws -> Data {
        try Self.validateFilename(asset.filename)
        guard (0...Self.maximumBytes).contains(asset.byteCount), asset.sha256.count == 64,
              asset.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw HistoryStoreError.invalidOwnedFile }
        let folder = try Self.openDirectory(assetDirectory(asset.id), create: false)
        defer { Darwin.close(folder) }
        let descriptor = openat(folder, "payload", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw HistoryStoreError.corruptOwnedFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == asset.byteCount else { Darwin.close(descriptor); throw HistoryStoreError.corruptOwnedFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: asset.byteCount + 1) ?? Data()
        guard data.count == asset.byteCount, RepresentationStorage.digest(data) == asset.sha256 else { throw HistoryStoreError.corruptOwnedFile }
        return data
    }

    /// Remove only this transaction's fresh generated directory. Existing assets are never reclaimed here.
    func removeNew(_ id: UUID) {
        guard let root = try? Self.openDirectory(directory, create: false) else { return }
        defer { Darwin.close(root) }
        let folder = openat(root, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folder >= 0 else { return }
        defer { Darwin.close(folder) }
        let files = openat(folder, "files", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if files >= 0 {
            if let stream = fdopendir(files) {
                while let entry = readdir(stream) {
                    let name = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    if name != ".", name != ".." { _ = unlinkat(files, name, 0) }
                }
                closedir(stream)
            } else { Darwin.close(files) }
        }
        _ = unlinkat(folder, "files", AT_REMOVEDIR)
        _ = unlinkat(folder, "payload", 0)
        _ = unlinkat(root, id.uuidString, AT_REMOVEDIR)
    }

    private static func write(_ data: Data, name: String, at directory: Int32) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HistoryStoreError.invalidOwnedFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Walk every component with O_NOFOLLOW; rejecting a link at the final file alone is insufficient.
    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw HistoryStoreError.invalidOwnedFile }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw HistoryStoreError.invalidOwnedFile }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != ".." else { throw HistoryStoreError.invalidOwnedFile }
                if create, mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST { throw HistoryStoreError.invalidOwnedFile }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw HistoryStoreError.corruptOwnedFile }
                Darwin.close(descriptor); descriptor = next
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
}
