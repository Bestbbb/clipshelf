# ClipShelf 改进规格：核心可用、内存可控、模块可裁

版本：2026-10-11 v1。适用基线：提交 `d7b5e60`。
背景见[复刻失败独立梳理](CORE_FLOW_DIAGNOSIS.zh-CN.md)；本文只写要做什么、怎么做、怎么验收，供实现者直接领任务。

## 0. 结论与范围

### 0.1 产品形态：保留菜单栏 app

保留独立的菜单栏 app，不改为 Raycast / Alfred 插件。理由：

- Paste 的三个本质能力只有独立进程做得到：系统级全局热键、不抢前台的非激活面板、通过辅助功能把 ⌘V 送回原应用。插件宿主只能给其中一部分，并且不受我们控制。
- 现有 `native/` 的采集、存储、搜索、面板都已经是可复用资产，缺的是“可控”和“瘦”，不是推翻重写。
- 插件路线作为**兜底**保留：`ClipShelfCore` 拆分完成后（见 W2），任何人都可以用它写一个读同一个 SQLite 库的 Raycast 扩展，不需要本规格额外安排。

### 0.2 目标

| 维度 | 现状（2026-10-10 实测） | 目标 |
| --- | --- | --- |
| 核心链路 | 物理热键唤起到回填从未经用户验收 | 第 5 节六步验收连续 10 次通过 |
| 空闲内存（physical footprint） | 149 MB，峰值 228 MB | 空闲 ≤ 60 MB，面板打开 ≤ 120 MB |
| 空闲 CPU | 0.1% | 维持 ≤ 0.5% |
| 可执行文件 | 9.6 MB | 核心构建 ≤ 5 MB |
| 失败可诊断性 | 日志被测试刷掉，最后一次失败无证据 | 任一失败都能在诊断面板中看到原因 |
| 测试副作用 | 泄漏 1,770 个 plist 到 `~/Library/Preferences` | 跑完测试该目录文件数不变 |

### 0.3 非目标

本规格不新增任何面向用户的功能；不改 CloudKit、MCP、Sparkle、分享扩展的行为，只把它们移到可选模块；不处理 iOS。

### 0.4 阶段与门槛

| 阶段 | 工作项 | 门槛 |
| --- | --- | --- |
| P1 核心可用 | W1.1 到 W1.6 | 第 5 节六步验收由非开发者在真实键盘上连续通过 10 次 |
| P2 模块与内存 | W2.1 到 W2.6 | 0.2 节内存与体积目标达成，P1 验收不回退 |
| P3 工程卫生 | W3.1 到 W3.4 | CI 绿，测试零副作用 |

P1 未通过门槛前，不开始 P2；任何阶段都不新增功能。

## 1. P1：核心链路可用与可控

### W1.1 粘贴严格度开关

**问题。** `PasteCoordinator.waitAndDispatch` 在发出 ⌘V 前要求七项条件全部成立：权限、进程存活、有窗口、目标在前台、修饰键全部松开、AX 焦点窗口 `CFEqual`、AX 焦点元素 `CFEqual`，最近一次提交又追加了 AX 选区范围相等（`differentSelection`）。任一不满足就降级为“已复制”。Paste 本身只做“激活目标，发送 ⌘V”。

**改动。**

1. 在 `PasteEnvironment.swift` 新增：
   ```swift
   enum PasteStrictness: String, Codable, CaseIterable, Sendable {
       case compatible   // 默认：激活、提升窗口、恢复焦点（尽力）、发送 ⌘V；不以 AX 相等作为拒绝条件
       case strict       // 现有行为
       case copyOnly     // 只写剪贴板，不发送按键
   }
   ```
2. `PasteCoordinator` 增加 `var strictness: PasteStrictness`，由应用从偏好键 `pasteStrictness` 读取，默认 `compatible`。
3. `compatible` 模式下的 `waitAndDispatch`：
   - 保留：权限、进程存活、目标在前台、修饰键松开、剪贴板 `changeCount` 未变、0.9 秒截止。
   - 降级为日志：`focusState` 的 `differentWindow / differentElement / differentSelection` 只写 trace，不改变流程。
   - `restoreFocusedElement` 仍调用，但 `kAXSelectedTextRangeAttribute` 写回失败不影响后续。
   - `focusSettleInterval` 从 80 毫秒降到 40 毫秒。
