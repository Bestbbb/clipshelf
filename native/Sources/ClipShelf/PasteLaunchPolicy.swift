import ApplicationServices

enum PasteLaunchPolicy {
    /// Opening the app from Finder's navigation surface does not identify a
    /// destination input. Finder text fields (rename/search) remain valid targets.
    static func requiresDestinationChoice(bundleID: String?, focusedRole: String?) -> Bool {
        guard bundleID == "com.apple.finder" else { return false }
        return ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(focusedRole ?? "")
    }
}
