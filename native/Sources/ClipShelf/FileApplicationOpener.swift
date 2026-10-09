import AppKit
import Foundation

struct FileOpeningApplication: Equatable {
    let url: URL
    let name: String
    let isDefault: Bool
    let menuTitle: String
}

struct FileApplicationListing {
    let applications: [URL]
    let defaultApplication: URL?
}

enum FileApplicationError: LocalizedError {
    case invalidFile, unavailableApplication, cannotOpen
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "文件位置无效，请刷新后重试。"
        case .unavailableApplication: return "所选应用已不可用，请重新选择已安装的应用。"
        case .cannotOpen: return "系统未能使用所选应用打开文件，请重试或选择其他应用。"
        }
    }
}

/// Launch Services discovery and explicit opening only. This never changes a
/// file type's default application and never launches during enumeration.
@MainActor
final class FileApplicationOpener {
    typealias Provider = (URL, @escaping (Result<FileApplicationListing, Error>) -> Void) -> Void
    typealias Launcher = (URL, URL, @escaping (Result<Void, Error>) -> Void) -> Void
    private let provider: Provider
    private let launcher: Launcher
    private let applicationName: (URL) -> String
    private let isApplication: (URL) -> Bool

    init(provider: Provider? = nil, launcher: Launcher? = nil,
         applicationName: ((URL) -> String)? = nil, isApplication: ((URL) -> Bool)? = nil) {
        self.provider = provider ?? { file, reply in
            reply(.success(FileApplicationListing(applications: NSWorkspace.shared.urlsForApplications(toOpen: file),
                defaultApplication: NSWorkspace.shared.urlForApplication(toOpen: file))))
        }
        self.launcher = launcher ?? { file, application, reply in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file], withApplicationAt: application, configuration: configuration) { running, error in
                Task { @MainActor in
                    if let error { reply(.failure(error)) }
                    else if running != nil { reply(.success(())) }
                    else { reply(.failure(FileApplicationError.cannotOpen)) }
                }
            }
        }
        self.applicationName = applicationName ?? { url in
            let name = FileManager.default.displayName(atPath: url.path)
            return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        self.isApplication = isApplication ?? { url in
            guard let values = try? url.resourceValues(forKeys: [.isApplicationKey, .isDirectoryKey]) else { return false }
            return values.isApplication == true && values.isDirectory == true
        }
    }

    func applications(for file: URL, completion: @escaping (Result<[FileOpeningApplication], Error>) -> Void) {
        guard Self.localURL(file) else { completion(.failure(FileApplicationError.invalidFile)); return }
        provider(file) { [weak self] result in
            guard let self else { return }
            completion(result.map { listing in
                let defaultURL = listing.defaultApplication?.standardizedFileURL
                let ordered = (listing.defaultApplication.map { [$0] } ?? []) + listing.applications
                var seen = Set<URL>()
                let urls = ordered.map(\.standardizedFileURL).filter {
                    Self.localURL($0) && self.isApplication($0) && seen.insert($0).inserted
                }
                let names = urls.map { self.applicationName($0) }
                let counts = Dictionary(grouping: names, by: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }).mapValues(\.count)
                return zip(urls, names).map { url, name in
                    let duplicate = counts[name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), default: 0] > 1
                    let isDefault = url == defaultURL
                    return FileOpeningApplication(url: url, name: name, isDefault: isDefault,
                        menuTitle: name + (isDefault ? "（默认）" : "") + (duplicate ? " — \(url.path)" : ""))
                }
            })
        }
    }

    func application(at url: URL) throws -> FileOpeningApplication {
        let normalized = url.standardizedFileURL
        guard Self.localURL(url), isApplication(normalized) else { throw FileApplicationError.unavailableApplication }
        let name = applicationName(normalized)
        return FileOpeningApplication(url: normalized, name: name, isDefault: false, menuTitle: name)
    }

    func open(file: URL, using application: FileOpeningApplication, completion: @escaping (Result<Void, Error>) -> Void) {
        guard Self.localURL(file) else { completion(.failure(FileApplicationError.invalidFile)); return }
        // Recheck the chosen bundle at the final boundary, rather than trusting an
        // application that happened to be installed when the menu was constructed.
        guard Self.localURL(application.url), isApplication(application.url) else {
            completion(.failure(FileApplicationError.unavailableApplication)); return
        }
        launcher(file, application.url, completion)
    }

    private static func localURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost") &&
            url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil && !url.path.contains("\0")
    }
}
