import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = ClipShelfApplication()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
