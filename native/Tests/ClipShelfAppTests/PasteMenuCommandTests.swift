import ApplicationServices
import XCTest
@testable import ClipShelf

final class PasteMenuCommandTests: XCTestCase {
    func testStandardCommandVIsIndependentOfLanguageAndCharacterCase() {
        for character in ["v", "V"] {
            XCTAssertTrue(PasteMenuCommand.matches(role: kAXMenuItemRole, character: character,
                modifiers: 0, enabled: true, supportsPress: true))
        }
    }

    func testShiftOptionControlAndNoCommandCannotSelectThePlainPasteCommand() {
        for modifiers in 1...15 {
            XCTAssertFalse(PasteMenuCommand.matches(role: kAXMenuItemRole, character: "v",
                modifiers: modifiers, enabled: true, supportsPress: true))
        }
        XCTAssertFalse(PasteMenuCommand.matches(role: kAXMenuItemRole, character: "v",
            modifiers: nil, enabled: true, supportsPress: true))
    }

    func testDisabledUnsupportedAndUnrelatedItemsCannotExecute() {
        XCTAssertFalse(PasteMenuCommand.matches(role: kAXMenuItemRole, character: "v",
            modifiers: 0, enabled: false, supportsPress: true))
        XCTAssertFalse(PasteMenuCommand.matches(role: kAXMenuItemRole, character: "v",
            modifiers: 0, enabled: true, supportsPress: false))
        XCTAssertFalse(PasteMenuCommand.matches(role: kAXMenuItemRole, character: "c",
            modifiers: 0, enabled: true, supportsPress: true))
        XCTAssertFalse(PasteMenuCommand.matches(role: kAXButtonRole, character: "v",
            modifiers: 0, enabled: true, supportsPress: true))
    }
}
