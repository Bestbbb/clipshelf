import ClipShelfLocalization
import AppKit
import ClipShelfCore
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum ImageFileOutputError: Error, LocalizedError {
    case noImage, invalidImage, imageTooLarge, invalidDestination
    var errorDescription: String? {
        switch self {
        case .noImage: return L10n.text("所选内容中没有可转为文件的图片。")
        case .invalidImage: return L10n.text("有图片无法解码，未输出任何内容。")
        case .imageTooLarge: return L10n.text("所选图片超过本次转换的大小限制，未输出任何内容。")
        case .invalidDestination: return L10n.text("图片文件的保存位置不可用。")
        }
    }
}

/// Preparation owns bytes only. It can run off the main thread and never creates files.
enum ImageFileOutput {
    static func hasImages(in records: [ClipboardRecord]) -> Bool {
        records.contains { $0.parts.contains(where: isImagePart) }
    }

    static func prepare(_ records: [ClipboardRecord]) throws -> PreparedImageFileOutput {
        var images: [PreparedImageFileOutput.Image] = []
        var pixels = 0
        var bytes = 0
        for (recordIndex, record) in records.enumerated() {
            for (partIndex, part) in record.parts.enumerated() {
                try Task.checkCancellation()
                guard isImagePart(part) else { try validateFiles(in: part); continue }
                let candidates = part.representations.filter { UTType($0.typeIdentifier)?.conforms(to: .image) == true }
                var png: Data?
                for candidate in candidates {
                    guard let source = CGImageSourceCreateWithData(candidate.data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                          width > 0, height > 0 else { continue }
                    let product = width.multipliedReportingOverflow(by: height)
                    guard !product.overflow, product.partialValue <= 64 * 1_024 * 1_024 - pixels else {
                        throw ImageFileOutputError.imageTooLarge
                    }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                        kCGImageSourceShouldCacheImmediately: true]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
                    let data = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { continue }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { continue }
                    guard data.length <= 512 * 1_024 * 1_024 - bytes else { throw ImageFileOutputError.imageTooLarge }
                    pixels += product.partialValue; bytes += data.length
                    png = data as Data
                    break
                }
                guard let png else { throw ImageFileOutputError.invalidImage }
                images.append(.init(recordIndex: recordIndex, partIndex: partIndex,
                                    filename: "ClipShelf-\(UUID().uuidString).png", data: png))
            }
        }
        guard !images.isEmpty else { throw ImageFileOutputError.noImage }
        try Task.checkCancellation()
        return PreparedImageFileOutput(records: records, images: images)
    }

    fileprivate static func isImagePart(_ part: ClipboardPart) -> Bool {
        !part.representations.contains { ClipboardFileAccess.isFileURLType($0.typeIdentifier) } &&
        part.representations.contains { UTType($0.typeIdentifier)?.conforms(to: .image) == true }
    }

    fileprivate static func validateFiles(in part: ClipboardPart) throws {
        for value in part.representations where ClipboardFileAccess.isFileURLType(value.typeIdentifier) {
            guard let url = ClipboardFileAccess.url(from: value.data), ClipboardFileAccess.availability(of: url) == .available else {
                throw ClipboardCodecError.unavailableFile
            }
        }
    }
}

struct PreparedImageFileOutput: Sendable {
    fileprivate struct Image: Sendable {
        let recordIndex: Int
        let partIndex: Int
        let filename: String
        let data: Data
    }
    fileprivate let records: [ClipboardRecord]
    fileprivate let images: [Image]
    var imageCount: Int { images.count }

    /// Each promised image lives in its provider, even when this prepared value is released.
    @MainActor func draggingWriters() throws -> [NSPasteboardWriting] {
        var result: [NSPasteboardWriting] = []
        for (recordIndex, record) in records.enumerated() {
            if record.parts.isEmpty { result += try ClipboardCodec.items(for: [record], plainText: false); continue }
            for (partIndex, part) in record.parts.enumerated() {
                if let image = images.first(where: { $0.recordIndex == recordIndex && $0.partIndex == partIndex }) {
                    result.append(RetainedImageFilePromiseProvider(image: image))
                } else {
                    var fragment = record; fragment.parts = [part]
                    result += try ClipboardCodec.items(for: [fragment], plainText: false)
                }
            }
        }
        return result
    }

