import ClipShelfCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageRotationError: Error, LocalizedError, Equatable {
    case noImage, invalidImage, imageTooLarge, unsupportedAnimation, encodingFailed

    var errorDescription: String? {
        switch self {
        case .noImage: return "这条记录没有可旋转的图片。"
        case .invalidImage: return "图片无法完整解码，原内容未修改。"
        case .imageTooLarge: return "图片的总像素或输出大小超过旋转限制，原内容未修改。"
        case .unsupportedAnimation: return "暂时无法完整保留这种图片的全部帧或播放时序，原内容未修改。"
        case .encodingFailed: return "旋转后的图片无法完整保存，原内容未修改。"
        }
    }
}

/// Pure byte preparation. Call on a worker task; no AppKit, files, store or cache side effects.
enum ImageRotationPlan {
    struct Limits {
        var maximumPixels = 64 * 1_024 * 1_024
        var maximumOutputBytes = 512 * 1_024 * 1_024
        var maximumFrames = 1_000
    }

    nonisolated static func rotatedRecord(_ record: ClipboardRecord) throws -> ClipboardRecord {
        try rotatedRecord(record, limits: Limits())
    }

    nonisolated static func rotatedRecord(_ record: ClipboardRecord, limits: Limits) throws -> ClipboardRecord {
        try Task.checkCancellation()
        // This is exactly the first image representation used by OCRDerivedCache / the preview.
        guard let partIndex = record.parts.firstIndex(where: { part in
            part.representations.contains { UTType($0.typeIdentifier)?.conforms(to: .image) == true }
        }), let representation = record.parts[partIndex].representations.first(where: {
            UTType($0.typeIdentifier)?.conforms(to: .image) == true
        }) else { throw ImageRotationError.noImage }
        guard !record.parts[partIndex].representations.contains(where: { ClipboardFileAccess.isFileURLType($0.typeIdentifier) }) else {
            throw ImageRotationError.noImage // A file thumbnail is not an editable embedded image.
        }
        guard representation.data.count <= limits.maximumOutputBytes else { throw ImageRotationError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(representation.data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let sourceType = CGImageSourceGetType(source) as String? else { throw ImageRotationError.invalidImage }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ImageRotationError.invalidImage }
        guard count <= limits.maximumFrames else { throw ImageRotationError.imageTooLarge }
        let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let isAPNG = sourceType == UTType.png.identifier &&
            (global[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGLoopCount] != nil
        let outputType: String
        if sourceType == UTType.gif.identifier { outputType = sourceType } // Even one frame can carry loop/delay semantics.
        else if count == 1 { outputType = UTType.png.identifier }
        else if [UTType.gif.identifier, UTType.png.identifier, UTType.tiff.identifier].contains(sourceType) { outputType = sourceType }
        else { throw ImageRotationError.unsupportedAnimation }

        var properties: [[CFString: Any]] = []
        var pixels = 0
        for index in 0..<count {
            try Task.checkCancellation()
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = dimension(frame[kCGImagePropertyPixelWidth]),
                  let height = dimension(frame[kCGImagePropertyPixelHeight]) else { throw ImageRotationError.invalidImage }
            let product = width.multipliedReportingOverflow(by: height)
            guard !product.overflow, product.partialValue <= limits.maximumPixels - pixels else { throw ImageRotationError.imageTooLarge }
            pixels += product.partialValue
            properties.append(frame)
        }
        // Bound raw working/output estimates before decoding any frame. The consumer also
        // enforces the actual encoded limit, including metadata and codec overhead.
        let workingBytes = pixels.multipliedReportingOverflow(by: 4)
        guard !workingBytes.overflow, workingBytes.partialValue <= limits.maximumOutputBytes else { throw ImageRotationError.imageTooLarge }
        let retainedBytes = try retainedByteCount(record, excluding: partIndex, maximum: limits.maximumOutputBytes)
        let output = BoundedRotationData(maximum: limits.maximumOutputBytes - retainedBytes)
        var callbacks = CGDataConsumerCallbacks(putBytes: { context, bytes, count in
            guard let context else { return 0 }
            return Unmanaged<BoundedRotationData>.fromOpaque(context).takeUnretainedValue().append(bytes, count: count)
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(output).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, outputType as CFString, count, nil) else {
            throw count > 1 ? ImageRotationError.unsupportedAnimation : ImageRotationError.encodingFailed
        }
        let animationKey = outputType == UTType.gif.identifier ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let loopKey = outputType == UTType.gif.identifier ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        if outputType != UTType.tiff.identifier,
           let loop = (global[animationKey] as? [CFString: Any])?[loopKey] {
            CGImageDestinationSetProperties(destination, [animationKey: [loopKey: loop]] as CFDictionary)
        }
        var firstSize: (width: Int, height: Int)?
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let frame = properties[index]
                let width = dimension(frame[kCGImagePropertyPixelWidth])!, height = dimension(frame[kCGImagePropertyPixelHeight])!
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                    kCGImageSourceShouldCacheImmediately: true]
                guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
                      oriented.width * oriented.height == width * height else { throw ImageRotationError.invalidImage }
                if index == 0 { firstSize = (oriented.width, oriented.height) }
                let rotated = try rotateLeft(oriented)
                try Task.checkCancellation()
                CGImageDestinationAddImage(destination, rotated, outputProperties(frame, width: rotated.width, height: rotated.height) as CFDictionary)
                if output.exceeded { throw ImageRotationError.imageTooLarge }
            }
        }
        let finalized = CGImageDestinationFinalize(destination)
        try Task.checkCancellation()
        guard !output.exceeded else { throw ImageRotationError.imageTooLarge }
        guard finalized, !output.data.isEmpty else { throw ImageRotationError.encodingFailed }
        var encoded = output.data
        if isAPNG || (count > 1 && outputType == UTType.png.identifier) {
            // ImageIO quantizes APNG delay doubles to milliseconds. Preserve the original
            // fcTL rational values exactly, including sub-millisecond and zero delays.
            try preserveAPNGTiming(original: representation.data, rotated: &encoded, count: count)
        }
        try verifyContainer(encoded, count: count, type: outputType, properties: properties, global: global)
        try Task.checkCancellation()
        var edited = record
        edited.parts[partIndex] = ClipboardPart(representations: [ClipboardRepresentation(typeIdentifier: outputType, data: encoded)])
        edited.ocrText = nil // OCR belongs to the first previewed image; other original parts stay byte-for-byte intact.
        if let size = firstSize, isAutomaticSummary(record, width: size.width, height: size.height) {
            edited.text = "图片 \(size.height) × \(size.width)"
        }
        return edited
    }