4. 按应用覆盖：偏好键 `pasteStrictnessOverrides: [String: String]`（bundle ID 到模式）。`PasteCoordinator.paste` 入口按 `target.application.bundleIdentifier` 查表。
5. 设置界面：在 `ShortcutSettingsController` 现有窗口底部增加一个三选一的 `NSPopUpButton`，以及“为当前目标应用单独设置”的入口（显示上次捕获的目标名）。

**验收。** 新增 `PasteCoordinatorTests` 用例：在内存环境中让 `focusState` 返回 `differentSelection`，`compatible` 下仍得到 `.dispatched`，`strict` 下得到 `.copiedOnly`。真实桌面：对微信、VS Code、Chrome 各做一次回填，`compatible` 全部通过。

### W1.2 AX 调用超时

**问题。** 全仓库没有 `AXUIElementSetMessagingTimeout`。`PasteSystemEnvironment.snapshot`、`focusState`、`destinationChoices` 都在主线程做 AX 读取，一个无响应的目标进程会让面板卡住最长 6 秒。

**改动。**

1. `PasteSystemEnvironment` 增加私有工厂：
   ```swift
   private static func application(_ pid: pid_t) -> AXUIElement {
       let app = AXUIElementCreateApplication(pid)
       AXUIElementSetMessagingTimeout(app, 0.25)
       return app
   }
   ```
   所有 `AXUIElementCreateApplication` 调用点改走该工厂；`AXUIElementCreateSystemWide()` 同样设置 0.25 秒。
2. `destinationChoices()` 不再在 `performTogglePanel` 中预先对全部运行应用做快照。改为：
   - 面板打开时只填充应用名称与 PID 列表（`NSWorkingApplication` 数据，无 AX 调用）；
   - 用户在下拉中选中某一项时，才对该 PID 做一次 `snapshot`，失败则提示“该应用当前没有可粘贴的窗口”。
3. `ValidationTrace` 新增事件 `ax_timeout`，`AXUIElementCopyAttributeValue` 返回 `.cannotComplete` 时记录。

**验收。** 用一个 `kill -STOP` 挂起的 TextEdit 作为前台应用，按热键，面板必须在 300 毫秒内出现，trace 中有 `ax_timeout`。

### W1.3 删除 PasteClickShield，改为点击计数过滤

**问题。** `PasteClickShield.swift` 用一个 12×12、透明度 0.01 的浮动窗口吞掉双击的第二下。它依赖 WindowServer 命中测试细节，在 Stage Manager、录屏、辅助工具下不可预期。

**改动。**

1. 删除 `PasteClickShield.swift` 与 `PasteClickShieldTests.swift`，移除 `ClipShelfApplication.pasteClickShield` 与 `panel.onCardPasteClick`。
2. `ClipboardCardView` 的 `mouseUp` 保持“首次抬起即触发 `onOpen`”，`clickCount >= 2` 直接返回（现已如此）。
3. 在 `PasteCoordinator.paste` 中，`dismiss()` 之后、`activate` 之前，若 `environment.uptime - request.startedAt < NSEvent.doubleClickInterval`，等待到该间隔结束再激活目标。这样第二次点击落在仍然可见的面板上，被 `clickCount` 过滤，不会落到目标输入框。
4. 删除 `ValidationTrace` 中 `paste_click_shield_*` 事件。

**验收。** 在 TextEdit 中快速双击卡片，文档只出现一份内容，且光标位置没有被鼠标点击移动。

### W1.4 诊断面板

**问题。** 热键注册失败只写进打不开的面板；粘贴失败原因只在统一日志，而日志已被测试刷掉。

**改动。**

1. 新建 `DiagnosticsController.swift`，一个普通 `NSWindow`，从菜单栏菜单的“诊断…”打开。显示：
   - 热键：`GlobalShortcutCoordinator.activeBindings` 与 `shortcutRegistrationFailures`，每项标“已注册 / 失败（OSStatus）”。
   - 权限：`AXIsProcessTrusted()` 结果，以及“打开系统设置”按钮。
   - 最近 20 次粘贴：时间、目标 bundle ID、`Outcome`、`Failure`、模式（menu / keyboard）、耗时。
   - 当前严格度与按应用覆盖表。
   - “复制诊断文本”按钮：把以上内容与 `ProcessInfo` 的 footprint（见 W2.6）拼成纯文本写入剪贴板，不含任何剪贴板内容、窗口标题或路径。
