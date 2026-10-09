import Foundation
import XCTest
@testable import ClipShelfLocalization

final class LocalizationRuntimeTests: XCTestCase {
    private func data(_ values: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }
    private func runtime(english: [String: String], simplified: [String: String]? = nil,
                         traditional: [String: String]? = nil) throws -> LocalizationRuntime {
        let contents: [InterfaceLanguage: Data] = [
            .en: try data(english), .zhHans: try data(simplified ?? english), .zhHant: try data(traditional ?? english),
        ]
        return LocalizationRuntime { _ in .init(directory: nil, source: .hostBundle, contents: contents, issues: []) }
    }

    func testUnconfiguredUsesSourceWithoutReadingEnvironmentOrResources() {
        let runtime = LocalizationRuntime { _ in XCTFail("Unconfigured text must not load resources"); return .init(directory: nil, source: .missing, contents: [:], issues: []) }
        let value = "{1} 50% 🇹🇼"
        XCTAssertEqual(runtime.text("中文 {literal} \(value)"), "中文 {literal} {1} 50% 🇹🇼")
        XCTAssertEqual(runtime.diagnostics.language, .zhHans)
        XCTAssertEqual(runtime.diagnostics.resourceSource, .unconfigured)
    }

    func testMessageEscapesBracesAndAcceptsGenericInterpolation() {
        struct Description: CustomStringConvertible { var description: String { "Ω 中文" } }
        let message: LocalizedMessage = "{{范围}} {value} \(17) · \(Description()) · \(Optional<Int>.none as Any)"
        XCTAssertEqual(message.key, "{{{{范围}}}} {{value}} {0} · {1} · {2}")
        XCTAssertEqual(message.arguments, ["17", "Ω 中文", "nil"])
        XCTAssertEqual(message.source, "{{范围}} {value} 17 · Ω 中文 · nil")
        let literal: LocalizedMessage = "完全没有参数 {0}"
        XCTAssertEqual(literal.key, "完全没有参数 {{0}}")
    }

    func testTranslationReordersAndRepeatsArgumentsWithoutRecursiveExpansion() throws {
        let runtime = try runtime(english: ["保存 {0} 到 {1}": "Destination {1}; payload {0}; again {0}; literal {{1}}; 100%"])
        runtime.configure(language: .en, preferredLanguages: [])
        let payload = "{1} %s %@ 中文 🧪"
        XCTAssertEqual(runtime.text("保存 \(payload) 到 \("Desk")"), "Destination Desk; payload {1} %s %@ 中文 🧪; again {1} %s %@ 中文 🧪; literal {1}; 100%")
        XCTAssertEqual(runtime.diagnostics.issues, [])
    }

    func testLiteralBracesUnicodePercentNewlineAndQuotesArePreserved() throws {
        let key = "{{配置}}：100% · 中文\n\"标题\""
        let runtime = try runtime(english: [key: "{{Settings}}: 100% · 日本語\n\"Title\""])
        runtime.configure(language: .en, preferredLanguages: [])
        XCTAssertEqual(runtime.text("{配置}：100% · 中文\n\"标题\""), "{Settings}: 100% · 日本語\n\"Title\"")
    }

    func testSystemLanguageResolutionUsesFirstSupportedLanguageAndScripts() {
        let examples: [([String], InterfaceLanguage)] = [
            (["fr-FR", "en-GB", "zh-TW"], .en), (["de", "zh-TW", "en"], .zhHant),
            (["zh-HK"], .zhHant), (["zh_MO"], .zhHant), (["ZH-hAnt-cn"], .zhHant),
            (["zh-Hans-HK"], .zhHans), (["zh-CN"], .zhHans), (["zh-SG"], .zhHans), (["zh"], .zhHans),
            (["en-US"], .en), (["es", "fr"], .en), ([], .en), (["zhx", "english"], .en),
        ]
        for (preferences, expected) in examples {
            XCTAssertEqual(InterfaceLanguage.resolve(.system, preferredLanguages: preferences), expected, "\(preferences)")
        }
        XCTAssertEqual(InterfaceLanguage.resolve(.zhHans, preferredLanguages: ["en-US"]), .zhHans)
        XCTAssertEqual(InterfaceLanguage.resolve(.zhHant, preferredLanguages: []), .zhHant)
        XCTAssertEqual(InterfaceLanguage.resolve(.en, preferredLanguages: ["zh-TW"]), .en)
    }

    func testConfigurationIsFixedForProcessContext() throws {
        let runtime = try runtime(english: ["保存": "Save"], simplified: ["保存": "保存"], traditional: ["保存": "儲存"])
        runtime.configure(language: .system, preferredLanguages: ["zh-TW"])
        runtime.configure(language: .en, preferredLanguages: ["en-US"])
        XCTAssertEqual(runtime.diagnostics.language, .zhHant)
        XCTAssertEqual(runtime.text("保存"), "儲存")
    }

    func testMissingTranslationFallsBackToEnglishThenSource() throws {
        let runtime = try runtime(english: ["保存 {0}": "Save {0}"], traditional: [:])
        runtime.configure(language: .zhHant, preferredLanguages: [])
        XCTAssertEqual(runtime.text("保存 \(5)"), "Save 5")
        XCTAssertEqual(runtime.text("不存在 \(7)"), "不存在 7")
        XCTAssertTrue(runtime.diagnostics.issues.contains("catalog.zh-Hant.incompleteKeySet"))
    }

