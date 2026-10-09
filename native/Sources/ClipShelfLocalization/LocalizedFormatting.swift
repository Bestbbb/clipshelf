import Foundation

public extension L10n {
    /// Locale changes presentation only; the user's local time zone is preserved.
    static func date(_ value: Date, includesDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = includesDate ? .medium : .none
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }

    static func fileSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}
