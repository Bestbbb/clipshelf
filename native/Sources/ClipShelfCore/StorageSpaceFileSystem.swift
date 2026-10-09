import Darwin
import Foundation
import CryptoKit

struct StorageSpaceNode: Codable, Equatable {
    let device: Int64
    let inode: UInt64
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(_ value: stat) {
        device = Int64(value.st_dev); inode = UInt64(value.st_ino); generation = value.st_gen
        birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
    }
}

enum StorageSpaceFiles {
    static func validURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.utf8.contains(0)
    }

    static func canonicalDirectory(_ url: URL) throws -> URL {
        guard validURL(url), let resolved = realpath(url.path, nil) else { throw StorageWriteFailure.destinationChanged }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let descriptor = try openDirectory(canonical)
        Darwin.close(descriptor)
        return canonical
    }

    /// All components of an already canonical path must remain directories, never links.
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard validURL(url) else { throw StorageWriteFailure.destinationChanged }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageWriteFailure.destinationChanged }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", component != ".." else { throw StorageWriteFailure.destinationChanged }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw StorageWriteFailure.destinationChanged }
                Darwin.close(descriptor); descriptor = next
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    static func info(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw StorageWriteFailure.coordinationUnavailable }
        return value
    }

    static func privateNode(_ descriptor: Int32, directory: Bool) throws -> StorageSpaceNode {
        let value = try info(descriptor)
        guard value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), value.st_uid == geteuid(),
              value.st_mode & 0o077 == 0, directory || value.st_nlink == 1 else {
            throw StorageWriteFailure.coordinationUnavailable
        }
        return StorageSpaceNode(value)
    }

    static func matches(_ identity: StorageSpaceNode, name: String, directory: Int32) -> Bool {
        var value = stat()
        return fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 && StorageSpaceNode(value) == identity
    }

    static func exists(_ name: String, directory: Int32) throws -> Bool {
        var value = stat()
        if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw StorageWriteFailure.coordinationUnavailable }
        return false
    }

    static func lock(_ descriptor: Int32) throws {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw StorageWriteFailure.coordinationUnavailable
        }
    }

    static func names(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw StorageWriteFailure.coordinationUnavailable }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw StorageWriteFailure.coordinationUnavailable }
                return result
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw StorageWriteFailure.coordinationUnavailable }
            if name == "." || name == ".." { continue }
            guard result.count < 8_192 else { throw StorageWriteFailure.coordinationUnavailable }
            result.append(name)
        }
    }

    static func read<T: Decodable>(_ type: T.Type, descriptor: Int32) throws -> T {
        let size = try info(descriptor).st_size
        guard size > 0, size <= 1_048_576 else { throw StorageWriteFailure.coordinationUnavailable }
        var data = Data(count: Int(size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw StorageWriteFailure.coordinationUnavailable }
                offset += count
            }
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw StorageWriteFailure.coordinationUnavailable }
    }

    static func write<T: Encodable>(_ value: T, descriptor: Int32) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw StorageWriteFailure.invalidRequirement }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pwrite(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }
                offset += count
            }
        }
        guard ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else { throw posixFailure() }
    }

    static func posixFailure() -> Error {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        return StorageWriteFailure.classify(error) ?? StorageWriteFailure.coordinationUnavailable
    }

    /// A checksum-invalid or incomplete slot is ignored only when the other slot supplies a
    /// complete preceding state. The caller never treats two invalid slots as an empty journal.
    static func readFrame<T: Decodable>(_ type: T.Type, descriptor: Int32, offset: Int64, maximumBytes: Int) throws -> T? {
        func bytes(_ count: Int, at offset: Int64) throws -> Data? {
            var data = Data(count: count)
            let complete = try data.withUnsafeMutableBytes { buffer -> Bool in
                var read = 0
                while read < count {
                    let result = pread(descriptor, buffer.baseAddress!.advanced(by: read), count - read, off_t(offset + Int64(read)))
                    if result < 0, errno == EINTR { continue }
                    guard result >= 0 else { throw StorageWriteFailure.coordinationUnavailable }
                    if result == 0 { return false }
                    read += result
                }
                return true
            }
            return complete ? data : nil
        }
        guard let header = try bytes(40, at: offset) else { return nil }
        var length: UInt64 = 0
        for index in 0..<8 { length |= UInt64(header[index]) << (index * 8) }
        guard length > 0, length <= UInt64(maximumBytes), let payload = try bytes(Int(length), at: offset + 40),
              Data(SHA256.hash(data: payload)) == header.subdata(in: 8..<40) else { return nil }
        return try? JSONDecoder().decode(type, from: payload)
    }

    static func writeFrame<T: Encodable>(_ value: T, descriptor: Int32, offset: Int64, maximumBytes: Int) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count > 0, payload.count <= maximumBytes else { throw StorageWriteFailure.invalidRequirement }
        let length = UInt64(payload.count)
        var data = Data((0..<8).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        data.append(Data(SHA256.hash(data: payload))); data.append(payload)
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < data.count {
                let count = pwrite(descriptor, buffer.baseAddress!.advanced(by: written), data.count - written, off_t(offset + Int64(written)))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixFailure() }
    }
}

