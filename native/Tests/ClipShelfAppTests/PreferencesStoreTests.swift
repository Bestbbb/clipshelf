import Foundation
import XCTest
@testable import ClipShelf

final class PreferencesStoreTests: XCTestCase {
    func testRegisteredDefaultsNeverOverwriteExplicitChoicesAndRemovalRevealsDefault() {
        let preferences = InMemoryPreferences(values: ["recording": true, "unrelated": "keep"])
        preferences.register(defaults: ["recording": false, "retention": 30])
        XCTAssertTrue(preferences.bool(forKey: "recording"))
        XCTAssertEqual(preferences.integer(forKey: "retention"), 30)
        XCTAssertNil(preferences.snapshot["retention"])
        preferences.removeObject(forKey: "recording")
        XCTAssertFalse(preferences.bool(forKey: "recording"))
        XCTAssertEqual(preferences.string(forKey: "unrelated"), "keep")
    }

    func testIndependentStoresAndTypedValuesSupportShortcutSettingsRoundTrip() throws {
        let first = InMemoryPreferences(), second = InMemoryPreferences()
        try KeyboardShortcutConfiguration.defaults.save(to: first)
        XCTAssertEqual(KeyboardShortcutConfiguration.load(from: first), .defaults)
        XCTAssertNil(second.data(forKey: KeyboardShortcutConfiguration.storageKey))
        first.set(["a", "b"], forKey: "applications")
        first.set("YES", forKey: "enabled")
        first.set("42", forKey: "retention")
        first.set(1.25, forKey: "height")
        XCTAssertEqual(first.stringArray(forKey: "applications"), ["a", "b"])
        XCTAssertTrue(first.bool(forKey: "enabled"))
        XCTAssertEqual(first.integer(forKey: "retention"), 42)
        XCTAssertEqual(first.double(forKey: "height"), 1.25)
        XCTAssertFalse(second.bool(forKey: "enabled"))
    }

    func testInterruptedValidationCannotLeaveOrReuseAPreferenceDomain() {
        let first = RuntimeProfile(arguments: ["ClipShelf", "--validation"])
        XCTAssertTrue(first.preferences is InMemoryPreferences)
        XCTAssertNil(first.validationPreferenceDomain)
        first.preferences.set(true, forKey: "recordingEnabled")
        // No cleanup call is needed to isolate the next validation launch.
        let next = RuntimeProfile(arguments: ["ClipShelf", "--validation"])
        XCTAssertFalse(next.preferences.bool(forKey: "recordingEnabled"))
        XCTAssertTrue(next.preferences.bool(forKey: "hasSeenWelcome"))
    }
}
