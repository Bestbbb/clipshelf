import AppKit
import XCTest
@testable import ClipShelf

@MainActor final class FileApplicationOpenerTests: XCTestCase {
    func testDiscoveryIncludesDefaultDeduplicatesAndDisambiguatesWithoutLaunching() throws {
        let file = URL(fileURLWithPath: "/synthetic/item.pdf")
        let first = URL(fileURLWithPath: "/Applications/Reader.app")
        let second = URL(fileURLWithPath: "/Users/synthetic/Applications/Reader.app")
        var launched = false, received: [FileOpeningApplication] = []
        let service = FileApplicationOpener(provider: { url, reply in
            XCTAssertEqual(url, file)
            reply(.success(.init(applications: [first, second, first, URL(string: "https://example.com/Fake.app")!], defaultApplication: second)))
        }, launcher: { _, _, _ in launched = true }, applicationName: { _ in "Reader" }, isApplication: { _ in true })
        service.applications(for: file) { received = (try? $0.get()) ?? [] }
        XCTAssertEqual(received.map(\.url), [second, first])
        XCTAssertTrue(received[0].isDefault); XCTAssertFalse(received[1].isDefault)
        XCTAssertTrue(received[0].menuTitle.contains("默认"))
        XCTAssertTrue(received[0].menuTitle.contains(second.path)); XCTAssertTrue(received[1].menuTitle.contains(first.path))
        XCTAssertFalse(launched)
    }
    func testMissingDefaultAndNonApplicationAreOmittedAndOtherAppIsValidated() throws {
        let valid = URL(fileURLWithPath: "/Applications/Valid.app")
        let service = FileApplicationOpener(provider: { _, reply in
            reply(.success(.init(applications: [valid, URL(fileURLWithPath: "/tmp/readme.txt")], defaultApplication: URL(fileURLWithPath: "/missing/App.app"))))
        }, launcher: { _, _, _ in XCTFail("Unexpected launch") }, applicationName: { $0.lastPathComponent }, isApplication: { $0 == valid })
        var result: [FileOpeningApplication] = []
        service.applications(for: URL(fileURLWithPath: "/synthetic/file")) { result = (try? $0.get()) ?? [] }
        XCTAssertEqual(result.map(\.url), [valid]); XCTAssertFalse(result[0].isDefault)
        XCTAssertEqual(try service.application(at: valid).url, valid)
        XCTAssertThrowsError(try service.application(at: URL(fileURLWithPath: "/tmp/readme.txt")))
        XCTAssertThrowsError(try service.application(at: URL(string: "file://remote/Apps/Test.app")!))
    }
    func testFinalLaunchChecksChosenApplicationStillExistsAndForwardsExactURLs() throws {
        let file = URL(fileURLWithPath: "/synthetic/file"), appURL = URL(fileURLWithPath: "/Applications/Chosen.app")
        var installed = true, launches: [(URL, URL)] = [], replies: [(Result<Void, Error>) -> Void] = []
        let service = FileApplicationOpener(provider: { _, _ in XCTFail("Not enumerating") }, launcher: { file, app, reply in
            launches.append((file, app)); replies.append(reply)
        }, applicationName: { _ in "Chosen" }, isApplication: { _ in installed })
        let app = try service.application(at: appURL)
        installed = false
        service.open(file: file, using: app) { if case .success = $0 { XCTFail("Removed application launched") } }
        XCTAssertTrue(launches.isEmpty)
        installed = true
        var message: String?
        service.open(file: file, using: app) { if case .failure(let error) = $0 { message = error.localizedDescription } }
        XCTAssertEqual(launches.count, 1); XCTAssertEqual(launches[0].0, file); XCTAssertEqual(launches[0].1, appURL)
        replies[0](.failure(NSError(domain: "Synthetic", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot launch fixture"])))
        XCTAssertEqual(message, "Cannot launch fixture")
    }
    func testNonLocalFilesCannotEnumerateOrLaunch() {
        let service = FileApplicationOpener(provider: { _, _ in XCTFail("Invalid URL reached discovery") }, launcher: { _, _, _ in XCTFail("Invalid URL reached launch") }, isApplication: { _ in true })
        let app = FileOpeningApplication(url: URL(fileURLWithPath: "/Applications/App.app"), name: "App", isDefault: false, menuTitle: "App")
        for file in [URL(string: "https://example.com/file")!, URL(string: "file://remote/f.txt")!, URL(string: "file:///tmp/f.txt?query=yes")!] {
            service.applications(for: file) { if case .success = $0 { XCTFail("Unexpected success") } }
            service.open(file: file, using: app) { if case .success = $0 { XCTFail("Unexpected success") } }
        }
    }
}