2. 新建 `PasteOutcomeLog`（环形缓冲，容量 20，仅内存），`PasteCoordinator.finish` 每次写入一条。
3. 热键注册失败时，除状态栏外，用 `NSUserNotification` 的替代 `UNUserNotificationCenter` 发一条本地通知，并把菜单栏图标改为带感叹号的变体。
4. `--diagnostic-trace` 保持不变。

**验收。** 手动把 ⌘⇧V 让系统占用（例如在另一应用中注册），启动 ClipShelf，10 秒内收到通知，诊断面板显示失败项与状态码。

### W1.5 热键注册失败的自动回退

**改动。** `GlobalShortcutCoordinator.start` 返回失败时，依次尝试备选组合 `⌃⇧V`、`⌥⇧V`、`⌘⇧space`，第一个成功的写回偏好并在通知中告知“已改用 ⌃⇧V”。用户可在设置中改回。

**验收。** 占用 ⌘⇧V 后启动，面板可用 ⌃⇧V 唤起，诊断面板显示当前绑定。

### W1.6 捕获与回填链路的端到端 trace 汇总

**改动。** 新增 `scripts/summarize-trace.py`：读取 `--diagnostic-trace` 的 stderr 输出（JSON 行），按一次 `invocation` 到 `paste_completed` 为一组，输出每组的：入口（hotkey / reopen / menu）、目标 bundle、各阶段耗时、最终 `state` 与 `failure`。输出为 Markdown 表格。

**验收。** 第 5 节的验收记录必须附这个脚本的输出，而不是测试数量。

## 2. P2：模块拆分与内存预算

### W2.1 SwiftPM 目标拆分

**现状。** `ClipShelf` 可执行目标 94 个文件 20,674 行，所有能力一起编译、一起初始化。

**目标结构。**

| 目标 | 内容 | 来源文件（现 `native/Sources/ClipShelf/`） |
| --- | --- | --- |
| `ClipShelfCore`（已有） | 存储、搜索、配额、同步数据层 | 不变 |
| `ClipShelfCapture`（新） | 轮询、快照、入库 | `CaptureService` `CaptureIngestionCoordinator` `CapturePersistence` `ClipboardCaptureSnapshot` `ClipboardCodec` |
| `ClipShelfPaste`（新） | 目标捕获、就绪检查、派发、Stack | `PasteEnvironment` `PasteCoordinator` `PasteTargetHistory` `PasteLaunchPolicy` `PasteMenuCommand` `PasteFeedbackController` `StackCoordinator` `StackKeyMonitor` `StackPasteGestureCoordinator` `GlobalHotKey` `GlobalShortcutCoordinator` `KeyboardShortcutConfiguration` |
| `ClipShelfShelf`（新） | 面板与卡片 | `ClipboardPanelController` `ClipboardCardView` `PinboardTabStrip` `Panel*` `HistoryFilter*` `HistoryPageQueryCoordinator` `ShelfStatusLabel` `*PreviewController` |
| `ClipShelfExtras`（新，可选） | CloudKit 同步与共享、MCP、OAuth、Sparkle、OCR、智能建议、分享收件箱、Shortcuts、加密备份、存储管理界面 | `Cloud*` `MCP*` `Sparkle*` `Update*` `LocalIntelligenceService` `ContextSuggestionService` `SuggestionPanelController` `OCRDerivedCache` `ShareInboxService` `ClipboardIntents` `EncryptedBackupService` `StorageSettingsController` `SharingSettingsController` |
| `ClipShelf`（可执行） | `main.swift`、`ClipShelfApplication`、`RuntimeProfile`、菜单、设置窗口装配 | 其余 |

**做法。**