    private nonisolated static func rotateLeft(_ image: CGImage) throws -> CGImage {
        let colorSpace = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageRotationError.invalidImage
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ImageRotationError.invalidImage }
        return result
    }

    private nonisolated static func outputProperties(_ original: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var result = original
        result[kCGImagePropertyOrientation] = 1
        result[kCGImagePropertyPixelWidth] = width; result[kCGImagePropertyPixelHeight] = height
        let oldX = result[kCGImagePropertyDPIWidth], oldY = result[kCGImagePropertyDPIHeight]
        result[kCGImagePropertyDPIWidth] = oldY; result[kCGImagePropertyDPIHeight] = oldX
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            let x = tiff[kCGImagePropertyTIFFXResolution], y = tiff[kCGImagePropertyTIFFYResolution]
            tiff[kCGImagePropertyTIFFXResolution] = y; tiff[kCGImagePropertyTIFFYResolution] = x
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width; exif[kCGImagePropertyExifPixelYDimension] = height
            result[kCGImagePropertyExifDictionary] = exif
        }
        if var gif = result[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? NSNumber {
                // GIF stores integer centiseconds; avoid a float round-trip truncating a tick.
                let exactTicks = (delay.doubleValue * 100).rounded() / 100 + 0.000_000_01
                gif[kCGImagePropertyGIFDelayTime] = exactTicks
                gif[kCGImagePropertyGIFUnclampedDelayTime] = exactTicks
            }
            gif[kCGImagePropertyGIFCanvasPixelWidth] = width; gif[kCGImagePropertyGIFCanvasPixelHeight] = height
            result[kCGImagePropertyGIFDictionary] = gif
        }
        return result
    }

    private nonisolated static func verifyContainer(_ data: Data, count: Int, type: String,
        properties: [[CFString: Any]], global: [CFString: Any]) throws {
        guard let result = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(result) == count,
              CGImageSourceGetStatus(result) == .statusComplete else { throw ImageRotationError.encodingFailed }
        let isAnimatedPNG = type == UTType.png.identifier && (count > 1 ||
            (global[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGLoopCount] != nil)
        guard type == UTType.gif.identifier || isAnimatedPNG else { return }
        let dictionary = type == UTType.gif.identifier ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let delay = type == UTType.gif.identifier ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
        let clamped = type == UTType.gif.identifier ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
        let loop = type == UTType.gif.identifier ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        let resultGlobal = CGImageSourceCopyProperties(result, nil) as? [CFString: Any] ?? [:]
        let beforeLoop = (global[dictionary] as? [CFString: Any])?[loop] as? NSNumber
        let afterLoop = (resultGlobal[dictionary] as? [CFString: Any])?[loop] as? NSNumber
        guard beforeLoop == afterLoop else { throw ImageRotationError.unsupportedAnimation }
        for index in 0..<count {
            try Task.checkCancellation()
            let before = properties[index][dictionary] as? [CFString: Any] ?? [:]
            let after = (CGImageSourceCopyPropertiesAtIndex(result, index, nil) as? [CFString: Any])?[dictionary] as? [CFString: Any] ?? [:]
            let old = (before[delay] as? NSNumber ?? before[clamped] as? NSNumber)?.doubleValue ?? 0
            let new = (after[delay] as? NSNumber ?? after[clamped] as? NSNumber)?.doubleValue ?? 0
            guard old.isFinite, new.isFinite, abs(old - new) < 0.000_01 else { throw ImageRotationError.unsupportedAnimation }
        }
    }

    private nonisolated static func preserveAPNGTiming(original: Data, rotated: inout Data, count: Int) throws {
        func controls(_ data: Data) throws -> [Int] {
            let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
            guard data.starts(with: signature) else { throw ImageRotationError.invalidImage }
            var cursor = data.startIndex + 8, offsets: [Int] = []
            while cursor < data.endIndex {
                try Task.checkCancellation()
                guard data.endIndex - cursor >= 12 else { throw ImageRotationError.invalidImage }
                let length = data[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
                guard length <= data.endIndex - cursor - 12 else { throw ImageRotationError.invalidImage }
                if data[(cursor + 4)..<(cursor + 8)].elementsEqual([102, 99, 84, 76]) {
                    guard length == 26 else { throw ImageRotationError.invalidImage }
                    offsets.append(cursor + 8)
                }
                cursor += length + 12
            }
            guard offsets.count == count else { throw ImageRotationError.unsupportedAnimation }
            return offsets
        }
        let before = try controls(original), after = try controls(rotated)
        for index in 0..<count {
            try Task.checkCancellation()
            let source = before[index] + 20, target = after[index] + 20
            rotated.replaceSubrange(target..<(target + 4), with: original[source..<(source + 4)])
            var crc: UInt32 = 0xffff_ffff
            for byte in rotated[(after[index] - 4)..<(after[index] + 26)] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb8_8320 }
            }
            crc ^= 0xffff_ffff
            let checksum = (0..<4).map { UInt8(truncatingIfNeeded: crc >> (24 - $0 * 8)) }
            rotated.replaceSubrange((after[index] + 26)..<(after[index] + 30), with: checksum)
        }
    }

    private nonisolated static func dimension(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0,
              number.doubleValue <= Double(Int32.max), number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }

    private nonisolated static func retainedByteCount(_ record: ClipboardRecord, excluding part: Int, maximum: Int) throws -> Int {
        var total = 0
        var sizes = [record.text.utf8.count, record.rtf?.count ?? 0, record.html?.count ?? 0]
        for (index, value) in record.parts.enumerated() where index != part { sizes += value.representations.map { $0.data.count } }
        for size in sizes {
            guard size <= maximum - total else { throw ImageRotationError.imageTooLarge }
            total += size
        }
        return total
    }

    private nonisolated static func isAutomaticSummary(_ record: ClipboardRecord, width: Int, height: Int) -> Bool {
        record.text == "图片 \(width) × \(height)" && record.rtf == nil && record.html == nil &&
        !record.parts.flatMap(\.representations).contains { UTType($0.typeIdentifier)?.conforms(to: .text) == true }
    }
}

private final class BoundedRotationData {
    let maximum: Int
    var data = Data()
    var exceeded = false
    init(maximum: Int) { self.maximum = maximum }
    func append(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        guard !Task.isCancelled else { return 0 }
        guard count <= maximum - data.count else { exceeded = true; return 0 }
        data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        return count
    }
}
