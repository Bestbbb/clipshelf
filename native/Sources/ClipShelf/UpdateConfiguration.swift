import ClipShelfLocalization
import Foundation
import CoreFoundation

/// Reading configuration never initializes Sparkle or a preferences domain.
struct UpdateConfiguration: Equatable {
    let feedURL: URL
    let publicEdKey: String
    let version: String
    let build: String
    let bundleIdentifier: String

    enum Unavailable: Error, LocalizedError, Equatable {
        case isolatedRuntime, developmentBuild, invalidReleaseConfiguration(String)
        var errorDescription: String? {
            switch self {
            case .isolatedRuntime: return L10n.text("演示和验证模式不启用应用更新。")
            case .developmentBuild: return L10n.text("开发版本未启用应用更新；正式发行版配置后才可检查。")
            case .invalidReleaseConfiguration(let reason): return L10n.text("此发行版的更新配置不完整：\(reason)")
            }
        }
    }

    static func read(bundle: Bundle, allowsBackgroundIntegrations: Bool) throws -> Self {
        try read(info: bundle.infoDictionary ?? [:], allowsBackgroundIntegrations: allowsBackgroundIntegrations)
    }

    static func read(info: [String: Any], allowsBackgroundIntegrations: Bool) throws -> Self {
        guard allowsBackgroundIntegrations else { throw Unavailable.isolatedRuntime }
        guard info["ClipShelfDistribution"] as? String == "release" else { throw Unavailable.developmentBuild }
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else { throw Unavailable.invalidReleaseConfiguration(reason) }
        }
        let rawURL = info["SUFeedURL"] as? String ?? ""
        let components = URLComponents(string: rawURL)
        try require(!rawURL.isEmpty && !rawURL.contains(where: { $0.isWhitespace }) &&
                    components?.scheme == "https" && components?.host?.isEmpty == false &&
                    components?.user == nil && components?.password == nil && components?.fragment == nil &&
                    components?.url != nil, L10n.text("需要有效的 HTTPS 更新源。"))
        let key = info["SUPublicEDKey"] as? String ?? ""
        let keyData = Data(base64Encoded: key)
        try require(keyData?.count == 32 && keyData?.base64EncodedString() == key, L10n.text("需要规范的 32 字节 Ed25519 公钥。"))
        func boolean(_ name: String, equals expected: Bool) -> Bool {
            guard let value = info[name] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
            return value.boolValue == expected
        }
        let grace = info["SUSignedFeedFailureExpirationInterval"] as? NSNumber
        try require(boolean("SUVerifyUpdateBeforeExtraction", equals: true) &&
                    boolean("SURequireSignedFeed", equals: true) &&
                    grace.map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == 0 } == true,
                    L10n.text("必须验证更新包与更新源签名，且不能设置验签失败宽限期。"))
        try require(boolean("SUEnableAutomaticChecks", equals: false) &&
                    boolean("SUAutomaticallyUpdate", equals: false) &&
                    boolean("SUEnableSystemProfiling", equals: false),
                    L10n.text("发行配置必须默认关闭自动检查、自动下载与系统资料收集。"))
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        try require(version.range(of: "^[0-9]+(\\.[0-9]+){0,2}\\z", options: .regularExpression) != nil &&
                    build.range(of: "^[1-9][0-9]*\\z", options: .regularExpression) != nil,
                    L10n.text("需要有效的发行版本与递增构建编号。"))
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        let forbiddenComponents: Set<String> = ["dev", "demo", "validation"]
        try require(identifier.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+\\z", options: .regularExpression) != nil &&
                    !identifier.lowercased().split(separator: ".").contains(where: { forbiddenComponents.contains(String($0)) }),
                    L10n.text("需要独立的正式版应用标识。"))
        return Self(feedURL: components!.url!, publicEdKey: key, version: version, build: build, bundleIdentifier: identifier)
    }
}
