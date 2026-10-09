import Foundation
import XCTest
@testable import ClipShelfLocalization

final class LocalizationResourceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clipshelf-localization-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private func bundle(_ relativePath: String) throws -> Bundle {
        let path = root.appendingPathComponent(relativePath, isDirectory: true)
        let contents = path.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources", isDirectory: true), withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "io.github.bestbbb.localization-test.\(UUID().uuidString)",
                                    "CFBundleName": "Localization Fixture", "CFBundleVersion": "1", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: path))
    }

    private func catalogBundle(in host: Bundle?, relativePath: String = "Standalone.bundle", corrupt: Bool = false) throws -> Bundle {
        let relative: String
        if let host {
            relative = try XCTUnwrap(host.resourceURL).appendingPathComponent(LocalizationResources.bundleName).path.replacingOccurrences(of: root.path + "/", with: "")
        } else { relative = relativePath }
        let catalog = try bundle(relative)
        let directory = try XCTUnwrap(catalog.resourceURL)
        let messages: [InterfaceLanguage: String] = [.en: "Save {0}", .zhHans: "保存 {0}", .zhHant: "儲存 {0}"]
        for language in InterfaceLanguage.supported {
            let data = corrupt ? Data("[1,2,3]".utf8) : try JSONSerialization.data(withJSONObject: ["保存 {0}": messages[language]!])
            try data.write(to: directory.appendingPathComponent("catalog-\(language.rawValue).json"))
        }
        return catalog
    }

    func testApplicationAndExtensionReadTheirOwnNestedBundle() throws {
        for path in ["Fixture.app", "Container.app/Contents/PlugIns/Fixture.appex"] {
            let host = try bundle(path)
            let nested = try catalogBundle(in: host)
            let files = LocalizationResources.load(hostBundle: host, packageBundle: { XCTFail("Packaged host must not evaluate SwiftPM fallback"); return nil })
            XCTAssertEqual(files.source, .hostBundle)
            XCTAssertEqual(files.directory, nested.resourceURL)
            XCTAssertEqual(files.contents.count, 3)
            XCTAssertEqual(files.issues, [])
            let runtime = LocalizationRuntime { _ in files }
            runtime.configure(language: .zhHant, preferredLanguages: [], hostBundle: host)
            XCTAssertEqual(runtime.text("保存 \(2)"), "儲存 2")
            XCTAssertEqual(runtime.diagnostics.issues, [])
        }
    }

    func testMissingPackagedResourcesNeverUseAvailablePackageBundle() throws {
        let package = try catalogBundle(in: nil)
        for path in ["Missing.app", "Missing.appex", "Outer.app/Contents/Frameworks/Inner.bundle"] {
            let host = try bundle(path)
            let files = LocalizationResources.load(hostBundle: host, packageBundle: { XCTFail("Absolute build fallback would hide a broken distributable"); return package })
            XCTAssertEqual(files.source, .missing)
            XCTAssertNil(files.directory)
            XCTAssertTrue(files.contents.isEmpty)
        }
    }

    func testMalformedPackagedCatalogNeverSubstitutesDeveloperCatalog() throws {
        let host = try bundle("Malformed.app")
        _ = try catalogBundle(in: host, corrupt: true)
        let files = LocalizationResources.load(hostBundle: host, packageBundle: { XCTFail("Existing corrupt host resources cannot fall back"); return nil })
        let runtime = LocalizationRuntime { _ in files }
        runtime.configure(language: .en, preferredLanguages: [], hostBundle: host)
        XCTAssertEqual(runtime.text("保存 \(4)"), "保存 4")
        XCTAssertEqual(runtime.diagnostics.resourceSource, .hostBundle)
        XCTAssertTrue(runtime.diagnostics.issues.contains("catalog.en.invalidJSON"))
    }

    func testCommandLineHostCanUseExplicitPackageFallback() throws {
        let host = try bundle("CommandLine.bundle")
        let package = try catalogBundle(in: nil)
        let files = LocalizationResources.load(hostBundle: host, packageBundle: { package })
        XCTAssertEqual(files.source, .swiftPackage)
        XCTAssertEqual(files.directory, package.resourceURL)
        XCTAssertEqual(files.contents.count, 3)
    }

    func testHostBundleTakesPrecedenceForCommandLineToo() throws {
        let host = try bundle("CommandLineWithResources.bundle")
        let nested = try catalogBundle(in: host)
        let files = LocalizationResources.load(hostBundle: host, packageBundle: { XCTFail("Nested resources have priority"); return nil })
        XCTAssertEqual(files.source, .hostBundle)
        XCTAssertEqual(files.directory, nested.resourceURL)
    }

    func testOneMissingLanguageProducesPartialDiagnosticsAndEnglishFallback() throws {
        let host = try bundle("Partial.app")
        let nested = try catalogBundle(in: host)
        try FileManager.default.removeItem(at: try XCTUnwrap(nested.resourceURL).appendingPathComponent("catalog-zh-Hant.json"))
        let files = LocalizationResources.load(hostBundle: host, packageBundle: { XCTFail("No developer fallback"); return nil })
        let runtime = LocalizationRuntime { _ in files }
        runtime.configure(language: .zhHant, preferredLanguages: [], hostBundle: host)
        XCTAssertEqual(runtime.text("保存 \(2)"), "Save 2")
        XCTAssertTrue(runtime.diagnostics.issues.contains("resources.zh-Hant.unreadable"))
        XCTAssertTrue(runtime.diagnostics.issues.contains("catalog.zh-Hant.missing"))
    }
    func testPackagedBundleSymlinkCannotBorrowSourceTreeResources() throws {
        let host = try bundle("Linked.app")
        let external = try catalogBundle(in: nil)
        let target = try XCTUnwrap(host.resourceURL).appendingPathComponent(LocalizationResources.bundleName)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external.bundleURL)
        let files = LocalizationResources.load(hostBundle: host, packageBundle: { XCTFail("No fallback for linked package"); return nil })
        XCTAssertEqual(files.source, .missing)
        XCTAssertTrue(files.issues.contains("resources.outsideHostBundle"))
    }

    func testCatalogSymlinkOutsideNestedBundleIsNotRead() throws {
        let host = try bundle("LinkedCatalog.app")
        let nested = try catalogBundle(in: host)
        let catalogURL = try XCTUnwrap(nested.resourceURL).appendingPathComponent("catalog-en.json")
        try FileManager.default.removeItem(at: catalogURL)
        let external = root.appendingPathComponent("external.json")
        try Data("{\"保存 {0}\":\"Unshipped {0}\"}".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: catalogURL, withDestinationURL: external)
        let files = LocalizationResources.load(hostBundle: host, packageBundle: { XCTFail("No fallback"); return nil })
        XCTAssertNil(files.contents[.en])
        XCTAssertTrue(files.issues.contains("resources.en.outsideResourceBundle"))
    }

}
