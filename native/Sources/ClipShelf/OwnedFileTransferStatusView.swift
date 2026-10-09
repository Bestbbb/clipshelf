import ClipShelfLocalization
import AppKit
import ClipShelfCore

struct OwnedFileTransferStatusItem: Equatable, Sendable {
    enum Direction: Equatable, Sendable { case upload, download }
    let filename: String
    let byteCount: Int
    let direction: Direction
    let failed: Bool
    let message: String?

    static func outstanding(_ states: [SyncOwnedTransferState]) -> [Self] {
        states.filter { $0.status != .complete }.map { state in
            Self(filename: state.file.filename, byteCount: state.file.byteCount,
                 direction: state.direction == .upload ? .upload : .download,
                 failed: state.status == .failed, message: state.error)
        }
    }
}

/// A local snapshot of outstanding transfers. No network requests or account
/// discovery happen here; the owning settings controller supplies current scope.
@MainActor
final class OwnedFileTransferStatusView: NSView {
    var onRetry: (() -> Void)?
    private let summary = NSTextField(wrappingLabelWithString: L10n.text("尚未读取文件传输状态。"))
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: L10n.text("重试文件传输"), target: nil, action: nil)
    private let scroll = NSScrollView()
    private let document = FlippedDocument()
    private var canRetry = false

    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.setAccessibilityLabel(L10n.text("文件传输摘要"))
        summary.font = .systemFont(ofSize: 13, weight: .medium)
        summary.setContentCompressionResistancePriority(.required, for: .vertical)
        retry.target = self; retry.action = #selector(retryTransfers)
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.isEnabled = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.setAccessibilityLabel(L10n.text("文件传输明细"))
        document.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        detail.setAccessibilityLabel(L10n.text("待处理文件"))
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        document.addSubview(detail); scroll.documentView = document
        for view in [summary, scroll, retry] { addSubview(view) }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: retry.topAnchor, constant: -8),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            retry.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            retry.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            detail.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            detail.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            detail.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ items: [OwnedFileTransferStatusItem], isRunning: Bool, enabled: Bool) {
        let uploads = items.filter { $0.direction == .upload }.count
        let downloads = items.count - uploads
        let failures = items.filter(\.failed).count
        if !enabled {
            summary.stringValue = L10n.text("文件传输已停止。")
            detail.stringValue = L10n.text("重新开启当前账号的同步后，才会继续处理文件。")
        } else if items.isEmpty {
            summary.stringValue = isRunning ? L10n.text("正在检查文件传输…") : L10n.text("当前没有待处理文件。")
            detail.stringValue = L10n.text("托管原件随记录传输；普通文件引用不会自动上传文件内容。")
        } else {
            summary.stringValue = L10n.text("文件任务：等待上传 \(uploads)，等待下载 \(downloads)，其中失败 \(failures)。")
            // The scroll area retains all rows; long names cannot push the retry
            // button outside the window or silently hide other failed files.
            detail.stringValue = items.map { item in
                let direction = item.direction == .upload ? L10n.text("上传") : L10n.text("下载")
                let state = item.failed ? L10n.text("失败待重试") : L10n.text("等待\(direction)")
                let filename = item.filename.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                let size = L10n.fileSize(Int64(max(0, item.byteCount)))
                let reason = item.failed ? item.message.map { " · \($0)" } ?? "" : ""
                return "\(filename) · \(size) · \(state)\(reason)"
            }.joined(separator: "\n\n")
        }
        canRetry = enabled && !isRunning && !items.isEmpty
        retry.isEnabled = canRetry
        needsLayout = true
    }

    func unavailable(_ message: String, isRunning: Bool, enabled: Bool) {
        summary.stringValue = enabled ? L10n.text("无法读取文件传输状态。") : L10n.text("文件传输已停止。")
        detail.stringValue = message
        canRetry = enabled && !isRunning
        retry.isEnabled = canRetry
    }

    @objc private func retryTransfers() {
        guard canRetry else { return }
        onRetry?()
    }
}
