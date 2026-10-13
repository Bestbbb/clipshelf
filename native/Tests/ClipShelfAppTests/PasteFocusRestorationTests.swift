import CoreFoundation
import XCTest
@testable import ClipShelf

final class PasteFocusRestorationTests: XCTestCase {
    func testUnchangedCaretAndSelectionDoNotRewriteAXAttributes() {
        for range in [CFRange(location: 15, length: 0), CFRange(location: 10, length: 5), CFRange(location: 0, length: 0)] {
            XCTAssertEqual(PasteFocusRestoration.plan(focusMatches: true, capturedRange: range, currentRange: range),
                           .init(restoreFocus: false, restoreSelection: false))
        }
    }

    func testChangedRangeRestoresOnlySelection() {
        let captured = CFRange(location: 15, length: 0)
        for current in [CFRange(location: 14, length: 0), CFRange(location: 15, length: 1), nil] {
            XCTAssertEqual(PasteFocusRestoration.plan(focusMatches: true, capturedRange: captured, currentRange: current),
                           .init(restoreFocus: false, restoreSelection: true))
        }
    }

    func testChangedElementRestoresFocusAndCapturedSelection() {
        let range = CFRange(location: 15, length: 0)
        XCTAssertEqual(PasteFocusRestoration.plan(focusMatches: false, capturedRange: range, currentRange: range),
                       .init(restoreFocus: true, restoreSelection: true))
    }

    func testMissingCapturedSelectionNeverInventsACaret() {
        for matches in [false, true] {
            XCTAssertEqual(PasteFocusRestoration.plan(focusMatches: matches, capturedRange: nil,
                                                     currentRange: CFRange(location: 0, length: 0)),
                           .init(restoreFocus: !matches, restoreSelection: false))
        }
    }
}
