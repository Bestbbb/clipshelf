import AppKit
import ClipShelfLocalization

struct DiagnosticsSnapshot {
    let hasPermission: Bool
    let activeBindings: [GlobalShortcutAction: ShortcutChord]
    let registrationFailures: [GlobalShortcutRegistrationError]
    let pastePreferences: PastePreferences
    let attempts: [PasteOutcomeLog.Entry]
    let footprintBytes: UInt64?
}

@MainActor
final class DiagnosticsController: NSWindowController {
    var snapshot: (() -> DiagnosticsSnapshot)?
    private let textView = NSTextView()
    private var report = ""

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("ClipShelf · 诊断")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 320)
        super.init(window: window)
        let root = NSView(); window.contentView = root
        let hint = NSTextField(wrappingLabelWithString: L10n.text("显示本次运行的最近 20 次粘贴。已发出操作不代表目标输入框已确认插入；诊断不包含剪贴板正文。"))
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        textView.isEditable = false; textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("diagnostics.report")
        scroll.documentView = textView
        let refresh = NSButton(title: L10n.text("刷新"), target: self, action: #selector(refreshReport))
        let copy = NSButton(title: L10n.text("复制诊断信息"), target: self, action: #selector(copyReport))
        let permission = NSButton(title: L10n.text("打开辅助功能设置"), target: self, action: #selector(openAccessibility))
        let buttons = NSStackView(views: [refresh, copy, permission]); buttons.spacing = 10
        buttons.distribution = .fillProportionally
        for view in [hint, scroll, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            hint.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: hint.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: hint.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        InterfaceLayout.apply(to: root)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        refreshReport(); window?.center()
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }

    static func makeReport(_ snapshot: DiagnosticsSnapshot) -> String {
        var lines = ["ClipShelf diagnostics · session only", "Accessibility: \(snapshot.hasPermission)",
                     "Default paste mode: \(snapshot.pastePreferences.strictness.rawValue)"]
        if let bytes = snapshot.footprintBytes { lines.append(String(format: "Physical footprint: %.1f MiB", Double(bytes) / 1_048_576)) }
        else { lines.append("Physical footprint: unavailable") }
        lines.append("\nActive shortcuts:")
        for action in GlobalShortcutAction.allCases {
            lines.append("  \(action == .activation ? "activation" : "stack"): \(snapshot.activeBindings[action]?.displayName ?? "unavailable")")
        }
        lines.append("\nRegistration failures (OSStatus):")
        for error in snapshot.registrationFailures {
            lines.append("  \(error.action == .activation ? "activation" : "stack") \(error.chord.displayName): \(error.status)")
        }
        lines.append("\nPer-app paste modes:")
        for (bundle, mode) in snapshot.pastePreferences.overrides.sorted(by: { $0.key < $1.key }) { lines.append("  \(bundle): \(mode.rawValue)") }
        lines.append("\nLast 20 paste attempts (dispatch is not insertion confirmation):")
        let formatter = ISO8601DateFormatter()
        for entry in snapshot.attempts.suffix(20).reversed() {
            lines.append(String(format: "%@ · %@ · %@ · %@ · %@ · %@ · %.0f ms",
                formatter.string(from: entry.timestamp), entry.bundleID ?? "unavailable", entry.mode.rawValue,
                String(describing: entry.outcome), entry.failure?.rawValue ?? "none", entry.method?.rawValue ?? "unsent", entry.elapsedMS))
        }
        return lines.joined(separator: "\n")
    }
    @objc private func refreshReport() {
        guard let snapshot else { return }
        report = Self.makeReport(snapshot()); textView.string = report
    }
    @objc private func copyReport() {
        refreshReport()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string)
    }
    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}
