import Foundation
import XCTest
@testable import ClipShelf

final class ValidationTraceTests: XCTestCase {
    func testGateRequiresBothExactValidationFlags() {
        let disabled: [[String]] = [
            [], ["--validation"], ["--validation-trace"],
            ["--validation", "--validation"],
            ["--validation-trace", "--validation-trace"],
            ["--validation=true", "--validation-trace"],
            ["--validation", "--validation-trace=true"],
            ["--validation", "--validation-trace-extra"],
            ["--Validation", "--validation-trace"],
        ]
        for arguments in disabled {
            XCTAssertFalse(ValidationTrace.isEnabled(arguments: arguments), "\(arguments)")
        }
        for arguments in [
            ["--validation", "--validation-trace"],
            ["--validation-trace", "--validation"],
            ["ClipShelf", "--demo", "--validation", "--validation-trace", "--validation"],
        ] {
            XCTAssertTrue(ValidationTrace.isEnabled(arguments: arguments), "\(arguments)")
        }
    }

    func testEncodedLineHasOnlyWhitelistedFieldsAndOmitsNilValues() throws {
        func decodeLine(_ data: Data) throws -> [String: Any] {
            XCTAssertEqual(data.last, UInt8(0x0A))
            XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertFalse(object.values.contains { $0 is NSNull })
            return object
        }

        let full = try decodeLine(XCTUnwrap(ValidationTrace.encodedLine(
            event: .focusChecked, timestamp: 1234.5, pid: 321, bundleID: "test.validation",
            hasTargetWindow: true, hasInputElement: false, state: .ready, failure: .changedForeground)))
        XCTAssertEqual(Set(full.keys), Set([
            "timestamp", "event", "pid", "bundleID", "hasTargetWindow", "hasInputElement", "state", "failure",
        ]))
        XCTAssertEqual((full["timestamp"] as? NSNumber)?.doubleValue, 1234.5)
        XCTAssertEqual(full["pid"] as? Int, 321)
        XCTAssertEqual(full["bundleID"] as? String, "test.validation")
        XCTAssertEqual(full["hasTargetWindow"] as? Bool, true)
        XCTAssertEqual(full["hasInputElement"] as? Bool, false)
        for key in ["event", "state", "failure"] {
            XCTAssertFalse(try XCTUnwrap(full[key] as? String).isEmpty)
        }

        let minimal = try decodeLine(XCTUnwrap(ValidationTrace.encodedLine(event: .targetCaptured, timestamp: 42)))
        XCTAssertEqual(Set(minimal.keys), Set(["timestamp", "event"]))
        XCTAssertEqual((minimal["timestamp"] as? NSNumber)?.doubleValue, 42)
        XCTAssertFalse(try XCTUnwrap(minimal["event"] as? String).isEmpty)
    }

    func testEncodedLineRejectsNaNTimestamp() {
        XCTAssertNil(ValidationTrace.encodedLine(event: .pasteCompleted, timestamp: .nan))
    }

    func testPasteMethodUsesOnlyTheDispatchSchema() throws {
        let data = try XCTUnwrap(ValidationTrace.encodedLine(event: .pasteDispatch,
            timestamp: 42, state: .dispatched, method: .menu))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["timestamp", "event", "state", "method"])
        XCTAssertEqual(object["method"] as? String, "menu")
    }

    func testDiagnosticFlagEnablesTraceWithoutValidationMode() {
        XCTAssertTrue(ValidationTrace.isEnabled(arguments: ["ClipShelf", "--diagnostic-trace"]))
        XCTAssertFalse(ValidationTrace.isEnabled(arguments: ["--diagnostic-trace=true"]))
        let profile = RuntimeProfile(arguments: ["ClipShelf", "--diagnostic-trace"])
        XCTAssertEqual(profile.mode, .standard)
        XCTAssertNil(profile.validationDirectory)
        XCTAssertNil(profile.validationPreferenceDomain)
    }

    func testHotkeyRegistrationIncludesOnlyNumericSystemStatus() throws {
        let data = try XCTUnwrap(ValidationTrace.encodedLine(event: .hotkeyRegistered,
            timestamp: 42, state: .unavailable, status: -9878, shortcut: .activation))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["timestamp", "event", "state", "status", "shortcut"])
        XCTAssertEqual(object["status"] as? Int, -9878)
        XCTAssertEqual(object["shortcut"] as? String, "activation")
    }
}
