import ApplicationServices
import XCTest
@testable import ClipShelf

@MainActor
final class PasteSelectionRangeTests: XCTestCase {
    func testCapturesInsertionPointAndSelectedTextWithoutContent() throws {
        for original in [CFRange(location: 7, length: 0), CFRange(location: 4, length: 6)] {
            var original = original
            let value = try XCTUnwrap(AXValueCreate(.cfRange, &original))
            let decoded = try XCTUnwrap(PasteSystemEnvironment.decodeSelectedRange(value))
            XCTAssertEqual(decoded.location, original.location)
            XCTAssertEqual(decoded.length, original.length)
        }
    }

    func testRejectsUnrelatedAccessibilityValuesAndInvalidRanges() throws {
        XCTAssertNil(PasteSystemEnvironment.decodeSelectedRange(nil))
        XCTAssertNil(PasteSystemEnvironment.decodeSelectedRange("range" as CFString))
        var point = CGPoint(x: 4, y: 6)
        XCTAssertNil(PasteSystemEnvironment.decodeSelectedRange(try XCTUnwrap(AXValueCreate(.cgPoint, &point))))
        for original in [CFRange(location: -1, length: 0), CFRange(location: 0, length: -1), CFRange(location: Int.max, length: 1)] {
            var original = original
            let value = try XCTUnwrap(AXValueCreate(.cfRange, &original))
            XCTAssertNil(PasteSystemEnvironment.decodeSelectedRange(value))
        }
    }
}
