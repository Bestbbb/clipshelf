# 托管文件跨 Mac 同步提案

状态：**提案，尚未实现**。代码审计基线为 `469ca0d`（2026-10-10）。本文件不改变 TECHNICAL_SPEC 中 F16 的目标或当前完成状态，也不属于本轮 F06 图片输出与指定 App 打开实现。

## 1. 结论与边界

当前同步会传输 `ClipboardRecord.parts` 中已有的图片、RTF、HTML 等表示字节，但托管文件只传其 `public.file-url` 路径。CloudKit 的 CKAsset 目前封装整个操作 JSON，**不是该路径指向的托管原件**。另一台 Mac 因此不能恢复文件字节或取得本地托管绑定。

建议独立一轮实施「已明确登记的托管原件同步」：数据库 schema v11（待实施）、带文件清单的 wire v2、私有及共享 zone 内的独立文件 CKAsset、持久附件待下载状态、本机路径物化，以及冲突比较和历史协议兼容。schema v10 已用于本地历史清理的逐记录变更标记，不包含云资产实现。普通 Finder 文件仍是引用，不自动复制、读取或上传其内容；外部 App 对打开副本的编辑也不自动替换原件或触发上传。

该轮可在无真实 Apple 账号的条件下完成 Core、两种 CloudKit 适配器和合成双库回归；真实两 Mac、生产容器、签名 entitlement、容量和撤权验收仍是独立发布 gate。不能因合成测试通过就宣称 F16 全部完成。

## 2. 已核实的数据流

| 环节 | 当前实现 | 必须补齐 |
| --- | --- | --- |
| 本地持久化 | `RepresentationStorage` 把表示的 Data 保存为摘要命名的 blob；file URL 表示保存的是 URL 字符串 | 区分表示字节和文件内容，不能把 URL 的 blob 当作文件原件 |
| 托管原件 | `OwnedFileStorage` 保存不可变 `payload` 及可编辑 `files/<filename>`；本地 registry 显式登记槽位 | 上传只能安全读取并校验 `payload`，不能读取已被外部编辑的 projection |
| outbox | `enqueueSyncOperation` 保存不可变 `SyncOperation` JSON；`owned_file_operation_bindings` 另存本地槽位证明 | 将受信证明变成可移植、不可变的文件清单；保存上传进度与依赖 |
| 私有/共享 CKAsset | `payload` 字段是 JSON 文件，`sha256` 校验该 JSON；当前 formatVersion=1 | 新文件 blob 的字节、摘要、名称、作用域及完成状态 |
| inbox/apply | 远端 JSON 进入 durable inbox；因果父操作/板存在后直接 insert 或 replace；cursor 同事务提交 | 还须等待所需文件验证完成，生成本机资产与路径，并登记绑定 |
| 共享缓存重放 | 目前仅本机创建过的操作有 ownership snapshot，远端 URL 不取得 ownership | 已验证下载文件的受信映射也需支持 accepted replay、只读降权与失败草稿 |
| 冲突判断 | `isOrderingOnlyConflict` 使用包含表示 Data 的内容比较 | 同一原件在两台 Mac 的不同绝对 URL 不能制造内容冲突 |

代码入口：[SyncModels](../native/Sources/ClipShelfCore/SyncModels.swift)、[同步存储](../native/Sources/ClipShelfCore/HistoryStore+Sync.swift)、[托管绑定](../native/Sources/ClipShelfCore/HistoryStore+OwnedFiles.swift)、[共享存储](../native/Sources/ClipShelfCore/HistoryStore+Sharing.swift)、[私有适配器](../native/Sources/ClipShelf/CloudSyncService.swift)、[共享适配器](../native/Sources/ClipShelf/CloudSharedBoardTransport.swift)。

## 3. 协议与身份

以下类型与签名是待实施的接口契约示意，不是当前 API。

```swift
struct SyncOwnedFileDescriptor: Codable, Equatable, Sendable {
    let digest: String       // 原件 SHA-256，作为当前云作用域内的 blob key
    let byteCount: Int
    let filename: String    // 校验后的叶子名称，不含目录或绝对路径
}
struct SyncOwnedFileBinding: Codable, Equatable, Sendable {
    let partIndex: Int
    let representationIndex: Int
    let digest: String
    let filename: String
}
struct SyncOwnedFileManifest: Codable, Equatable, Sendable {
    let version: Int
    let files: [SyncOwnedFileDescriptor]
    let bindings: [SyncOwnedFileBinding]
}
// SyncOperation 增加可选 ownedFiles 清单；旧 v1 解码为 nil。
```

