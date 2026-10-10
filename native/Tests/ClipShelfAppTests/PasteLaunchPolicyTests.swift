import ApplicationServices
import XCTest
@testable import ClipShelf

final class PasteLaunchPolicyTests: XCTestCase {
    func testOpeningFromFinderNavigationRequiresAnExplicitDestination() {
        for role in [nil, kAXOutlineRole, kAXTableRole, kAXButtonRole] {
            XCTAssertTrue(PasteLaunchPolicy.requiresDestinationChoice(bundleID: "com.apple.finder", focusedRole: role))
        }
    }

    func testFinderEditableInputsAndOtherApplicationsRemainValidTargets() {
        for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] {
            XCTAssertFalse(PasteLaunchPolicy.requiresDestinationChoice(bundleID: "com.apple.finder", focusedRole: role))
        }
        for bundle in [nil, "com.apple.TextEdit", "com.google.Chrome", "com.microsoft.VSCode"] {
            XCTAssertFalse(PasteLaunchPolicy.requiresDestinationChoice(bundleID: bundle, focusedRole: nil))
        }
    }
}
