import Foundation

/// The saved choice can follow the system; a configured runtime always resolves it
/// to a supported interface language for the lifetime of the process.
public enum InterfaceLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case cs, da, nl, fr, de, he, it, ja, ko, pl, pt, ru, es

    public static var supported: [InterfaceLanguage] { allCases.filter { $0 != .system } }
    public var isRightToLeft: Bool { self == .he }

    /// Self-names stay recognizable when the current interface language is unfamiliar.
    public var nativeName: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .cs: return "Čeština"
        case .da: return "Dansk"
        case .nl: return "Nederlands"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .he: return "עברית"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .pl: return "Polski"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .es: return "Español"
        }
    }

    static func resolve(_ choice: InterfaceLanguage, preferredLanguages: [String]) -> InterfaceLanguage {
        guard choice == .system else { return choice }
        for preference in preferredLanguages {
            let pieces = preference.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
            guard let language = pieces.first else { continue }
            if language == "zh" {
                // An explicit script takes precedence over a region hint.
                if pieces.contains("hant") { return .zhHant }
                if pieces.contains("hans") { return .zhHans }
                return pieces.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .zhHant : .zhHans
            }
            if language == "iw" { return .he } // Legacy ISO identifier still found in preferences.
            if let matched = supported.first(where: { $0.rawValue.lowercased() == language }) { return matched }
        }
        return .en
    }
}

public enum L10nResourceSource: String, Sendable {
    case unconfigured
    case hostBundle
    case swiftPackage
    case missing
}

/// Diagnostic information is for packaging verification, not user-facing copy.
/// Issues contain stable codes rather than translated text or clipboard content.
public struct L10nDiagnostics: Equatable, Sendable {
    public let language: InterfaceLanguage
    public let resourceDirectory: URL?
    public let resourceSource: L10nResourceSource
    public let issues: [String]
}
