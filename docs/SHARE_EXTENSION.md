# macOS 入站分享扩展

状态：2026-10-09，实现及隔离测试阶段。代码提供 App + Share Extension 两个 Xcode target；完整 Xcode 构建与已签名扩展的宿主验收仍有下述门禁。本文对应 F15、[技术规格](TECHNICAL_SPEC.zh-CN.md) 和[产品动线](PRODUCT_FLOWS.zh-CN.md)。

## 用户动线

在支持系统分享的 App 中选择 ClipShelf，扩展读取分享项并显示目的地。用户必须选择「剪贴板历史」或一个可写目的板，再点击「保存到收件箱」。准备内容和切换目的地不会写入历史；取消会删除暂存内容。含已知机密、临时或密码管理器标记的分享整批拒绝。

保存成功表示内容已经提交到 App Group 的收件箱。ClipShelf 运行时负责导入；如果主应用已退出，内容等下次启动后导入。扩展不会声称已写入历史，也不会尝试强行启动主应用。导入失败保留内容与导入凭据供恢复。

以下入口有不同语义，不能互相替代：

| 入口 | 当前实现 |
| --- | --- |
| 其他 App 的系统「分享」→ ClipShelf | 本文的沙盒 Share Extension，确认目的地后提交收件箱 |
| 系统「服务」→ 保存到 ClipShelf | 主应用的 `NSServices` 接收流程 |
| ClipShelf 内「分享」到其他 App | 主应用的 `NSSharingServicePicker` |
| Shortcuts / App Intents | 主应用独立的三个自动化动作 |

Paste 公开页面明确介绍 iPhone/iPad 的分享入板；Mac 的具体宿主覆盖、目的板 UI 和错误行为尚未实测，不用该公开描述代替 Mac 对照验收。[Paste Pinboards](https://pasteapp.io/help/organize-with-pinboards)

## 工程结构

- `native/ClipShelf.xcodeproj`：ClipShelf App 和 ClipShelfShare.appex；App 的 Embed App Extensions 阶段嵌入扩展。
- App 使用同步文件夹引用 `Sources/ClipShelf`，复用现有原生源码；本地 Swift package 提供 `ClipShelfCore` 和 `ShareInboxShared`。
- 扩展使用 `Sources/ClipShelfShareExtension/ShareViewController.swift`，入口为 `ClipShelfShare.ShareViewController`，扩展点为 `com.apple.share-services`。
- `ShareInboxShared`：DTO、App Group 配置校验、暂存与原子发布、受限 `NSItemProvider` 读取。扩展不链接 Core、不打开历史数据库，也不读取 MCP 或云端凭据。
- `ShareInboxService`：仅主应用使用，统一通过 Core 的 `create` 事务导入。
- SwiftPM 的普通可执行文件构建不生成 `.appex`，入站分享的打包入口是 Xcode 工程。

扩展采用自定义 `NSViewController`。Apple 文档规定扩展通过 `NSExtensionContext` 取得输入并完成或取消请求；同组容器用于扩展与 containing app 交换文件，主应用可保持非沙盒。[创建扩展](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)、[共享容器](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)

## 主应用接入 API

```swift
let inbox = try ShareInboxService.configured(
    store: historyStore,
    privateDirectory: applicationDataDirectory
)
try await inbox.publishDestinations(allowImports: true)
let report = try await inbox.importPending()
// report.imported / report.alreadyImported: Int
// report.failures: [Failure(operationID: UUID, message: String)]
```

`configured` 从 Bundle 的 `ClipShelfAppGroupIdentifier` 读取组名，并要求当前进程的 `com.apple.security.application-groups` entitlement 包含该值。之后必须取得系统返回的 group container URL。缺少配置、未授权或容器不可访问时明确失败，不回退到猜测的 `~/Library/Group Containers` 或普通共享目录。

调用时机由主应用决定：启动、激活、目的板/账号/权限变化及有限频率检查。`publishDestinations` 缓存目录内容，只有账号、目的地或允许状态变化才重写；时间戳不触发重复写入。`allowImports: false` 发布空目的地并暂停该 actor 的导入，已排队内容保留。录制暂停与用户主动分享是不同意图，主应用分别处理；锁屏或会话暂停应暂停导入。

`importPending(retryUncertain: true)` 仅用于用户明确选择恢复。正常检查使用默认 `false`。没有 `cancel` API：主应用 actor 串行处理最多 100 个待导入操作，扩展自己的取消由 `ShareProviderLoader.cancel()` 与 `ShareInboxDraft.cancel()` 完成。

## 数据与可靠性边界

App Group 内只存放：

```text
ClipShelfShare/
  destinations.json       # 目的板名称、颜色、共享状态及账号绑定摘要
  Staging/<operationID>/  # 未确认的临时内容
  Inbox/<operationID>/    # 已确认的 manifest.json + 随机名 .data 文件
```

主应用私有目录另有 `ShareImports/<operationID>.json` 导入凭据、进程间锁，以及 `ShareImports/Files/<localRecordID>/` 的已接收文件。分享文件被复制到私有持久目录后，Core 保存该副本的文件 URL；删除 Inbox 不会使文件条目马上失效。

- 每次最多 20 项、总负载 64 MiB、每项最多 8 种表示；manifest / catalog 各最多 1 MiB。文件使用随机 UUID 名、大小和 SHA-256 校验，拒绝路径穿越、符号链接、重复表示和不支持的类型。
- 文字可保留 UTF-8、RTF、HTML；图片保留提供方表示；链接保留 URL 表示；文件内容复制而非依赖宿主临时 URL。目录、文件包及提供方无法读取的类型会明确失败，不递归采集。
- 优先 `loadFileRepresentation`，在其回调结束前受限读取临时文件；部分提供方仅支持 `loadDataRepresentation`，该路径在返回后检查大小。NSItemProvider 内部生成数据的瞬时内存分配不受本应用控制，不能将 64 MiB 负载限额描述为进程内存上限。[NSItemProvider 临时文件生命周期](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:))
- 暂存负载和 manifest 同步落盘，Save 时在同一容器内原子重命名为 Inbox 条目；取消及未完成读取不会发布半条 Inbox 操作。进程硬崩溃可能留下未发布的 Staging 目录，当前没有自动清理策略。
- 每个 Inbox 操作映射到主应用生成的新 UUID，凭据先于 `store.create` 落盘；不接受传入的记录 ID，也不使用采集去重 API `record()`，因此相同分享内容可保留多次。
- 已完成凭据使重复操作幂等；即使用户删除了导入记录，重复投递也不会使其重新出现。若进程中断导致「已尝试但缺少完成凭据、数据库中也无记录」，正常检查保留该操作，只有明确恢复才重新尝试。
- 每项独立事务；多项分享可能部分导入，凭据记录已完成项，恢复时继续剩余项。收件箱原子发布不等于多记录数据库整体事务。
- 账号绑定、当前目的板与共享写权限在导入时重验；Core 的 `create(_:expectedSyncConfiguration:expectedSharingConfiguration:)` 在同一事务验证两份完整账号配置（含 generation），防止检查后切号及 A→B→A 竞态。
- 旧账号私有板不会出现在新账号目录；只读、撤销或其他账号的共享板不可导入。写入共享板使用其共享 namespace，不同时加入私有历史；服务器最终拒绝后的失败草稿由现有共享同步层处理。
- 失败条目、导入凭据及文件副本没有自动过期清理；待产品明确保留规则后统一清理。备份及加密策略由主应用控制，App Group 收件箱本身没有额外应用层加密。

