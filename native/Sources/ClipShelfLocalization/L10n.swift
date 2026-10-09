import Foundation

public enum L10n {
    private static let runtime = LocalizationRuntime()

    public static func text(_ message: LocalizedMessage) -> String { runtime.text(message) }

    /// The first call configures this process. Saving another preference takes
    /// effect on the next launch, so existing windows cannot mix runtime states.
    public static func configure(language: InterfaceLanguage, preferredLanguages: [String], hostBundle: Bundle = .main) {
        runtime.configure(language: language, preferredLanguages: preferredLanguages, hostBundle: hostBundle)
    }

    public static var language: InterfaceLanguage { runtime.diagnostics.language }
    public static var locale: Locale { Locale(identifier: language.rawValue) }
    public static var diagnostics: L10nDiagnostics { runtime.diagnostics }
}

struct LocalizationCatalogFiles {
    let directory: URL?
    let source: L10nResourceSource
    let contents: [InterfaceLanguage: Data]
    let issues: [String]
}

struct LocalizationCatalog {
    let translations: [String: LocalizationTemplate]
    let keys: Set<String>
    let issues: [String]

    init(data: Data?, language: InterfaceLanguage) {
        let prefix = "catalog.\(language.rawValue)."
        guard let data else {
            translations = [:]; keys = []; issues = [prefix + "missing"]; return
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: data), let dictionary = decoded as? [String: String] else {
            translations = [:]; keys = []; issues = [prefix + "invalidJSON"]; return
        }
        var result: [String: LocalizationTemplate] = [:], issues: [String] = []
        var invalidKey = false, invalidTemplate = false, invalidPlaceholders = false
        for (key, value) in dictionary {
            guard let source = LocalizationTemplate(key), source.placeholders == Array(0..<source.placeholders.count) else {
                invalidKey = true; continue
            }
            guard let translation = LocalizationTemplate(value) else { invalidTemplate = true; continue }
            guard Set(source.placeholders) == Set(translation.placeholders) else { invalidPlaceholders = true; continue }
            result[key] = translation
        }
        if invalidKey { issues.append(prefix + "invalidKey") }
        if invalidTemplate { issues.append(prefix + "invalidTemplate") }
        if invalidPlaceholders { issues.append(prefix + "invalidPlaceholders") }
        translations = result; keys = Set(dictionary.keys); self.issues = issues
    }
}

/// Tests use independent instances, keeping the global source-language default
/// deterministic for the app's existing test targets in the same process.
final class LocalizationRuntime: @unchecked Sendable {
    struct Snapshot {
        let translations: [String: LocalizationTemplate]
        let english: [String: LocalizationTemplate]
        let diagnostics: L10nDiagnostics
    }
    private let lock = NSLock()
    private var snapshot: Snapshot?
    private let catalogLoader: (Bundle) -> LocalizationCatalogFiles

    init(catalogLoader: @escaping (Bundle) -> LocalizationCatalogFiles = { LocalizationResources.load(hostBundle: $0) }) {
        self.catalogLoader = catalogLoader
    }

    var diagnostics: L10nDiagnostics {
        lock.lock(); defer { lock.unlock() }
        return snapshot?.diagnostics ?? L10nDiagnostics(language: .zhHans, resourceDirectory: nil,
                                                       resourceSource: .unconfigured, issues: [])
    }

    func text(_ message: LocalizedMessage) -> String {
        lock.lock(); let current = snapshot; lock.unlock()
        guard let current else { return message.source }
        return current.translations[message.key]?.render(arguments: message.arguments)
            ?? current.english[message.key]?.render(arguments: message.arguments) ?? message.source
    }

    func configure(language: InterfaceLanguage, preferredLanguages: [String], hostBundle: Bundle = .main) {
        lock.lock(); let configured = snapshot != nil; lock.unlock()
        guard !configured else { return }
        // Loading outside the lock avoids blocking readers and invoking arbitrary
        // Bundle/JSON work while locked. The first completed configuration wins.
        let files = catalogLoader(hostBundle)
        let selected = InterfaceLanguage.resolve(language, preferredLanguages: preferredLanguages)
        var catalogs: [InterfaceLanguage: LocalizationCatalog] = [:], issues = files.issues
        for language in InterfaceLanguage.supported {
            let catalog = LocalizationCatalog(data: files.contents[language], language: language)
            catalogs[language] = catalog; issues += catalog.issues
        }
        let completeKeys = catalogs.values.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        for language in InterfaceLanguage.supported where catalogs[language]?.keys != completeKeys {
            issues.append("catalog.\(language.rawValue).incompleteKeySet")
        }
        let prepared = Snapshot(translations: catalogs[selected]?.translations ?? [:], english: catalogs[.en]?.translations ?? [:],
            diagnostics: L10nDiagnostics(language: selected, resourceDirectory: files.directory, resourceSource: files.source, issues: issues))
        lock.lock(); defer { lock.unlock() }
        if snapshot == nil { snapshot = prepared }
    }
}

/// Packaged applications must carry their own resource bundle. In particular,
/// never evaluate SwiftPM's generated absolute-path fallback inside an app or
/// extension: that can hide a broken distributable on a developer's machine.
enum LocalizationResources {
    static let bundleName = "ClipShelf_ClipShelfLocalization.bundle"

    static func load(hostBundle: Bundle, packageBundle: () -> Bundle? = packageResources) -> LocalizationCatalogFiles {
        if let resources = hostBundle.resourceURL {
            let candidate = resources.appendingPathComponent(bundleName, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue,
               let bundle = Bundle(url: candidate), let directory = bundle.resourceURL {
                guard isContained(directory, in: hostBundle.bundleURL) else {
                    return LocalizationCatalogFiles(directory: nil, source: .missing, contents: [:], issues: ["resources.outsideHostBundle"])
                }
                return read(directory: directory, source: .hostBundle)
            }
        }
        let isPackaged = hostBundle.bundleURL.pathComponents.contains {
            let component = $0.lowercased()
            return component.hasSuffix(".app") || component.hasSuffix(".appex")
        }
        if !isPackaged, let bundle = packageBundle(), let directory = bundle.resourceURL {
            return read(directory: directory, source: .swiftPackage)
        }
        return LocalizationCatalogFiles(directory: nil, source: .missing, contents: [:], issues: ["resources.missing"])
    }

    private static func read(directory: URL, source: L10nResourceSource) -> LocalizationCatalogFiles {
        var contents: [InterfaceLanguage: Data] = [:], issues: [String] = []
        for language in InterfaceLanguage.supported {
            let url = directory.appendingPathComponent("catalog-\(language.rawValue).json")
            guard isContained(url, in: directory) else {
                issues.append("resources.\(language.rawValue).outsideResourceBundle")
                continue
            }
            do { contents[language] = try Data(contentsOf: url) }
            catch { issues.append("resources.\(language.rawValue).unreadable") }
        }
        return LocalizationCatalogFiles(directory: directory, source: source, contents: contents, issues: issues)
    }

    private static func isContained(_ url: URL, in directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let child = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return child.count > root.count && child.starts(with: root)
    }

    private static func packageResources() -> Bundle? {
        #if SWIFT_PACKAGE
        return .module
        #else
        return nil
        #endif
    }
}