1. `Package.swift` 增加编译条件：`ClipShelf` 目标在 `swiftSettings` 中加 `.define("CLIPSHELF_EXTRAS", .when(configuration: ...))` 不够灵活，改为环境变量驱动：构建脚本读 `CLIPSHELF_EXTRAS=1` 时把 `ClipShelfExtras` 加入依赖并传 `-DCLIPSHELF_EXTRAS`。`scripts/build-macos.sh` 默认不带。
2. `ClipShelfApplication` 中所有 Extras 调用点包进 `#if CLIPSHELF_EXTRAS`；Extras 向主程序注入的接口统一为一个协议 `ExtrasRegistry`（提供菜单项、设置窗口、`onRecordSaved` 钩子），核心只依赖协议。
3. 先按上表机械移动文件、修 `import`，不改逻辑；每移一个目标跑一次 `swift build`。
4. Sparkle 依赖只在 Extras 目标声明，核心构建不下载、不嵌入框架。`scripts/embed-sparkle.sh` 在无 Extras 时跳过。

**验收。** 不带 Extras 的 `build-macos.sh` 产出 ≤ 5 MB 可执行文件，`otool -L` 不含 Sparkle；带 Extras 的构建行为与现在一致。CI 两种配置都跑。

### W2.2 延迟创建重服务

**问题。** `ClipShelfApplication` 第 53 行 `private let intelligence = LocalIntelligenceService()`、第 58 行 `ContextSuggestionService()` 在应用对象创建时就实例化；每张图片采集后 `scheduleOCR` 立刻跑 Vision。堆上常驻 1.7 万个 CoreML（Espresso）对象。

**改动。**

1. 两个属性改为 `private lazy var`，并随 W2.1 进入 Extras。
2. OCR 改为偏好键 `ocrEnabled`，默认 `false`；开启后在设置中提示“会增加内存占用”。
3. `scheduleOCR` 改为批处理：面板关闭后 30 秒内空闲再处理队列；每批处理完调用 `LocalIntelligenceService.releaseModels()`（新增，置空 `VNRecognizeTextRequest` 与相关缓存）。
4. `ImagePreviewController.recognizer`、`ContextSuggestionService` 内部的 `LocalIntelligenceService()` 同样改为按需创建、用后释放。

**验收。** 关闭 OCR 时，`heap` 输出中不出现 `Espresso::` 类；开启并处理 10 张图后 60 秒，`Espresso::` 对象数回到 0。

### W2.3 本地化只加载当前语言

**问题。** `L10n.swift` 的 `read(directory:)` 读入全部 16 个 `catalog-*.json` 并解析为字典，堆上约 8 万个 `CFString`。

**改动。**

1. `LocalizationCatalogFiles` 只读 `InterfaceLanguage.current` 与 `en`；其余语言在 `LanguageSettingsController` 预览时按需读取并在窗口关闭后释放。
2. 字典解析结果缓存一份，不保留原始 `Data`。
3. `scripts/localization-audit.py` 继续在构建期校验全部 16 份文件，不依赖运行时加载。

**验收。** 启动后 `heap` 的 `CFString` 计数下降至少 5 万；切换语言并重启后界面正确。

### W2.4 面板内存释放

**改动。**

1. `ClipboardPanelController.thumbnailCache.totalCostLimit` 从 32 MiB 降为 8 MiB；`dismiss()` 与 `hidePreservingDraft()` 末尾调用 `thumbnailCache.removeAllObjects()`。
2. `records` 只保留 `ClipboardRecordMetadata`，正文和表示在卡片可见时按需读取（`HistoryPageQueryCoordinator` 已支持分页，补“可见范围预取”）。
3. 面板关闭 60 秒后，`NSCollectionView` 的 item 复用池用 `resultsView.reloadData()` 清空；`inlineRecords.removeAll()`。
4. 检查并移除对 SwiftUI 的链接（`otool -L` 当前包含 SwiftUI，确认来源后替换为 AppKit 实现或移入 Extras）。

**验收。** 打开面板浏览 300 条含 50 张图片的记录后关闭，60 秒后 footprint 回到空闲值 ±5 MB。

### W2.5 采集预算下调

**改动。**

1. `ClipboardCodec.snapshot` 单次总字节预算从 64 MiB 降为 16 MiB（偏好键 `captureBudgetMiB` 可调）。
2. 超过预算的表示类型只记录类型标识与字节数，不读取内容；面板中对应卡片标“仅记录类型”。
3. 轮询间隔保持 0.3 秒；`CaptureService.poll` 中 `declaredTypes()` 之前先比较 `changeCount`，避免每 0.3 秒枚举一次 `pasteboardItems`（当前已先比 `changeCount`，保持）。

