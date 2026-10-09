import AppKit
import ClipShelfLocalization

// A packaging check, before any AppKit application, clipboard, preferences or
// background service is created. Every language is tested in a separate process.
if let index = CommandLine.arguments.firstIndex(of: "--localization-diagnostics") {
    guard CommandLine.arguments.indices.contains(index + 1),
          let language = InterfaceLanguage(rawValue: CommandLine.arguments[index + 1]), language != .system else {
        FileHandle.standardError.write(Data("Expected a supported interface language identifier.\n".utf8))
        exit(2)
    }
    L10n.configure(language: language, preferredLanguages: [], hostBundle: .main)
    let diagnostics = L10n.diagnostics
    let result: [String: Any] = ["language": diagnostics.language.rawValue,
        "resourceSource": diagnostics.resourceSource.rawValue,
        "resourceDirectory": diagnostics.resourceDirectory?.path ?? "",
        "issues": diagnostics.issues, "sample": L10n.text("取消")]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
    exit(diagnostics.issues.isEmpty ? 0 : 1)
}

MainActor.assumeIsolated {
    let profile = RuntimeProfile.current
    L10n.configure(language: LanguagePreferences.selectedLanguage(in: profile.preferences),
                   preferredLanguages: Locale.preferredLanguages, hostBundle: .main)
    let application = NSApplication.shared
    let delegate = ClipShelfApplication()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
