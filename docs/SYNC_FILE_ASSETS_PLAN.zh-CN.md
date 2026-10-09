# 托管文件跨 Mac 同步协议与验收

状态：**Core、私有及共享 CloudKit 适配器和本地传输状态界面已实现；真实双机 CloudKit 与生产发布验收未完成。** 本文按 2026-10-10 工作树更新，保留原提案文件名便于已有链接继续访问。它不代表 F16 已完成，也不替代 [技术规格](TECHNICAL_SPEC.zh-CN.md) 中的完整同步范围。

## 1. 范围与数据流

已明确登记的托管原件可以随记录传输。当前数据库为 schema v12：v11 引入作用域、操作证明、附件状态与本机映射，v12 增加本地保留依赖和安全回收日志；包含托管原件的新操作仍使用 immutable wire v2，逻辑备份仍为 archive schema 3。普通 Finder 文件仍是外部引用，不会因同步被自动读取、复制或上传。外部 App 编辑打开副本，也不会替换原件或生成新的上传内容。

| 环节 | 当前实现 |
| --- | --- |
| 本地存储 | `OwnedFileStorage` 保存不可变 `payload` 和可供外部 App 打开的独立 projection；registry 显式登记记录与槽位 |
| outbox | 与记录修改同一事务生成不可变文件清单、内部 token、操作级 bindings 和证明；旧 revision 不会改用当前记录的文件 |
| 上传 | 从受信原件生成独立 staging，逐文件确认当前 zone 内的 blob，全部依赖成功后才发布该 operation |
| 拉取 | change feed 只取 metadata；逐个读取 operation JSON，文件 blob 按 durable inbox 的缺失依赖另行下载 |
| 等待与重试 | cursor 与 inbox 一起持久化；附件状态为 `pending`、`failed` 或 `complete`，失败或预算不足不提前发布可用 revision |
| 物化 | 已验证文件逐个存入本机受控资产和 scope 映射；操作的所有依赖齐备后才原子改写本机 URL、登记 bindings 并应用记录 |
| 共享 | 同一协议支持拥有者的 private database 和成员的 shared database；accepted replay、降权和失败草稿继续使用受信文件证明 |
| 冲突 | 按可移植文件身份比较内容，发送端与接收端的不同绝对路径不单独制造正文冲突 |
| 本地回收 | schema v12 按历史、临时 lease、持久 publication 和同步重放依赖保留资产，只回收本机已无引用且可完整验证的托管文件 |

代码入口：[模型与预算](../native/Sources/ClipShelfCore/SyncOwnedFileModels.swift)、[文件同步存储](../native/Sources/ClipShelfCore/HistoryStore+OwnedSync.swift)、[私有协调器](../native/Sources/ClipShelfCore/SyncModels.swift)、[共享协调器](../native/Sources/ClipShelfCore/SharedBoardModels.swift)、[CloudKit 编码器](../native/Sources/ClipShelf/CloudOwnedBlobCodec.swift)、[私有适配器](../native/Sources/ClipShelf/CloudSyncService.swift)、[共享适配器](../native/Sources/ClipShelf/CloudSharedBoardTransport.swift)。

## 2. Wire v2 与身份

`SyncOperation` 增加可选 `formatVersion` 和 `ownedFiles`。无清单的旧 v1 保持缺省字段，解码后重编码不补写 `formatVersion: 1`，以保留旧 JSON hash；含清单的新操作显式使用 `formatVersion: 2`。未知版本、v1 携带清单、v2 缺清单、CloudKit 外层与 JSON 内层版本不一致都会拒绝。

文件清单结构为：

```swift
SyncOwnedFileDescriptor(digest: String, byteCount: Int, filename: String)
SyncOwnedFileBinding(partIndex: Int, representationIndex: Int,
                     digest: String, filename: String)
SyncOwnedFileManifest(version: Int, files: [SyncOwnedFileDescriptor],
                      bindings: [SyncOwnedFileBinding])
```

`digest` 是原件 SHA-256；`filename` 必须是通过校验的叶子名称。只有 registry 中的显式本地绑定或已验证的远端清单可以形成 ownership，路径相似、远端 UUID 和任意 file URL 均不是证明。

