import ClipShelfCore
@testable import ClipShelf
import CoreGraphics
import CoreText
import ImageIO
import XCTest

@MainActor
final class LocalIntelligenceServiceTests: XCTestCase {
    func testEmptyAndUnrelatedContextDoNotReturnRecencyFallbacks() async throws {
        let service = LocalIntelligenceService()
        let records = [ClipboardRecord(text: "clipboard documentation")]
        let empty = try await service.suggestions(contextString: "  ", records: records)
        let unrelated = try await service.suggestions(contextString: "volcano", records: records)
        let stopWords = try await service.suggestions(contextString: "the and with", records: records)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(unrelated.isEmpty)
        XCTAssertTrue(stopWords.isEmpty)
    }

    func testBodyMatchOutranksSourceAndExplainsMatchedTerms() async throws {
        let service = LocalIntelligenceService()
        let sourceMatch = ClipboardRecord(text: "unrelated", sourceApp: "Safari")
        let bodyMatch = ClipboardRecord(text: "Safari documentation")
        let results = try await service.rankedSuggestions(contextString: "safari", records: [sourceMatch, bodyMatch])
        XCTAssertEqual(results.map(\.recordID), [bodyMatch.id, sourceMatch.id])
        XCTAssertEqual(results.first?.matchedTerms, ["safari"])
        XCTAssertGreaterThan(results[0].score, results[1].score)
    }

    func testChineseSubstringAndCaseWidthNormalization() async throws {
        let service = LocalIntelligenceService()
        let chinese = ClipboardRecord(text: "这是一条剪贴板历史记录")
        let english = ClipboardRecord(text: "ＳＡＦＡＲＩ café guide")
        let chineseResult = try await service.rankedSuggestions(contextString: "剪贴板", records: [english, chinese])
        XCTAssertEqual(chineseResult.map(\.recordID), [chinese.id])
        XCTAssertTrue(chineseResult[0].matchedTerms.contains("剪贴"))
        let normalized = try await service.suggestions(contextString: "safari cafe", records: [english, chinese])
        XCTAssertEqual(normalized, [english.id])
    }

    func testTiesUseRecencyThenInputOrderAndIDsAreUnique() async throws {
        let service = LocalIntelligenceService()
        let oldest = ClipboardRecord(text: "clipboard", copiedAt: Date(timeIntervalSince1970: 1))
        let newest = ClipboardRecord(text: "clipboard", copiedAt: Date(timeIntervalSince1970: 3))
        let middle = ClipboardRecord(text: "clipboard", copiedAt: Date(timeIntervalSince1970: 2))
        let sameDate = ClipboardRecord(text: "clipboard", copiedAt: middle.copiedAt)
        let records = [oldest, newest, middle, sameDate, newest]
        let results = try await service.suggestions(contextString: "clipboard", records: records, limit: 3)
        XCTAssertEqual(results, [newest.id, middle.id, sameDate.id])
        let zero = try await service.suggestions(contextString: "clipboard", records: records, limit: 0)
        XCTAssertTrue(zero.isEmpty)
    }

    func testCancelledSuggestionsDoNotPublishAResult() async {
        let service = LocalIntelligenceService()
        let task = Task { try await service.suggestions(contextString: "clipboard", records: [ClipboardRecord(text: "clipboard")]) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled caller must not receive current suggestions")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testInvalidImageProducesUsefulError() async {
        let service = LocalIntelligenceService()
        do {
            _ = try await service.recognizeText(in: Data("not an image".utf8))
            XCTFail("Invalid image data must fail")
        } catch {
            guard case LocalIntelligenceService.RecognitionError.invalidImage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testOCRRecognizesSyntheticImageWithNormalizedRegions() async throws {
        let service = LocalIntelligenceService()
        let result = try await service.recognizeText(in: try Self.syntheticImage(), recognitionLanguages: ["en-US"])
        XCTAssertTrue(result.text.uppercased().contains("CLIPSHELF"), result.text)
        XCTAssertTrue(result.text.contains("2026"), result.text)
        XCTAssertFalse(result.regions.isEmpty)
        XCTAssertEqual(result.recognitionLanguages, ["en-US"])
        for region in result.regions {
            XCTAssertGreaterThanOrEqual(region.boundingBox.minX, 0)
            XCTAssertGreaterThanOrEqual(region.boundingBox.minY, 0)
            XCTAssertLessThanOrEqual(region.boundingBox.maxX, 1)
            XCTAssertLessThanOrEqual(region.boundingBox.maxY, 1)
            XCTAssertGreaterThan(region.boundingBox.width, 0)
            XCTAssertGreaterThan(region.boundingBox.height, 0)
            XCTAssertGreaterThanOrEqual(region.confidence, 0)
            XCTAssertLessThanOrEqual(region.confidence, 1)
        }
    }

    func testCancelledOCRDoesNotReturnAResult() async throws {
        let service = LocalIntelligenceService()
        let data = try Self.syntheticImage()
        let task = Task { try await service.recognizeText(in: data) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled caller must not receive an OCR result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private static func syntheticImage() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1_000, height: 180,
                                             bitsPerComponent: 8, bytesPerRow: 4_000,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 180))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let text = NSAttributedString(string: "CLIPSHELF OCR 2026", attributes: attributes)
        context.textPosition = CGPoint(x: 35, y: 70)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