    /// Clipboard URLs need local backing files. They are retained for at least 24 hours,
    /// then eligible for cleanup on a later export; this is not receiver acknowledgement.
    func exportReceipt(directory: URL? = nil, now: Date = Date()) throws -> ImageFileExportReceipt {
        for record in records { for part in record.parts { try ImageFileOutput.validateFiles(in: part) } }
        try Task.checkCancellation()
        let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.bestbbb.clipshelf/ImageExports", isDirectory: true)
        guard ClipboardFileAccess.url(from: Data(root.absoluteString.utf8)) != nil else { throw ImageFileOutputError.invalidDestination }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ImageFileOutputError.invalidDestination }
        var result = records
        var written: [ImageFileIdentity] = []
        do {
            for image in images {
                try Task.checkCancellation()
                let url = root.appendingPathComponent(image.filename)
                written.append(try ImageFileWriter.write(image.data, to: url))
                result[image.recordIndex].parts[image.partIndex] = ClipboardPart(representations: [
                    ClipboardRepresentation(typeIdentifier: UTType.fileURL.identifier, data: Data(url.absoluteString.utf8))])
            }
            try Task.checkCancellation()
        } catch {
            written.forEach { $0.discard() }
            throw error
        }
        Self.cleanOldExports(in: root, preserving: Set(written.map { $0.url.lastPathComponent }), now: now)
        return ImageFileExportReceipt(records: result, files: written)
    }

    func exportRecords(directory: URL? = nil, now: Date = Date()) throws -> [ClipboardRecord] {
        try exportReceipt(directory: directory, now: now).records
    }

    private static func cleanOldExports(in root: URL, preserving current: Set<String>, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where !current.contains(file.lastPathComponent) && file.pathExtension == "png" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("ClipShelf-"), UUID(uuidString: String(stem.dropFirst(10))) != nil else { continue }
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  now.timeIntervalSince1970 - Double(info.st_birthtimespec.tv_sec) > 86_400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

struct ImageFileExportReceipt: Sendable {
    let records: [ClipboardRecord]
    fileprivate let files: [ImageFileIdentity]
    var fileURLs: [URL] { files.map(\.url) }
    /// Call only if the URLs were never published to a pasteboard or receiving application.
    func discardUnpublished() { files.forEach { $0.discard() } }
}

fileprivate struct ImageFileIdentity: Sendable {
    let url: URL
    let device: dev_t
    let inode: ino_t
    func discard() {
        var current = stat()
        guard lstat(url.path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == device, current.st_ino == inode else { return }
        unlink(url.path)
    }
}

private enum ImageFileWriter {
    @discardableResult static func write(_ data: Data, to url: URL) throws -> ImageFileIdentity {
        guard ClipboardFileAccess.url(from: Data(url.absoluteString.utf8)) != nil else { throw ImageFileOutputError.invalidDestination }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO); close(fd); throw error
        }
        let identity = ImageFileIdentity(url: url, device: info.st_dev, inode: info.st_ino)
        var closed = false
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += count
                }
            }
            let result = close(fd); closed = true
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return identity
        } catch {
            if !closed { close(fd) }
            identity.discard()
            throw error
        }
    }
}

@MainActor private final class RetainedImageFilePromiseProvider: NSFilePromiseProvider {
    private let retainedDelegate: ImageFilePromiseDelegate
    init(image: PreparedImageFileOutput.Image) {
        let delegate = ImageFilePromiseDelegate(filename: image.filename, data: image.data)
        retainedDelegate = delegate
        super.init()
        fileType = UTType.png.identifier
        self.delegate = delegate
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ImageFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let filename: String
    let data: Data
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "ClipShelf.image-file-promises"
        queue.qualityOfService = .userInitiated; queue.maxConcurrentOperationCount = 1
        return queue
    }()
    init(filename: String, data: Data) { self.filename = filename; self.data = data }
    @MainActor func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { filename }
    @MainActor func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do { try ImageFileWriter.write(data, to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
}
