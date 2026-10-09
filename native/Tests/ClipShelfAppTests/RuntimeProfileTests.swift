import Foundation
import XCTest
@testable import ClipShelf

final class RuntimeProfileTests: XCTestCase {
    func testValidationHasFreshDirectoriesAndCannotResumeBackgroundServices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = RuntimeProfile(arguments: ["ClipShelf", "--validation"], temporaryDirectory: root)
        let second = RuntimeProfile(arguments: ["ClipShelf", "--validation"], temporaryDirectory: root)
        defer { first.discardValidationPreferences(); second.discardValidationPreferences() }
        XCTAssertEqual(first.mode, .validation)
        XCTAssertFalse(first.allowsBackgroundIntegrations)
        XCTAssertNotEqual(try first.dataDirectory(), try second.dataDirectory())
        XCTAssertEqual(try first.dataDirectory().deletingLastPathComponent().path, root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        first.preferences.set(true, forKey: "recordingEnabled")
        first.preferences.set(true, forKey: "syncEnabled")
        XCTAssertFalse(second.preferences.bool(forKey: "recordingEnabled"))
        XCTAssertFalse(second.preferences.bool(forKey: "syncEnabled"))
        XCTAssertTrue(second.preferences.bool(forKey: "hasSeenWelcome"))
    }

    func testDemoAndStandardHaveDifferentIntegrationPolicies() {
        XCTAssertFalse(RuntimeProfile(arguments: ["ClipShelf", "--demo"]).allowsBackgroundIntegrations)
        XCTAssertTrue(RuntimeProfile(arguments: ["ClipShelf"]).allowsBackgroundIntegrations)
        let profile = RuntimeProfile(arguments: ["ClipShelf", "--demo", "--validation"])
        defer { profile.discardValidationPreferences() }
        XCTAssertEqual(profile.mode, .validation)
    }
}
