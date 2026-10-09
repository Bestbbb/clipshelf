import Foundation

/// The saved choice can follow the system; a configured runtime always resolves it
/// to one of the three supported interface languages for the lifetime of the process.
public enum InterfaceLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"

    static let supported: [InterfaceLanguage] = [.en, .zhHans, .zhHant]

    static func resolve(_ choice: InterfaceLanguage, preferredLanguages: [String]) -> InterfaceLanguage {
        guard choice == .system else { return choice }
        for preference in preferredLanguages {
            let pieces = preference.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
            guard let language = pieces.first else { continue }
            if language == "en" { return .en }
            if language == "zh" {
                // An explicit script takes precedence over a region hint.
                if pieces.contains("hant") { return .zhHant }
                if pieces.contains("hans") { return .zhHans }
                return pieces.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .zhHant : .zhHans
            }
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