**验收。** 复制一张 40 MB TIFF，进程 footprint 增量 < 20 MB，历史中出现该条目且标注类型。

### W2.6 内存预算与自动回归

**改动。**

1. 新增 `MemoryFootprint.swift`：用 `task_info(TASK_VM_INFO)` 读取 `phys_footprint`，供诊断面板与 `--memory-report` 参数使用（启动完成 5 秒后打印一行 JSON 到 stderr 并退出）。
2. CI 增加一步：`open build/ClipShelf.app --args --demo --memory-report`，断言空闲 footprint ≤ 60 MB（Extras 关闭）与 ≤ 110 MB（Extras 开启）。超限则构建失败。
3. 预算数值写在 `scripts/memory-budget.json`，调整需在 PR 中说明。

**验收。** CI 两种配置均输出 footprint 且在预算内。

## 3. P3：工程卫生

### W3.1 测试零副作用

**问题。** `~/Library/Preferences` 有 1,770 个测试遗留 plist（`ClipShelf.cleanup-tests.*` 556、`clipshelf-language-tests.*` 253、`io.github.bestbbb.clipshelf.validation.*` 41 等）。测试里 `UserDefaults(suiteName:)` 与 `removePersistentDomain` 数量相当，泄漏来自被中断的运行与 `--validation` 启动。

**改动。**

1. 新增协议 `PreferencesStore`（`bool(forKey:)`、`set(_:forKey:)`、`data(forKey:)`、`removeObject(forKey:)`），`UserDefaults` 扩展实现之；测试用内存字典实现，不再创建任何 suite。
2. `RuntimeProfile` 的 validation 模式改用同一内存实现，退出时无文件残留。
3. `LanguagePreferences` 的 suite 读取改经协议。
4. 新增 `scripts/tests/test_preferences_hygiene.py`：记录 `~/Library/Preferences` 中 `*clipshelf*` 文件数，运行 `swift test`，断言数量不变。CI 执行。
5. 一次性清理脚本 `scripts/cleanup-leaked-preferences.sh`，只删除上述前缀，执行前打印清单并要求确认。

**验收。** 本地与 CI 跑完全部测试，`ls ~/Library/Preferences | grep -ci clipshelf` 前后一致。

### W3.2 日志不被刷掉

**改动。**

1. 测试目标中所有 `Logger(subsystem: "io.github.bestbbb.clipshelf")` 调用经 `LogSink` 协议注入，测试使用空实现。
2. 生产日志 `PasteOutcome` 分类保持 `notice` 级别；新增 `log config` 说明写入 `docs/BUILD_AND_RELEASE.md`，便于复现时拉取。

**验收。** 跑完测试后，`log show --last 10m --predicate 'subsystem == "io.github.bestbbb.clipshelf"'` 不含测试进程条目。

### W3.3 拆分两个上帝对象

**改动。**

1. `ClipShelfApplication.swift`（2,287 行）按职责拆成 `AppDelegate`（生命周期与菜单）、`PasteFlowController`（目标、粘贴、Stack 装配）、`LibraryController`（存储、清理、备份装配）、`SettingsCoordinator`（各设置窗口）。
2. `ClipboardPanelController.swift`（3,339 行）拆出 `ShelfToolbar`、`ShelfResultsController`（集合视图与分页）、`ShelfDetailController`（编辑与预览窗口）、`ShelfSelectionController`。
3. 面板与应用之间的 30 余个 `onXxx` 闭包收敛为一个 `ShelfDelegate` 协议。
4. 机械拆分，不改行为；每拆一个文件跑相关测试。

**验收。** 单文件 ≤ 800 行；现有测试全部通过。

### W3.4 清理遗留

- 删除根目录 Tauri / Vite 脚手架（`src-tauri/`、`index.html`、`vite.config.ts`、`tsconfig.json`、`package.json`、`package-lock.json`、`node_modules/`），README 保留一句历史说明。
- 修正 README 与实现状态文档中面板高度的不一致（代码为 240 / 330 pt）。
- `docs/` 中超过 50 KB 的三份文档各加“阅读顺序”摘要段。