托管文件 part 在 wire 中规范化为一个 `public.file-url` 表示，其数据是 `clipshelf-owned://<digest>/<base64(filename)>` 内部 token。发送端旧路径、fallback、opaque 定位及预览表示不会跟随这个托管 part 到另一台 Mac；其他独立 parts 保留。该 token 只在 inbox 中等待物化，不能作为可用文件直接交给粘贴板。接收端生成自己的 asset ID 和 projection URL，并保存 `(scope, digest, filename) → localAssetID`，不会采用远端 asset ID 作为本机 registry 主键。

本机 `SyncOwnedFileScope` 包含真实账号、容器、database、zone owner、zone name 和 namespace。异步 `SyncTransferContext` 另外绑定 Store、账号配置 generation 和共享访问 generation。账号 A→B→A、共享权限或 descriptor 变化都会使旧上下文失效。只读状态查询不创建 context、不补发操作，也不发起网络请求。

共享云记录属于共享 zone，**不写上传成员的真实 account 字段**。共享 operation 的 namespace 为 `shared:<boardUUID>`；blob 另外校验容器、zone name 和 scope kind，完整 owner 由 `CKRecord.ID.zoneID` 及当前 descriptor 校验。拥有者看到的 `__defaultOwner__` 与接收成员看到的实际 owner 不会被写成相互矛盾的文件正文。本机缓存及上传确认仍包含实际当前账号和 database，不能借同一摘要跨账号、私有/共享或不同板复用授权。

## 3. CloudKit record 布局

operation 和 blob 是不同类型，所有文件名语义保留在 operation 清单中；同一 zone 内同摘要但不同文件名可共用 blob bytes。

| Record type / record name | 字段 | 校验与用途 |
| --- | --- | --- |
| `ClipShelfOperationV1` / operation UUID | `payload: CKAsset`、`sha256: String`、`account: String`、`formatVersion: Int`；v2 另有 `payloadByteCount: Int` | 私有不可变操作；名称保留 `V1` 以兼容旧记录，字段版本支持 1/2 |
| `ClipShelfSharedOperationV1` / operation UUID | `payload: CKAsset`、`sha256: String`、`namespace: String`、`formatVersion: Int`；v2 另有 `payloadByteCount: Int` | 共享不可变操作；不得含上传者 `account` |
| `ClipShelfOwnedFileV1` / `owned-<sha256>` | `sha256: String`、`byteCount: Int`、`chunkCount: Int`、`formatVersion: Int = 1`、`container: String`、`namespace: String`、`scopeKind: String`、`zoneName: String`、`chunk0: CKAsset`、可选 `chunk1: CKAsset` | 当前 zone 的不可变原件；scope kind 为 `private` 或 `shared`，摘要与长度针对完整原件 |

单个 chunk 至多 32 MiB，原件至多 64 MiB，因此每个 blob 有 1 或 2 个 CKAsset；空文件使用一个空 chunk。下载按顺序拼接、校验每段长度、总长度和完整 SHA-256。32 MiB 是实现采用的分块预算，不是已经验证的生产 CloudKit 容量承诺。

成功响应和 `serverRecordChanged` 重试都核对完整 record ID、type、版本、namespace/account、摘要及适用的长度字段。冲突响应的 CKAsset URL 可能不存在，因此上传幂等确认比较受约束 metadata；下载则必须拿到全部资产并验证实际字节。旧 operation ID 不能替换为不同 JSON 或不同清单。

change feed 的 `desiredKeys` 排除 `payload`、`chunk0`、`chunk1`，只取 metadata。operation 随后逐条显式读取 `payload`；blob 只在存在缺失依赖时显式读取 chunk。blob record 和删除事件按类型及 zone 分流：删除辅助 blob 不等价于删除用户记录，确实缺失的下载会保留为可重试失败；操作日志删除仍中止同步并保留本地内容。共享 CKShare 删除按撤权处理。

这避免依赖 CloudKit 临时文件长期存在。适配器在响应内用 regular-file、`O_NOFOLLOW` 和有界读取将字节复制到自身 staging；返回 `SyncOwnedFileStaging` lease 持有独立文件，Core 接受前再次校验。参考：[CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset)、[desiredKeys](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation/zoneconfiguration/desiredkeys)。

## 4. 事务、重试与预算

当前 API 包括：

