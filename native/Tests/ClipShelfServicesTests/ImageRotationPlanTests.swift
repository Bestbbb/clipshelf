import ClipShelfCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClipShelf

final class ImageRotationPlanTests: XCTestCase {
    private let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255],
                                    [255, 255, 0, 255], [255, 0, 255, 255], [0, 255, 255, 255]]

    private func image(width: Int = 3, height: Int = 2, pixels: [[UInt8]]? = nil) throws -> CGImage {
        let bytes = Data((pixels ?? colors).flatMap { $0 })
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: XCTUnwrap(CGDataProvider(data: bytes as CFData)), decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func encode(_ images: [CGImage], type: String = UTType.png.identifier,
                        properties: [[CFString: Any]] = [], global: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, images.count, nil))
        CGImageDestinationSetProperties(destination, global as CFDictionary)
        for (index, image) in images.enumerated() {
            CGImageDestinationAddImage(destination, image, (index < properties.count ? properties[index] : [:]) as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func record(_ data: Data, type: String = UTType.png.identifier, text: String = "用户的说明") -> ClipboardRecord {
        ClipboardRecord(text: text, parts: [.init(representations: [.init(typeIdentifier: type, data: data)])])
    }

    private func source(_ data: Data) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    }

    private func bytes(_ image: CGImage) throws -> [[UInt8]] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { Array(UnsafeBufferPointer(start: data + $0 * 4, count: 4)) }
    }

    private func decoded(_ data: Data, index: Int = 0) throws -> CGImage {
        try XCTUnwrap(CGImageSourceCreateImageAtIndex(source(data), index, nil))
    }

    private func rotatedBytes(_ input: [[UInt8]], width: Int, height: Int) -> [[UInt8]] {
        (0..<width).flatMap { row in (0..<height).map { col in input[col * width + width - 1 - row] } }
    }

    func testNonSquarePixelsRotateLeftAndFourTurnsRestoreOriginal() throws {
        let original = try encode([image()])
        var current = record(original, text: "图片 3 × 2")
        current = try ImageRotationPlan.rotatedRecord(current)
        let rotated = try decoded(current.parts[0].representations[0].data)
        XCTAssertEqual(rotated.width, 2); XCTAssertEqual(rotated.height, 3)
        XCTAssertEqual(try bytes(rotated), [colors[2], colors[5], colors[1], colors[4], colors[0], colors[3]])
        XCTAssertEqual(current.text, "图片 2 × 3")
        for _ in 0..<3 { current = try ImageRotationPlan.rotatedRecord(current) }
        XCTAssertEqual(try bytes(decoded(current.parts[0].representations[0].data)), colors)
    }

    func testAllExifOrientationsAreAppliedBeforeLeftRotationAndResetInOutput() throws {
        let expected: [[Int]] = [[2, 5, 1, 4, 0, 3], [0, 3, 1, 4, 2, 5],
            [3, 0, 4, 1, 5, 2], [5, 2, 4, 1, 3, 0], [3, 4, 5, 0, 1, 2],
            [0, 1, 2, 3, 4, 5], [2, 1, 0, 5, 4, 3], [5, 4, 3, 2, 1, 0]]
        for orientation in 1...8 {
            let input = try encode([image()], type: UTType.tiff.identifier,
                properties: [[kCGImagePropertyOrientation: orientation,
                              kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: orientation]]])
            let value = try ImageRotationPlan.rotatedRecord(record(input, type: UTType.tiff.identifier))
            let output = value.parts[0].representations[0].data
            let decodedImage = try decoded(output)
            XCTAssertEqual(try bytes(decodedImage), expected[orientation - 1].map { colors[$0] }, "orientation \(orientation)")
            XCTAssertEqual(decodedImage.width, orientation > 4 ? 3 : 2)
            XCTAssertEqual(decodedImage.height, orientation > 4 ? 2 : 3)
            let props = CGImageSourceCopyPropertiesAtIndex(try source(output), 0, nil) as? [CFString: Any]
            XCTAssertEqual((props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        }
    }

    func testAlphaAndOtherPartsMetadataAndUserTextSurvive() throws {
        var transparent = colors; transparent[1] = [0, 200, 0, 128]; transparent[4] = [80, 30, 10, 0]
        let data = try encode([image(pixels: transparent)])
        let before = ClipboardPart(representations: [.init(typeIdentifier: "public.utf8-plain-text", data: Data("prefix".utf8))])
        let after = ClipboardPart(representations: [.init(typeIdentifier: "public.png", data: try encode([image(width: 2, height: 3)]))])
        var original = record(data)
        original.parts = [before, .init(representations: original.parts[0].representations + [
            .init(typeIdentifier: "public.tiff", data: Data("stale alternative".utf8)),
            .init(typeIdentifier: "public.html", data: Data("stale embedded preview".utf8))]), after]
        original.sourceApp = "Fixture"; original.sourceBundleID = "example.fixture"
        original.copiedAt = Date(timeIntervalSinceReferenceDate: 15); original.renamedTitle = "用户标题"
        original.revision = 9; original.pinboardID = UUID(); original.pinboardOrder = 20
        original.originDeviceID = UUID(); original.originDeviceName = "Mac"; original.isInHistory = false
        original.rtf = Data("user rtf".utf8); original.html = Data("user html".utf8); original.ocrText = "old derived OCR"
        let result = try ImageRotationPlan.rotatedRecord(original)
        var expected = original; expected.parts[1] = result.parts[1]; expected.ocrText = nil
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.parts[1].representations.count, 1)
        XCTAssertEqual(try bytes(decoded(result.parts[1].representations[0].data)),
                       rotatedBytes(try bytes(decoded(data)), width: 3, height: 2))
    }

    func testGIFAndAPNGKeepEveryFrameTimingLoopAndPixels() throws {
        for type in [UTType.gif.identifier, UTType.png.identifier] {
            let key = type == UTType.gif.identifier ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
            let delay = type == UTType.gif.identifier ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
            let unclamped = type == UTType.gif.identifier ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
            let loop = type == UTType.gif.identifier ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
            let timings = [0.07, 0.13, 0.21]
            var partial = colors; partial[1] = [0, 0, 0, 0]; partial[5] = [0, 0, 0, 0]
            let input = try encode([image(), image(pixels: Array(colors.reversed())), image(pixels: partial)], type: type,
                properties: timings.map { [key: [delay: $0, unclamped: $0]] }, global: [key: [loop: 4]])
            let originalSource = try source(input)
            XCTAssertEqual(CGImageSourceGetCount(originalSource), 3)
            let result = try ImageRotationPlan.rotatedRecord(record(input, type: type))
            XCTAssertEqual(result.parts[0].representations[0].typeIdentifier, type)
            let output = result.parts[0].representations[0].data, outputSource = try source(output)
            XCTAssertEqual(CGImageSourceGetCount(outputSource), 3)
            let global = CGImageSourceCopyProperties(outputSource, nil) as? [CFString: Any]
            XCTAssertEqual(((global?[key] as? [CFString: Any])?[loop] as? NSNumber)?.intValue, 4)
            for index in 0..<3 {
                let properties = CGImageSourceCopyPropertiesAtIndex(outputSource, index, nil) as? [CFString: Any]
                XCTAssertEqual(((properties?[key] as? [CFString: Any])?[unclamped] as? NSNumber)?.doubleValue ?? -1, timings[index], accuracy: 0.00001)
                let old = try decoded(input, index: index), new = try decoded(output, index: index)
                XCTAssertEqual(new.width, old.height); XCTAssertEqual(new.height, old.width)
                XCTAssertEqual(try bytes(new), rotatedBytes(try bytes(old), width: old.width, height: old.height), "\(type), frame \(index)")
            }
        }
    }

    func testMultipageTIFFKeepsAllPageSizesAndPerPageOrientations() throws {
        let input = try encode([image(), image(width: 2, height: 3)], type: UTType.tiff.identifier,
            properties: [[kCGImagePropertyOrientation: 6], [kCGImagePropertyOrientation: 1]])
        let result = try ImageRotationPlan.rotatedRecord(record(input, type: UTType.tiff.identifier))
        let output = result.parts[0].representations[0].data
        XCTAssertEqual(result.parts[0].representations[0].typeIdentifier, UTType.tiff.identifier)
        XCTAssertEqual(CGImageSourceGetCount(try source(output)), 2)
        XCTAssertEqual(try bytes(decoded(output)), colors)
        XCTAssertEqual(try bytes(decoded(output, index: 1)), rotatedBytes(colors, width: 2, height: 3))
    }

    func testMalformedFirstRepresentationDoesNotSilentlyRotateAnotherImageOrLoseFrames() throws {
        var value = record(Data("bad image".utf8))
        value.parts[0].representations.append(.init(typeIdentifier: UTType.png.identifier, data: try encode([image()])))
        XCTAssertThrowsError(try ImageRotationPlan.rotatedRecord(value)) { XCTAssertEqual($0 as? ImageRotationError, .invalidImage) }
        let animation = try encode([image(), image()], type: UTType.gif.identifier)
        XCTAssertThrowsError(try ImageRotationPlan.rotatedRecord(record(Data(animation.prefix(animation.count / 2)), type: UTType.gif.identifier)))
        XCTAssertThrowsError(try ImageRotationPlan.rotatedRecord(ClipboardRecord(text: "plain"))) { XCTAssertEqual($0 as? ImageRotationError, .noImage) }
    }

    func testAggregatePixelFrameAndEncodedOutputBudgetsRejectAtomically() throws {
        let input = try encode([image(), image()], type: UTType.tiff.identifier)
        let value = record(input, type: UTType.tiff.identifier)
        XCTAssertThrowsError(try ImageRotationPlan.rotatedRecord(value, limits: .init(maximumPixels: 11))) { XCTAssertEqual($0 as? ImageRotationError, .imageTooLarge) }
        XCTAssertThrowsError(try ImageRotationPlan.rotatedRecord(value, limits: .init(maximumFrames: 1))) { XCTAssertEqual($0 as? ImageRotationError, .imageTooLarge) }
        // Large retained text leaves room for the input and raw pixels, but not the encoded result.
        let png = try encode([image()])
        let tight = record(png, text: String(repeating: "x", count: png.count))
        XCTAssertThrowsError(try ImageRotationPlan.rotatedRecord(tight, limits: .init(maximumOutputBytes: png.count + 30))) { XCTAssertEqual($0 as? ImageRotationError, .imageTooLarge) }
        XCTAssertEqual(value.parts[0].representations[0].data, input)
    }

    func testCancellationFromWorkerNeverReturnsEditedRecord() async throws {
        let value = record(try encode([image()]))
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ImageRotationPlan.rotatedRecord(value)
        }
        do { _ = try await task.value; XCTFail("Cancelled rotation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTextRepresentationPreventsTreatingMatchingUserCaptionAsAutomaticSummary() throws {
        var value = record(try encode([image()]), text: "图片 3 × 2")
        value.parts[0].representations.append(.init(typeIdentifier: "public.utf8-plain-text", data: Data(value.text.utf8)))
        XCTAssertEqual(try ImageRotationPlan.rotatedRecord(value).text, value.text)
    }

    func testAPNGKeepsExactRationalTimingIncludingSubMillisecondAndZeroDelay() throws {
        let key = kCGImagePropertyPNGDictionary
        var input = try encode([image(), image(pixels: Array(colors.reversed())), image()],
            properties: Array(repeating: [key: [kCGImagePropertyAPNGDelayTime: 0.2]], count: 3),
            global: [key: [kCGImagePropertyAPNGLoopCount: 0]])
        func controls(_ data: Data) -> [Int] {
            var cursor = 8, result: [Int] = []
            while cursor + 12 <= data.count {
                let length = data[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
                if data[(cursor + 4)..<(cursor + 8)].elementsEqual([102, 99, 84, 76]) { result.append(cursor + 8) }
                cursor += length + 12
            }
            return result
        }
        let timings: [[UInt8]] = [[0, 1, 0, 60], [0, 1, 255, 255], [0, 0, 0, 0]]
        let offsets = controls(input)
        XCTAssertEqual(offsets.count, timings.count)
        for (index, offset) in offsets.enumerated() {
            input.replaceSubrange((offset + 20)..<(offset + 24), with: timings[index])
            var crc: UInt32 = 0xffff_ffff
            for byte in input[(offset - 4)..<(offset + 26)] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb8_8320 }
            }
            crc ^= 0xffff_ffff
            input.replaceSubrange((offset + 26)..<(offset + 30), with: (0..<4).map { UInt8(truncatingIfNeeded: crc >> (24 - 8 * $0)) })
        }
        // Foundation Data slices can retain a nonzero startIndex.
        var prefixed = Data([90, 91, 92]); prefixed.append(input)
        var current = record(prefixed.dropFirst(3))
        for _ in 0..<4 { current = try ImageRotationPlan.rotatedRecord(current) }
        let data = current.parts[0].representations[0].data
        XCTAssertEqual(CGImageSourceGetCount(try source(data)), 3)
        XCTAssertEqual(controls(data).map { Array(data[($0 + 20)..<($0 + 24)]) }, timings,
                       "Repeated rotations must never accumulate frame-time quantization")
        XCTAssertEqual(try bytes(decoded(data)), colors)
    }

    func testUnsupportedMultiImageICOIsExplicitlyRejectedInsteadOfKeepingFirstImage() throws {
        let frames = try [16, 32].map { dimension in
            try encode([image(width: dimension, height: dimension,
                pixels: (0..<(dimension * dimension)).map { colors[$0 % colors.count] })])
        }
        var data = Data([0, 0, 1, 0, 2, 0]), offset = 6 + 2 * 16
        func little(_ value: Int, count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        for (index, frame) in frames.enumerated() {
            let dimension: UInt8 = index == 0 ? 16 : 32
            data.append(contentsOf: [dimension, dimension, 0, 0, 1, 0, 32, 0])
            data.append(contentsOf: little(frame.count, count: 4) + little(offset, count: 4))
            offset += frame.count
        }
        frames.forEach { data.append($0) }
        XCTAssertEqual(CGImageSourceGetCount(try source(data)), 2)
        XCTAssertThrowsError(try ImageRotationPlan.rotatedRecord(record(data, type: UTType.ico.identifier))) {
            XCTAssertEqual($0 as? ImageRotationError, .unsupportedAnimation)
        }
    }

    func testSingleFrameGIFRetainsItsLoopAndDelayMetadata() throws {
        let input = try encode([image()], type: UTType.gif.identifier,
            properties: [[kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.13]]],
            global: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 7]])
        let value = try ImageRotationPlan.rotatedRecord(record(input, type: UTType.gif.identifier))
        XCTAssertEqual(value.parts[0].representations[0].typeIdentifier, UTType.gif.identifier)
        let output = try source(value.parts[0].representations[0].data)
        XCTAssertEqual(CGImageSourceGetCount(output), 1)
        let globals = CGImageSourceCopyProperties(output, nil) as? [CFString: Any]
        XCTAssertEqual(((globals?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 7)
        let props = CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any]
        XCTAssertEqual(((props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? -1, 0.13, accuracy: 0.00001)
    }

    func testFileThumbnailIsNotTreatedAsEditableImageBytes() throws {
        var value = record(try encode([image()]))
        value.parts[0].representations.append(.init(typeIdentifier: UTType.fileURL.identifier,
                                                   data: Data("file:///nonexistent/photo.png".utf8)))
        XCTAssertThrowsError(try ImageRotationPlan.rotatedRecord(value)) { XCTAssertEqual($0 as? ImageRotationError, .noImage) }
    }

    func testOptimizedGIFFrameOffsetsAndRestorePreviousDisposalStayVisuallyCorrect() throws {
        // Hand-encoded fixture: full canvas, one offset pixel (restore previous),
        // then a transparent two-pixel patch. Clear codes keep the tiny LZW stream fixed-width.
        var input = Data("GIF89a".utf8)
        input.append(contentsOf: [3, 0, 2, 0, 0xf2, 6, 0])
        (colors + [[0, 0, 0, 0], [0, 0, 0, 255]]).forEach { input.append(contentsOf: $0.prefix(3)) }
        input.append(contentsOf: [0x21, 0xff, 11]); input.append(Data("NETSCAPE2.0".utf8))
        input.append(contentsOf: [3, 1, 0, 0, 0])
        func frame(x: UInt8, y: UInt8, width: UInt8, height: UInt8, disposal: UInt8, indices: [UInt8]) {
            input.append(contentsOf: [0x21, 0xf9, 4, disposal << 2 | 1, 9, 0, 6, 0,
                                      0x2c, x, 0, y, 0, width, 0, height, 0, 0, 3])
            let codes: [UInt8] = indices.flatMap { [UInt8(8), $0] } + [UInt8(9)]
            var packed: [UInt8] = []
            for index in stride(from: 0, to: codes.count, by: 2) {
                packed.append(codes[index] | ((index + 1 < codes.count ? codes[index + 1] : 0) << 4))
            }
            input.append(UInt8(packed.count)); input.append(contentsOf: packed); input.append(0)
        }
        frame(x: 0, y: 0, width: 3, height: 2, disposal: 1, indices: [0, 1, 2, 3, 4, 5])
        frame(x: 1, y: 0, width: 1, height: 1, disposal: 3, indices: [5])
        frame(x: 0, y: 1, width: 2, height: 1, disposal: 2, indices: [6, 0])
        input.append(0x3b)
        let expected = [colors, [colors[0], colors[5], colors[2], colors[3], colors[4], colors[5]],
                        [colors[0], colors[1], colors[2], colors[3], colors[0], colors[5]]]
        for index in 0..<3 { XCTAssertEqual(try bytes(decoded(input, index: index)), expected[index]) }
        let result = try ImageRotationPlan.rotatedRecord(record(input, type: UTType.gif.identifier))
        let output = result.parts[0].representations[0].data
        XCTAssertEqual(CGImageSourceGetCount(try source(output)), 3)
        for index in 0..<3 {
            XCTAssertEqual(try bytes(decoded(output, index: index)), rotatedBytes(expected[index], width: 3, height: 2), "frame \(index)")
        }
    }
}