- 仅本地显式登记绑定或已经验证的远端清单可以产生该字段。文件 URL、任意远端 UUID、相似目录名均不是 ownership 证明。
- wire 中绑定槽位使用明确的内部文件 token，不携带发送设备的受控绝对路径；普通外部引用保持原语义。wire token 不能直接交给 NSPasteboard。
- 同一文件对象的 URL aliases 必须一致；旧路径 fallback、预览及 opaque 文件定位表示不能让接收 App 选中发送端的旧文件。实现须制定并测试明确的文件 part 规范化策略，保留其他 parts；不应仅替换一个槽位后留下互相矛盾的表示。
- blob key 只在当前私有库或单个共享 zone 内去重。作用域至少包含真实账号、容器、私有/共享标识，以及共享 zone owner/name；不能只靠 `shared:<boardUUID>` 跨账号复用缓存或授权。
- 本地生成全新的 `OwnedFileAsset.id`，持久保存 `(scope, digest, filename) → localAssetID` 映射。不能直接把远端资产 ID 当作本机 registry 主键。
- 同步内容等价性按「绑定槽位、名称、长度、摘要、其他表示内容」比较；本机投影路径、localAssetID 不属于跨设备正文。普通编辑/排序继续保留原件绑定，纯排序不得创建内容冲突副本。

## 4. Core 与 transport 接口

建议保留现有普通 `SyncOperation` 因果、墓碑与 namespace 契约，增加以下能力。所有异步结果提交均携带开始时的配置 generation；共享还需 descriptor/当前读写权限校验。

```swift
// opaque 准备态持有独立私有 staging 文件；生命周期覆盖网络请求。
func prepareSyncOwnedUpload(operationID: UUID,
                            context: SyncTransferContext) throws -> PreparedSyncOwnedUpload
func pendingSyncOwnedDownloads(context: SyncTransferContext,
                               limit: Int) throws -> [SyncOwnedDownloadRequest]
func acceptSyncOwnedDownload(_ request: SyncOwnedDownloadRequest,
                             stagedFileURL: URL,
                             context: SyncTransferContext) throws
func syncOwnedTransferStates(context: SyncTransferContext) throws -> [SyncOwnedTransferState]
```

`SyncTransferContext` 绑定真实账号、完整作用域、私有/共享配置 generation。准备态、下载请求由 Core 创建且不可由外部任意伪造；stagedFileURL 始终视为未信任输入，提交前重新检查长度、摘要、regular file 与路径安全。

私有 `SyncTransport` 与 `SharedBoardTransport` 分别增加文件上传/下载方法，后者保留 board 参数，避免误用私有 zone。返回成功必须核对完整作用域、blob identity 和摘要；不允许旧适配器通过默认空实现忽略文件依赖。内存 transport 同样模拟文件失败、重试与权限变化。

### 上传

1. 内容/清单/local bindings/outbox 在同一事务内固定，之后不根据当前记录重新拼装旧操作。
2. 按操作的本地受信绑定读取原件并校验 SHA；复制到独立 staging，禁止直接上传可编辑 projection，也不能以当前记录替代旧 revision 的原件。
3. 先上传当前作用域的不可变 blob，确认摘要一致；再发布引用这些 blob 的不可变 operation record。操作确认丢失后，只认可相同 ID、作用域、manifest 和 payload hash。
4. 某个文件失败时该 revision 不发布为远端可用；其他无依赖操作仍可推进。上传日志和错误可重试，切账号或共享降权后拒绝继续提交旧上下文。

### 下载与物化

1. 增量拉取 operation 元数据/清单；持久保存到 inbox 后才推进 cursor。附带的 blob 辅助记录需按 record type 分流，不能当作操作解码。
2. 缺文件的操作标记 `pending/downloading/failed`，显示已知条目/待下载状态；不能让不存在的本机 URL 成为可粘贴内容。旧 revision 已可用时保留旧版，同时显示更新未完成。
3. 附件逐个下载到受控 staging 并校验；进程重启仍从持久 inbox/传输状态继续，不能依赖 CloudKit 临时 URL。官方说明 CKAsset 临时文件会被系统回收，并支持通过 desiredKeys 排除资产字段以先取得元数据。[Apple CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset)、[desiredKeys](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation/zoneconfiguration/desiredkeys)
4. 全部依赖就绪后，在同一事务内创建本机资产、改写文件槽位、登记 bindings、应用冲突/排序/墓碑与新 revision，并完成 inbox 操作。远端 apply 不反向生成 outbox。
5. 复用 `HistoryStore.transaction` 的新资产目录跟踪：包括 outbox flush 或 COMMIT 失败，都只能删除本次新建目录，不能删除旧原件。失败不产生半个可用条目。
6. 共享 accepted replay 与失败草稿必须携带已验证资产映射；权限撤销不能靠旧 manifest 继续网络读写。恢复本地失败草稿是显式本地副本，不自动重发。

