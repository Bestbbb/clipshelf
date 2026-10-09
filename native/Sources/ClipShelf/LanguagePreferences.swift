import Foundation
import Security
import ClipShelfLocalization

/// Stores a choice for the next process launch. Saving never changes the active
/// localization context, touches global preferences, or starts a service.
final class LanguagePreferences {
    static let selectionKey = "interfaceLanguage"
    static let appleLanguagesKey = "AppleLanguages"
    private let preferences: UserDefaults
    private let sharedPreferences: UserDefaults?
    let allowsChanges: Bool

    init(preferences: UserDefaults, allowsChanges: Bool, sharedPreferences: UserDefaults? = nil) {
        self.preferences = preferences
        self.allowsChanges = allowsChanges
        self.sharedPreferences = allowsChanges ? sharedPreferences : nil
    }

    static func selectedLanguage(in preferences: UserDefaults) -> InterfaceLanguage {
        preferences.string(forKey: selectionKey).flatMap(InterfaceLanguage.init(rawValue:)) ?? .system
    }
    var selectedLanguage: InterfaceLanguage { Self.selectedLanguage(in: preferences) }

    enum SaveError: Error, LocalizedError {
        case isolatedRuntime
        var errorDescription: String? { L10n.text("演示和验证模式不能保存语言设置；真实设置保持不变。") }
    }

    func save(_ language: InterfaceLanguage) throws {
        guard allowsChanges else { throw SaveError.isolatedRuntime }
        for destination in [preferences, sharedPreferences].compactMap({ $0 }) {
            destination.set(language.rawValue, forKey: Self.selectionKey)
            if language == .system {
                // Remove only this app/suite's override. The inherited macOS
                // language list is left intact, including unsupported languages.
                destination.removeObject(forKey: Self.appleLanguagesKey)
            } else {
                destination.set([language.rawValue], forKey: Self.appleLanguagesKey)
            }
        }
    }

    /// Match the signed App Group boundary used by the sharing extension. Merely
    /// declaring a group in an unsigned development plist does not authorize it.
    static func configuredSharedPreferences(bundle: Bundle = .main, allowsChanges: Bool) -> UserDefaults? {
        guard allowsChanges,
              let identifier = bundle.object(forInfoDictionaryKey: "ClipShelfAppGroupIdentifier") as? String,
              !identifier.isEmpty, !identifier.contains("$("), !identifier.contains("YOUR_"),
              let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              groups.contains(identifier) else { return nil }
        return UserDefaults(suiteName: identifier)
    }
}