```swift
makeSyncTransferContext(scope: SyncOwnedFileScope) throws -> SyncTransferContext
prepareSyncOwnedUpload(operationID: UUID, file: SyncOwnedFileDescriptor,
                       context: SyncTransferContext) throws -> PreparedSyncOwnedUpload
recordSyncOwnedUpload(operationID: UUID, file: SyncOwnedFileDescriptor,
                      context: SyncTransferContext, error: String? = nil) throws
pendingSyncOwnedDownloads(context: SyncTransferContext, limit: Int = 100,
                          excluding: Set<String> = []) throws -> [SyncOwnedDownloadRequest]
acceptSyncOwnedDownload(_ request: SyncOwnedDownloadRequest, stagedFileURL: URL,
                        context: SyncTransferContext) throws
syncOwnedTransferStates() throws -> [SyncOwnedTransferState]
```

`SyncOwnedFileTransport` 和 `SharedBoardOwnedFileTransport` 提供明确的 scope、upload 和 download 能力，后者始终带 board 参数。不具备文件传输能力的旧 transport 会明确报错并保留 durable inbox，不会借 cursor 已前进而宣称附件完成。

上传按操作级 bindings 读取不可变原件，绝不读取被外部 App 编辑过的 projection。从原件复制到独立 staging 期间持有数据库 writer 事务，避免另一连接的 GC 在旧 WAL 读快照仍引用原件时将其删除；返回后的网络等待由独立 staging lease 覆盖。每个文件的确认写入本地状态；适配器在发布 operation 前还会验证当前 zone 内的 blob metadata。单个文件失败、达到本轮预算、或 operation 发布失败都保留重试依据；独立的无依赖文本操作仍可继续。已发布 operation 的响应丢失后沿用原 ID 和 JSON hash 重试。

下载先持久化操作和 cursor，再逐文件验证及缓存。全部依赖齐备前，新记录不成为可粘贴记录；已有记录保持旧可用 revision。文件缓存、映射和 inbox 应用复用 Store 的事务和新资产回滚追踪：SQL/outbox/COMMIT 失败只回滚本次新建资产，不删除旧原件。远端 apply 不反向生成 outbox。墓碑、因果顺序和共享 accepted replay 仍由原同步逻辑处理；共享撤权后不能以旧 manifest 发起新的网络请求，失败草稿恢复为显式本地副本。

| 预算 | 当前值 |
| --- | --- |
| 单个原件 | 64 MiB |
| 每个操作的清单总字节 | 256 MiB |
| 每个操作的文件清单项 / 绑定数 | 各至多 64 |
| 每轮协调器文件传输预算 | 512 MiB，上传与下载合计；失败尝试也计入本轮预算 |
| 单个 CloudKit 文件 chunk | 32 MiB |
| operation JSON payload | 至多 256 MiB，沿用已有操作限制 |

这些是内容和传输预算，不是 RSS 或总磁盘占用上限。文件逐个流转；预算不足保留可见的 pending 状态，下一轮可继续。设置窗口显示当前作用域待上传、待下载、失败文件及原因，并提供显式重试；读取状态本身不启用同步、不查询账号、不产生补发。

## 5. 当前 schema v12、迁移与兼容

schema v11 新增 `owned_sync_operation_proofs`、`owned_sync_scopes`、`owned_sync_access`、`owned_sync_assets`、`owned_sync_transfers`、`owned_sync_backfill` 和 `owned_sync_local_recovery`，保留原有 `owned_file_assets`、`owned_file_bindings`、`owned_file_operation_bindings`。schema v10 的逐记录历史清理 token 继续保留。

从旧数据库升级前先创建 SQLite 与附件恢复包；迁移事务登记已有受信绑定的 backfill 标记，不扫描任意 URL 认领 ownership。真正进入用户已启用的同步后，只为当前 namespace、非 local-only、当前账号及可写共享内容生成新的因果后继 v2 操作。旧 outbox 的 operation ID 和 JSON bytes 保持不变；不能借补文件将 A 账号数据转给 B 账号，也不能为只读共享制造写操作。

旧 v1 URL-only 数据仍可解码，但没有发送端字节时不能恢复托管原件，不能读取远端给出的任意本机路径补造 ownership。对于已经有受信托管身份的内容，旧 peer 的 URL-only 更新不能静默清除该身份；正文和排序冲突以可移植语义及受信证明处理。