## 4. 具体数值与默认值一览

| 项 | 现值 | 新默认 | 偏好键 |
| --- | --- | --- | --- |
| 粘贴严格度 | strict（唯一） | compatible | `pasteStrictness` |
| 焦点稳定等待 | 80 ms | 40 ms | 无 |
| 派发截止 | 0.9 s | 0.9 s | 无 |
| AX 消息超时 | 系统默认 6 s | 0.25 s | 无 |
| OCR | 始终开 | 关 | `ocrEnabled` |
| 缩略图缓存 | 32 MiB | 8 MiB | 无 |
| 单次采集预算 | 64 MiB | 16 MiB | `captureBudgetMiB` |
| 轮询间隔 | 0.3 s | 0.3 s | 无 |
| 空闲内存预算 | 无 | 60 MB（核心）/ 110 MB（含 Extras） | `scripts/memory-budget.json` |

## 5. 验收流程

### 5.1 六步人工验收

由非开发者在真实键盘上执行，ClipShelf 以 `--diagnostic-trace` 启动，stderr 重定向到文件：

1. 在目标应用中复制一段文字（分别用 TextEdit、Chrome 网页输入框、VS Code、微信各做一轮）。
2. 物理按 ⌘⇧V，面板出现。
3. 单击一张卡片，面板消失。
4. 内容恰好一次出现在原光标处。
5. 继续输入，输入落在粘贴内容之后。
6. 再按一次 ⌘⇧V 后按 Esc，无插入；再按 ⌘⇧V 后单击另一张卡片，恰好一次插入。

四个应用各连续 10 次，任一失败即 P1 不通过。记录用 `scripts/summarize-trace.py` 生成，附在 PR 描述里。

### 5.2 自动回归

- `swift test` 只跑核心三目标；Extras 测试在 `CLIPSHELF_EXTRAS=1` 时运行。
- CI 新增：内存预算断言（W2.6）、偏好卫生断言（W3.1）、两种配置的构建体积断言（W2.1）。

### 5.3 不算通过的情况

- 用桌面自动化工具向窗口定向输入、用应用 reopen 代替热键唤起。
- 只凭 `dispatched` 日志，不核对目标文档内容。
- 单元测试数量增加。

## 6. 工作量与顺序

| 工作项 | 估算 | 依赖 |
| --- | --- | --- |
| W1.1 严格度开关 | 1.5 天 | 无 |
| W1.2 AX 超时 | 0.5 天 | 无 |
| W1.3 删除点击盾 | 0.5 天 | 无 |
| W1.4 诊断面板 | 2 天 | W1.1 |
| W1.5 热键回退 | 0.5 天 | W1.4 |
| W1.6 trace 汇总脚本 | 0.5 天 | 无 |
| P1 验收 | 1 天 | 以上全部 |
| W2.1 目标拆分 | 3 天 | P1 通过 |
| W2.2 延迟服务 | 1 天 | W2.1 |
| W2.3 本地化按需 | 1 天 | 无 |
| W2.4 面板释放 | 1 天 | 无 |
| W2.5 采集预算 | 0.5 天 | 无 |
| W2.6 内存预算 CI | 1 天 | W2.1 |
| W3.1 测试卫生 | 1.5 天 | 无 |
| W3.2 日志注入 | 0.5 天 | 无 |
| W3.3 拆上帝对象 | 4 天 | W2.1 |
| W3.4 清理遗留 | 0.5 天 | 无 |

P1 约 1.5 周，P2 约 1.5 周，P3 约 1.5 周，单人串行约 4.5 周；W2.3 / W2.4 / W2.5 / W3.1 / W3.2 / W3.4 无依赖，可并行。

## 7. 风险

- `compatible` 模式放宽后，在极少数应用上可能把内容粘进错误输入框。缓解：按应用覆盖表，诊断面板一键切回 `strict`。
- 目标拆分期间与并行修 bug 的分支冲突大。缓解：拆分按文件机械移动，单独 PR，当天合并。
- 内存预算在不同 macOS 版本上基线不同。缓解：预算只在 CI 的固定镜像上断言，本机只报告。