## 构建与签名配置

在具有完整 Xcode 的环境中执行：

```sh
xcodebuild -project native/ClipShelf.xcodeproj \
  -scheme ClipShelf -configuration Debug \
  -derivedDataPath /tmp/clipshelf-xcode-build \
  CODE_SIGNING_ALLOWED=NO build
```

该命令只验证无签名编译/嵌入结构，不等于扩展可安装和访问 App Group。当前机器执行到 Xcode 自身插件装载阶段即失败（exit 70），尚未进入项目编译：`IDESimulatorFoundation` 请求的 `DVTDownloads` 符号在 `/Library/Developer/PrivateFrameworks` 的已安装版本缺失。日志为 `/tmp/clipshelf-xcode-share.log`。将 Xcode 配套安装包仅展开到临时目录并设置该进程的 `DYLD_FRAMEWORK_PATH` 后仍失败；没有修改系统框架、运行安装器或登录 Apple 账号。此门禁解除后须重新执行完整命令，不能把单文件编译成功替代 Xcode 构建成功。

正式调试或分发须使用同一个开发团队、正确的 Bundle IDs 和可用 App Group，配置：

| 设置 | 用途 |
| --- | --- |
| `DEVELOPMENT_TEAM` | 签名团队，由维护者提供 |
| `CLIPSHELF_APP_GROUP_IDENTIFIER` | 维护者配置的合法组名，默认空值会明确禁用入口 |
| Info `ClipShelfAppGroupIdentifier` | 两个进程使用的同一组名 |
| `ShareExtension-App.entitlements` | 主 App 的 App Group entitlement 模板 |
| `ShareExtension.entitlements` | 扩展沙盒、用户选择文件只读、同一 App Group |

Xcode App target 通过 `INFOPLIST_KEY_ClipShelfAppGroupIdentifier` 合并现有 Info；扩展 Info 显式展开该 build setting。签名后的最终两个 Info.plist 和 entitlements 均须检查一致。已有 CloudKit 能力需要团队在 App 签名配置中同时保留对应云 entitlement，本模板不会替维护者创建云资源。不要把本地 ad-hoc 签名或手工创建同名目录当作 App Group 授权已经验证。[Apple App Groups 配置](https://developer.apple.com/documentation/xcode/configuring-app-groups)

## 验证记录与待验

已完成的隔离验证：

- SwiftPM 编译 `ShareInboxShared`、`ClipShelf`；扩展源码通过 `swiftc -typecheck -application-extension`。
- Xcode 工程、Info 与 entitlements 的 `plutil -lint` 通过；尚无完整 `xcodebuild` 成功证据。
- `ShareInboxTests` 使用临时数据库、临时容器和合成 `NSItemProvider`，覆盖取消、确认门禁、机密标记、大小限制、相同内容多次分享、删除后的幂等重投、文件持久化、损坏/符号链接/路径穿越、账号与暂停、共享权限及原子账号检查。最终测试数量与结果以本轮根任务的完整测试报告为准。
- 未读取真实剪贴板或用户历史，未安装或注册真实扩展。

签名条件具备后须验：Finder/Safari/Notes 等宿主的扩展可发现性；纯文本/链接/RTF/HTML/图片/单文件与多文件；目标板选择；慢提供方取消与宿主退出；主应用已退出后保存及重启导入；账号切换/共享撤权；真实 App Group 双进程可访问性；合成文件成功之外的宿主格式差异；App Intents 与扩展同时嵌入的签名及元数据。每项都需记录 OS、Xcode、App 版本和证据，不从当前隔离测试推断已通过。