schema v12 新增 `owned_asset_leases`、`owned_asset_lease_roots`、`owned_asset_publications`、`owned_asset_publication_roots` 与 `owned_gc_journal`。同一资产最多有一条活动回收日志。升级前仍先创建恢复包；v12 前的 registry 资产全部登记 legacy external protection，因为旧版已经输出的文件 URL 没有 publication 记录，不能仅凭历史中已无记录推断外部 App 已不再使用。

逻辑备份继续为 archive schema 3：包含可移植原件和记录绑定，不导出云账号授权、同步队列或传输确认。物理数据库恢复包保留对应数据库状态与附件；直接克隆数据库与 owned 目录后 inode 可能改变，无法验证的 lease/journal 会保守保留，不承诺自动回收克隆资料库的全部旧状态。文件同步和本地回收都不意味着本地加密、iCloud 端到端加密或安全擦除。Paste 自身的文件保留细节仍待基线验证。

## 6. 本地托管资产占用与安全回收

存储管理只统计 owned 树内的原件、打开副本 projection 和回收隔离区 quarantine，不包括数据库、普通表示附件、OCR 缓存、导出缓存、独立备份或外部 Finder 原文件。逻辑字节与文件系统 allocated 字节分别显示；两者都不等于卷上最终可释放空间。扫描不完整时数值是已测到内容的下界，读取失败不能显示为零。未知、未注册目录计入占用并保留，不因“没有 registry”自动删除。

手动回收先生成当前 Store 绑定的冻结候选集，再确认执行。**自动本地回收默认关闭**；用户显式开启后，在启动、每小时及成功清理历史后复用同一 prepare/commit 路径，并避让正在进行的修改。关闭开关阻止新的自动提交；已提交的日志事务正常完成。读取占用不启用同步、不查询云账号。全资料库容量上限、写入空间 reservation 和配额准入仍属于后续完整容量管理，不由本轮实现冒充。

回收依据持久根和临时根共同判断：

- 历史、Pinboard 和普通记录里确实指向已登记托管文件的 URL；URL 引用只延长保留，不授予 ownership。
- Undo、Stack 队列及上一项、编辑、预览和已准备输出的 lease。解析文件与登记 lease 在同一个 writer 事务内完成；独立锁文件的进程锁证明活跃使用，进程结束释放锁，不按 TTL 推断任务结束。锁缺失或身份变化时继续保留。
- outbox/inbox 操作的不可变 bindings、已验证的部分下载、shared accepted replay 和失败草稿。只在不再被这些持久依赖使用时退役旧 private operation bindings，不能按“已经上传过”清空共享重放所需的原件。
- 已输出文件 URL 的持久 publication，包括剪贴板、drag、sharing 和 external open；输出调用返回和 App 退出都不代表接收者用完。

剪贴板 publication 跨重启保留。只有稳定且完整可读的当前粘贴板既不含该批 marker，也不含任一已发布 URL，才解除其保护；不确定读取继续保留。其他外部 publication 没有自动超时：存储管理完整列出用途与路径，用户确认外部 App 已不再需要这些文件后，按精确集合一次解除 external-open/sharing/drag/legacy 保护。该动作本身不删除文件，也不解除当前剪贴板和活跃 lease；随后必须重新准备回收范围。v12 前的 legacy protection 使用同一显式核对入口。

执行前再次核对两类账号 generation、全部根、原件摘要/长度和目录/文件的 device、inode、mtime、size。只有布局完整且原件与 projection 仍匹配受信内容的资产可以回收；外部修改过的 projection、额外文件、链接或异常目录保留为待处理，避免后台删掉未写回原件的外部编辑。

GC 先提交 durable planned 日志，再在第二个 writer 事务中核验自身全部日志仍为相同 token，才原子移动到 quarantine 并提交 registry 删除。同一资产的并发回收互斥；另一连接提前恢复/取消 intent 后，原调用必须失败，不能无日志移动文件。metadata 提交前失败或崩溃可按目录身份恢复；metadata 提交后才逐文件删除隔离内容。启动及“继续中断的回收”只恢复既有授权日志，即使自动回收关闭也可继续，不扩大到新的候选。未完成日志保留；结果只累计本次实际 unlink 的文件/字节，组数在日志完成事务提交成功后累计，重试不重复报告释放。

