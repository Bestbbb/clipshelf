import Foundation
import ClipShelfCore
import ClipShelfLocalization

struct LibraryStorageSnapshot: Sendable {
    let report: StorageUsageReport
    let profileAvailableBytes: Int64?
}

enum LibraryStorageReader {
    static func additionalRoots(validationDirectory: URL?, cachesDirectory: URL,
                                shareInboxRoot: URL?) -> [StorageUsageRoot] {
        if let validationDirectory {
            return [
                .init(id: "ocr", url: validationDirectory.appendingPathComponent("OCR"), category: .ocrCache, scopeKind: .profile),
                .init(id: "images", url: validationDirectory.appendingPathComponent("ImageExports"), category: .imageExports, scopeKind: .profile)
            ]
        }
        var roots: [StorageUsageRoot] = [
            .init(id: "ocr", url: cachesDirectory.appendingPathComponent("ClipShelf/OCR-v1"), category: .ocrCache, scopeKind: .sharedCache),
            .init(id: "images", url: cachesDirectory.appendingPathComponent("io.github.bestbbb.clipshelf/ImageExports"), category: .imageExports, scopeKind: .sharedCache)
        ]
        if let shareInboxRoot {
            roots.append(.init(id: "share", url: shareInboxRoot, category: .shareInbox, scopeKind: .appGroup))
        } else {
            roots.append(.unavailable(id: "share", category: .shareInbox, scopeKind: .appGroup, reason: .unavailable))
        }
        return roots
    }

    static func read(store: HistoryStore, roots: [StorageUsageRoot], cancellation: HistoryReadCancellation) throws -> LibraryStorageSnapshot {
        let report = try StorageUsageScanner.scan(scope: store.storageUsageScope(additionalRoots: roots), cancellation: cancellation)
        let available = try? StorageSpaceCoordinator.systemCapacity(for: report.scope.profileDirectory).availableBytes
        guard !cancellation.isCancelled else { throw CancellationError() }
        return LibraryStorageSnapshot(report: report, profileAvailableBytes: available)
    }

    static func describe(_ snapshot: LibraryStorageSnapshot) -> String {
        let report = snapshot.report
        var lines = [L10n.text("整库占用 · 已计量范围")]
        for kind in [StorageUsageScopeKind.profile, .sharedCache, .appGroup] {
            let rows = report.measurements.filter { $0.scopeKind == kind }
            let rootStates = report.roots.filter { $0.root.scopeKind == kind }
            guard !rows.isEmpty || !rootStates.isEmpty else { continue }
            lines += ["", scopeLabel(kind)]
            for category in StorageUsageCategory.allCases where category != .storageCredentials && category != .directoryMetadata {
                let matching = rows.filter {
                    category == .ownedCredentials
                        ? [.ownedCredentials, .storageCredentials, .directoryMetadata].contains($0.category)
                        : $0.category == category
                }
                guard !matching.isEmpty else { continue }
                let logical = L10n.fileSize(matching.reduce(0) { $0 + $1.logicalBytes })
                let allocated = L10n.fileSize(matching.reduce(0) { $0 + $1.allocatedBytes })
                lines.append(L10n.text("\(categoryLabel(category))：大小 \(logical) · 分配 \(allocated)"))
            }
            if rows.isEmpty, rootStates.allSatisfy({ $0.status == .notPresent }) {
                lines.append(L10n.text("尚未创建对应目录。"))
            }
            if rootStates.contains(where: { $0.status == .unavailable }) {
                lines.append(L10n.text("部分范围不可访问，未计入总量。"))
            }
        }
        lines += ["", L10n.text("已计量合计：\(L10n.fileSize(report.logicalBytes)) · 分配 \(L10n.fileSize(report.allocatedBytes))")]
        if let available = snapshot.profileAvailableBytes {
            lines.append(L10n.text("资料库所在卷当前可用：\(L10n.fileSize(available))"))
        } else { lines.append(L10n.text("资料库所在卷的可用空间暂时未知。")) }
        if report.isPartial {
            lines.append(L10n.text("扫描期间内容有变化、存在未知范围或达到扫描边界；当前统计可能不完整，请稍后刷新。"))
        }
        lines.append(L10n.text("统计时间：\(L10n.date(report.finishedAt, includesDate: true))"))
        return lines.joined(separator: "\n")
    }

    private static func scopeLabel(_ kind: StorageUsageScopeKind) -> String {
        switch kind {
        case .profile: return L10n.text("当前资料库")
        case .sharedCache: return L10n.text("各资料库共用缓存")
        case .appGroup: return L10n.text("系统分享收件箱")
        }
    }
    private static func categoryLabel(_ category: StorageUsageCategory) -> String {
        switch category {
        case .database: return L10n.text("数据库与日志")
        case .representations: return L10n.text("剪贴板附件")
        case .ownedOriginals: return L10n.text("托管原件")
        case .ownedOpenCopies: return L10n.text("打开副本")
        case .ownedQuarantine: return L10n.text("回收暂存")
        case .ownedCredentials, .storageCredentials, .directoryMetadata: return L10n.text("管理元数据")
        case .backups: return L10n.text("备份")
        case .shareImports: return L10n.text("分享导入")
        case .ocrCache: return L10n.text("OCR 缓存")
        case .imageExports: return L10n.text("图片导出缓存")
        case .shareInbox: return L10n.text("系统分享收件箱")
        case .unknown: return L10n.text("待检查内容")
        }
    }
}
