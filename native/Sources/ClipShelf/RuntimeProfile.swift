import Foundation

/// Interactive acceptance uses the real query/paste path with a separate data
/// directory and preference domain. It never resumes a user's background services.
struct RuntimeProfile {
    enum Mode: Equatable { case standard, demo, validation }
    let mode: Mode
    let preferences: UserDefaults
    let validationDirectory: URL?
    let validationPreferenceDomain: String?

    static let current = RuntimeProfile(arguments: CommandLine.arguments)

    init(arguments: [String], temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        if arguments.contains("--validation") {
            mode = .validation
            let identifier = UUID().uuidString
            validationDirectory = temporaryDirectory.appendingPathComponent("ClipShelf-Validation-\(identifier)", isDirectory: true)
            let domain = "io.github.bestbbb.clipshelf.validation.\(identifier)"
            validationPreferenceDomain = domain
            preferences = UserDefaults(suiteName: domain)!
            preferences.register(defaults: ["hasSeenWelcome": true, "recordingEnabled": false])
        } else {
            mode = arguments.contains("--demo") ? .demo : .standard
            validationDirectory = nil
            validationPreferenceDomain = nil
            preferences = .standard
        }
    }

    var allowsBackgroundIntegrations: Bool { mode == .standard }

    func dataDirectory() throws -> URL {
        if let validationDirectory { return validationDirectory }
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
            .appendingPathComponent("ClipShelf Development", isDirectory: true)
    }

    func discardValidationPreferences() {
        if let validationPreferenceDomain { preferences.removePersistentDomain(forName: validationPreferenceDomain) }
    }
}