备份导出和同步上传在复制原件时持有 writer 事务，生成的独立备份与 staging 不属于 GC 候选。文件删除使用受控目录和 no-follow 身份检查，不递归清除未知内容，也不删除普通外部文件、独立备份或 CloudKit blob。统计/准备虽然在后台执行，仍可能持 writer 锁完成验证；大库实际响应延迟继续是验收项。

代码入口：[保留模型](../native/Sources/ClipShelfCore/OwnedStorageModels.swift)、[lease/publication](../native/Sources/ClipShelfCore/HistoryStore+OwnedRetention.swift)、[回收事务](../native/Sources/ClipShelfCore/HistoryStore+OwnedReclamation.swift)、[文件系统校验与隔离](../native/Sources/ClipShelfCore/OwnedFileReclamationStorage.swift)、[存储界面](../native/Sources/ClipShelf/StorageSettingsController.swift)。

## 7. 验证证据与发布 gate

本轮使用合成 CKRecord、临时文件、不同根目录的临时数据库和内存 transport，没有连接真实 Apple 账号。回归入口为 [OwnedFileSyncIntegrationTests](../native/Tests/ClipShelfCoreTests/OwnedFileSyncIntegrationTests.swift)、[CloudOwnedBlobCodecTests](../native/Tests/ClipShelfSyncTests/CloudOwnedBlobCodecTests.swift)、[CloudOperationCodecTests](../native/Tests/ClipShelfSyncTests/CloudOperationCodecTests.swift)、[CloudSharedTransportTests](../native/Tests/ClipShelfSyncTests/CloudSharedTransportTests.swift)。完整测试、构建与 CI 的最终证据以 [实现状态](IMPLEMENTATION_STATUS.zh-CN.md) 为准，不用定向通过代替全量验收。

现有用例覆盖：两库原件往返与重启、不可变旧 revision、失败/丢失响应重试、缺 blob 等待、提交失败回滚、不同账号的只读共享接收、账号 ABA、跨 scope 同摘要、accepted replay/失败草稿、下载与删除交错、排序与改名、v1 兼容和迁移补发。Cloud 编码器覆盖 64 MiB 原件分块、缺 chunk/坏摘要/长度、链接路径拒绝、独立 lease、共享 owner 别名、版本不一致、记录身份和 metadata-only 冲突确认。

本地回收回归入口为 [OwnedStorageCleanupTests](../native/Tests/ClipShelfCoreTests/OwnedStorageCleanupTests.swift)、[OwnedFileReclamationStorageTests](../native/Tests/ClipShelfCoreTests/OwnedFileReclamationStorageTests.swift)、[OwnedFilePublicationTests](../native/Tests/ClipShelfAppTests/OwnedFilePublicationTests.swift) 和 [OwnedFileStackRetentionTests](../native/Tests/ClipShelfAppTests/OwnedFileStackRetentionTests.swift)。覆盖临时库、独立进程锁、跨重启 publication、旧版保留迁移、modified/未知目录保留、双连接 intent 交错和 metadata/journal COMMIT 失败。历史 milestone 的数量和构建结论仅属于其对应 commit，不能沿用为当前 schema v12 的全量通过声明；当前统一回归、构建及 CI 结果仍以实现状态中的对应证据为准。

仍需完成：

1. 开发者自己的 CloudKit 容器、签名 entitlement 与 development/production schema 配置；上述 record types、字段类型及共享权限必须在真实环境核对并部署。
2. 同一真实账号的两台 Mac 私有同步，以及不同真实账号的共享拥有者/成员同步；验证 private/shared database、owner 别名和 readonly/revoke 行为。
3. 真实离线重连、账号切换、配额/网络错误、生产 CKAsset 多 chunk 上传下载、操作确认丢失和重启恢复。
4. 真实设置/存储窗口、待下载记录体验、大库扫描/回收响应与跨 App 文件输出；当前合成控制器测试不证明焦点、权限弹窗或接收 App 在退出/重启后的文件使用行为。
5. Developer ID、hardened runtime、notarization/stapling 和分发工件检查；当前 ad-hoc 开发包不是已签名公证的公开发行版。

这些 gate 仍然打开；本地协议实现和合成回归不能证明生产 CloudKit 的容量、服务端 schema 或真实双机体验。
