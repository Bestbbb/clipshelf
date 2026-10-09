import ClipShelfLocalization
import ClipShelfCore
import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

enum EncryptedBackupError: LocalizedError {
    case passwordTooShort, invalidBackup, cannotEncrypt
    var errorDescription: String? {
        switch self {
        case .passwordTooShort: return L10n.text("备份密码需至少 8 个字符且最多 1024 字节。")
        case .invalidBackup: return L10n.text("密码不正确，或备份已损坏、超出大小限制或使用了不支持的版本。")
        case .cannotEncrypt: return L10n.text("无法创建加密备份，请稍后重试。")
        }
    }
}

/// Version 1: magic || 16-byte salt || CryptoKit combined AES-GCM box.
/// The magic and salt are authenticated. PBKDF2-HMAC-SHA256 uses 600,000 rounds
/// and a 256-bit key. The iteration count is fixed by version, never file-controlled.
enum EncryptedBackupService {
    private static let magic = Data([0x43, 0x53, 0x42, 0x4b, 0x01])
    private static let maximumSize = 512 * 1024 * 1024

    static func isEncrypted(_ url: URL) throws -> Bool {
        let (file, _) = try openSource(url)
        defer { try? file.close() }
        return try file.read(upToCount: 4) == magic.prefix(4)
    }

    static func seal(_ plaintext: Data, password: String) throws -> Data {
        guard password.count >= 8, password.utf8.count <= 1024 else { throw EncryptedBackupError.passwordTooShort }
        guard plaintext.count <= maximumSize else { throw EncryptedBackupError.invalidBackup }
        var salt = Data(count: 16)
        let random = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard random == errSecSuccess else { throw EncryptedBackupError.cannotEncrypt }
        let header = magic + salt
        let key = try derive(password, salt: salt)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = box.combined else { throw EncryptedBackupError.cannotEncrypt }
        return header + combined
    }

    static func open(_ data: Data, password: String) throws -> Data {
        guard data.count >= 49, data.count <= maximumSize + 49,
              data.prefix(5) == magic, !password.isEmpty, password.utf8.count <= 1024 else { throw EncryptedBackupError.invalidBackup }
        do {
            let key = try derive(password, salt: data.subdata(in: 5..<21))
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(21))
            return try AES.GCM.open(box, using: key, authenticating: data.prefix(21))
        } catch { throw EncryptedBackupError.invalidBackup }
    }

    static func export(store: HistoryStore, to destination: URL, password: String) throws {
        // The chosen destination may be a synced folder or remote volume. Plaintext
        // must never be staged there, even temporarily or with restrictive permissions.
        let localStaging = try temporaryDirectory(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: localStaging) }
        let plain = localStaging.appendingPathComponent("archive.clipshelf")
        try store.exportBackup(to: plain)
        let ciphertext = try seal(Data(contentsOf: plain), password: password)
        let staging = try temporaryDirectory(in: destination.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: staging) }
        let encrypted = staging.appendingPathComponent("encrypted.clipshelf")
        try ciphertext.write(to: encrypted, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encrypted.path)
        // A complete file is published only after sealing succeeds; existing files are never overwritten.
        try FileManager.default.moveItem(at: encrypted, to: destination)
    }

    static func restore(store: HistoryStore, from source: URL, password: String, mode: BackupRestoreMode) throws -> BackupRestoreSummary {
        let prepared = try prepareRestore(from: source, password: password, mode: mode, store: store)
        return try store.restoreBackup(prepared)
    }

    /// Authentication and complete Core validation precede any migration or store mutation.
    /// Core owns the immutable prepared value; plaintext staging is removed before return.
    static func prepareRestore(from source: URL, password: String, mode: BackupRestoreMode, store: HistoryStore) throws -> PreparedBackupRestore {
        let plaintext = try open(readSource(source), password: password)
        let staging = try temporaryDirectory(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent("archive.clipshelf")
        try plaintext.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try store.prepareBackupRestore(from: file, mode: mode)
    }

    private static func openSource(_ url: URL) throws -> (FileHandle, stat) {
        guard url.isFileURL else { throw EncryptedBackupError.invalidBackup }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw EncryptedBackupError.invalidBackup }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumSize + 49 else {
            Darwin.close(descriptor)
            throw EncryptedBackupError.invalidBackup
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), info)
    }

    private static func readSource(_ url: URL) throws -> Data {
        let (file, before) = try openSource(url)
        defer { try? file.close() }
        var data = Data()
        // The descriptor and byte budget stay authoritative even if the path is
        // replaced or the file grows after fstat. Never use an unbounded path read.
        while let chunk = try file.read(upToCount: min(65_536, maximumSize + 50 - data.count)), !chunk.isEmpty {
            guard chunk.count <= maximumSize + 49 - data.count else { throw EncryptedBackupError.invalidBackup }
            data.append(chunk)
        }
        var after = stat()
        guard fstat(file.fileDescriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == Int(before.st_size),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw EncryptedBackupError.invalidBackup
        }
        return data
    }

    private static func temporaryDirectory(in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent(".ClipShelf-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        var key = Data(count: 32)
        defer { key.resetBytes(in: 0..<key.count) }
        var passwordData = Data(password.utf8)
        defer { passwordData.resetBytes(in: 0..<passwordData.count) }
        let status = key.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, passwordBytes.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw EncryptedBackupError.cannotEncrypt }
        return SymmetricKey(data: key)
    }
}