/// A caller-selected existing ancestor is resolved once. New path components below it cannot
/// become links or switch volumes, while normal creation of initially absent directories is allowed.
struct StorageSpaceDestination: Equatable {
    let originalAnchor: URL
    let canonicalAnchor: URL
    let identity: StorageSpaceNode
    let remainingComponents: [String]

    init(_ destination: URL) throws {
        guard StorageSpaceFiles.validURL(destination) else { throw StorageWriteFailure.invalidRequirement }
        var ancestor = destination.standardizedFileURL, remaining: [String] = []
        while true {
            var value = stat()
            if lstat(ancestor.path, &value) == 0 {
                if value.st_mode & S_IFMT == S_IFDIR { break }
                // Existing final files are written through their parent. Existing links are
                // never accepted as output locations, including a dangling final link.
                guard remaining.isEmpty, value.st_mode & S_IFMT == S_IFREG else { throw StorageWriteFailure.destinationChanged }
            } else if errno != ENOENT { throw StorageWriteFailure.destinationChanged }
            guard ancestor.path != "/" else { throw StorageWriteFailure.destinationChanged }
            remaining.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        originalAnchor = ancestor
        canonicalAnchor = try StorageSpaceFiles.canonicalDirectory(ancestor)
        let descriptor = try StorageSpaceFiles.openDirectory(canonicalAnchor)
        defer { Darwin.close(descriptor) }
        identity = StorageSpaceNode(try StorageSpaceFiles.info(descriptor))
        remainingComponents = remaining
    }

    func currentDirectory() throws -> URL {
        guard try StorageSpaceFiles.canonicalDirectory(originalAnchor) == canonicalAnchor else { throw StorageWriteFailure.destinationChanged }
        var descriptor = try StorageSpaceFiles.openDirectory(canonicalAnchor)
        defer { Darwin.close(descriptor) }
        guard StorageSpaceNode(try StorageSpaceFiles.info(descriptor)) == identity else { throw StorageWriteFailure.destinationChanged }
        var path = canonicalAnchor
        for (index, component) in remainingComponents.enumerated() {
            var value = stat()
            if fstatat(descriptor, component, &value, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw StorageWriteFailure.destinationChanged }
                return path
            }
            if value.st_mode & S_IFMT == S_IFREG, index == remainingComponents.count - 1 { return path }
            guard value.st_mode & S_IFMT == S_IFDIR else { throw StorageWriteFailure.destinationChanged }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw StorageWriteFailure.destinationChanged }
            guard StorageSpaceNode(try StorageSpaceFiles.info(next)) == StorageSpaceNode(value) else {
                Darwin.close(next); throw StorageWriteFailure.destinationChanged
            }
            Darwin.close(descriptor); descriptor = next; path.appendPathComponent(component, isDirectory: true)
        }
        return path
    }
}