    func testAllMissingCatalogsFallBackToSourceWithDiagnostics() {
        let runtime = LocalizationRuntime { _ in .init(directory: nil, source: .missing, contents: [:], issues: ["resources.missing"]) }
        runtime.configure(language: .en, preferredLanguages: [])
        XCTAssertEqual(runtime.text("{字面值} \(3)"), "{字面值} 3")
        XCTAssertEqual(runtime.diagnostics.resourceSource, .missing)
        XCTAssertTrue(runtime.diagnostics.issues.contains("catalog.en.missing"))
        XCTAssertTrue(runtime.diagnostics.issues.contains("resources.missing"))
    }

    func testMalformedJSONAndNonStringValuesAreRejected() {
        for source in ["not json", "[]", "null", "{\"保存\": 1}", "{\"保存\": null}"] {
            let catalog = LocalizationCatalog(data: Data(source.utf8), language: .en)
            XCTAssertTrue(catalog.translations.isEmpty)
            XCTAssertEqual(catalog.issues, ["catalog.en.invalidJSON"], source)
        }
    }

    func testInvalidTemplateFallsBackWithoutDroppingValidSibling() throws {
        for value in ["Bad {", "Bad }", "Bad {1}", "Bad {00}", "Bad {-1}", "Bad {name}", "Bad {999999999999999999999999999}", "Missing parameter"] {
            let runtime = try runtime(english: ["保存 {0}": "Save {0}", "取消": "Cancel"],
                                      traditional: ["保存 {0}": value, "取消": "取消"])
            runtime.configure(language: .zhHant, preferredLanguages: [])
            XCTAssertEqual(runtime.text("保存 \(9)"), "Save 9", value)
            XCTAssertEqual(runtime.text("取消"), "取消")
            XCTAssertFalse(runtime.diagnostics.issues.isEmpty)
        }
    }

    func testInvalidSourceKeysAreRejected() throws {
        for key in ["保存 {", "保存 }", "保存 {1}", "保存 {0} {0}", "保存 {00}", "保存 {1} {0}"] {
            let catalog = LocalizationCatalog(data: try data([key: key]), language: .en)
            XCTAssertTrue(catalog.translations.isEmpty, key)
            XCTAssertEqual(catalog.issues, ["catalog.en.invalidKey"], key)
        }
        let valid = LocalizationCatalog(data: try data(["保存 {{0}} {0}": "Save {0} literal {{0}}"]), language: .en)
        XCTAssertEqual(valid.translations.count, 1)
        XCTAssertEqual(valid.issues, [])
    }

    func testAllPlaceholderArgumentsMustBeRepresentedButMayRepeat() throws {
        let missing = LocalizationCatalog(data: try data(["{0} 加 {1}": "Only {1}"]), language: .en)
        XCTAssertEqual(missing.issues, ["catalog.en.invalidPlaceholders"])
        let extra = LocalizationCatalog(data: try data(["{0} 加 {1}": "{0}, {1}, {2}"]), language: .en)
        XCTAssertEqual(extra.issues, ["catalog.en.invalidPlaceholders"])
        let repeated = LocalizationCatalog(data: try data(["{0} 加 {1}": "{1}, {0}, {1}"]), language: .en)
        XCTAssertEqual(repeated.issues, [])
    }

    func testCatalogKeySetsAreCheckedAcrossEverySupportedLanguage() throws {
        let runtime = try runtime(english: ["保存": "Save"], simplified: ["保存": "保存", "取消": "取消"], traditional: ["保存": "儲存"])
        runtime.configure(language: .en, preferredLanguages: [])
        XCTAssertEqual(Set(runtime.diagnostics.issues), ["catalog.en.incompleteKeySet", "catalog.zh-Hant.incompleteKeySet"])
    }

    func testConcurrentReadersSeeCompleteSnapshotsAndNeverReinterpretParameters() throws {
        let runtime = try runtime(english: ["保存 {0}": "Save {0}"])
        let results = LockedValues<String>()
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index == 100 { runtime.configure(language: .en, preferredLanguages: []) }
            let injection = "{0}"
            results.append(runtime.text("保存 \(injection)"))
        }
        XCTAssertEqual(results.values.count, 1_000)
        XCTAssertTrue(Set(results.values).isSubset(of: ["保存 {0}", "Save {0}"]))
        XCTAssertEqual(runtime.text("保存 \(3)"), "Save 3")
    }

    func testConcurrentConfigurationProducesOneImmutableLanguageSnapshot() throws {
        let runtime = try runtime(english: ["保存": "Save"], simplified: ["保存": "保存"], traditional: ["保存": "儲存"])
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            runtime.configure(language: InterfaceLanguage.supported[index % 3], preferredLanguages: [])
        }
        let expected: [InterfaceLanguage: String] = [.en: "Save", .zhHans: "保存", .zhHant: "儲存"]
        let language = runtime.diagnostics.language
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            XCTAssertEqual(runtime.diagnostics.language, language)
            XCTAssertEqual(runtime.text("保存"), expected[language])
        }
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
}