使用独立 blob record 可让多次排序/改标题复用同一文件，而不为每次完整操作重复上传原件。现有 zone 拉取会拒绝所有记录删除；新实现需区分操作日志缺失与 blob 不可用，后者进入附件失败状态，不能解释成删除用户内容。

## 5. 数据库、兼容与迁移 gate

建议后续 schema v11 新增（当前 v10 已用于本地清理变更标记）：

- 操作级不可变 manifest/传输版本记录，与 outbox 同事务生成。
- namespace 隔离的已验证资产映射与下载状态表。
- 待补发旧已同步托管记录的标记，避免迁移时扫描 URL 自动认领资产。

保留 `owned_file_assets`、`owned_file_bindings`、`owned_file_operation_bindings` 的本地证明用途；补足 scope 外键/关联校验。逻辑备份继续只导出可移植原件与记录绑定，不导出云上传授权、账号队列或设备配置；物理数据库回退包应保留新表及其资产。

必须通过以下兼容 gate：

1. **旧 operationID 与 JSON hash 不可变。** 已发布/可能已发布的 v1 操作不能追加文件字段后用原 ID 重试；否则 CloudKit 同 ID 冲突无法幂等确认。
2. 新建含托管清单的操作使用 wire v2；无清单 v1 继续支持。未知 wire 版本明确拒绝，不能旧客户端忽略新字段后将 token 当普通可用文件。
3. 既有托管记录需按当前账号和可写共享权限生成新的因果后继 v2 操作；不可改写旧日志，不能把 A 账号内容借 B 账号重新上传。只读共享不能以补文件为理由生成写操作。
4. 升级时先建迁移回退包。不开启任何云传输，也不扩大已有同步范围；补发只处理已有 namespace 归属和显式允许同步的内容。
5. 旧远端 v1 文件 URL 无字节时保持引用/不可用状态；没有发送端原件就不能补造恢复成功，也不得打开远端传来的任意本机路径来“补文件”。
6. 同一内容跨设备路径差异、旧 peer 缺 manifest、正文与排序交错须有明确合并规则。旧 peer 的 URL-only 更新不能静默清除已验证托管身份；不可判定时保留冲突/待升级状态。
7. 新增文件大小/数量/批次预算要公开且预检。沿用现有单原件 64 MiB 上限，文件逐个流转，另设显式的总预算；不能在现有 100 操作批次中额外一次加载全部文件，也不能先做无界 Base64 编码后才限额。

这些 gate 意味着实现不仅涉及两处 CKAsset 赋值：Core 的操作比较、冲突副本、shared cache replay、撤销所需绑定和旧版本迁移必须一并覆盖。

## 6. 实施边界与验证

可并行分工：Core 负责模型/schema/清单与待下载状态/物化/语义比较；私有适配器负责私有 zone blob 与分阶段拉取；共享适配器负责共享 zone 隔离及每次请求的服务端权限；App 只接可用/待下载/失败状态和重试。独立提交，勿与当前 F06 输出改动混合。

最低回归集合：

- 两个不同根目录的合成资料库，同一托管记录往返、重启、重复拉取后原件 bytes 相同、本机 URL 不同、绑定完整且不产生重复条目。
- 缺 blob、错误摘要/长度、非法 filename/槽位、symlink、越作用域请求及重复 digest 矛盾全部拒绝；失败不提前推进可用 revision。
- 上传完成但 operation 未发布、operation 已发布但确认丢失、下载中断/重启、游标已提交但文件尚未就绪均可恢复。
- 纯排序、改标题、正文并发编辑、删除与下载交错、整板删除后的冲突副本均保留正确文件与墓碑语义。
- 本地原件与被外部编辑的 projection 不混淆；普通 Finder 引用和恶意远端路径从不取得托管资格。
- 私有 A→B→A、两个共享板/账号同 digest、只读/撤权、accepted replay/failed draft 本地恢复，以及私有板转共享副本不跨作用域借用上传确认。
- v1/v2 混合、未知版本、旧 outbox 不改写、补发新 ID、旧记录无原件不可恢复、迁移/COMMIT 失败的文件和数据库回退。
- CloudKit record/CKAsset 编码解码可用本地合成记录测试；真实容器与两 Mac 断网重连另行验证，不能以 mock 覆盖声明替代。

本轮仅完成上述只读审计与提案，没有修改同步协议、数据库 schema、云记录或用户数据。
