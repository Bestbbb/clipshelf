# ClipShelf 复刻失败独立梳理：进展、卡点与重启建议

归档说明：本文保留同事独立诊断时的运行状态、结论和建议，不代表最新版本。后续通用恢复修复、实际通过的流程与尚未验收的项目见[通用输入位置恢复记录](GENERIC_PASTE_WORKFLOW.zh-CN.md)。

整理日期：2026-10-10。本文基于对仓库代码、docs/ 下既有记录、`build/` 诊断文件和本机运行状态的独立核对，不替代[失败复盘](REPLICATION_FAILURE_RETROSPECTIVE.zh-CN.md)，而是回答三个问题：代码做到了哪一步，核心链路卡在哪里，重启时该先做什么。

## 1. 一句话结论

功能面和代码量都远超一个最小可用的剪贴板管理器，但唯一重要的链路“复制 → 物理按 ⌘⇧V 唤起 → 选中 → 回到原应用原光标粘贴”从未在用户的真实入口上被验证过。所有记录在案的“通过”都来自自动化使用的旁路入口。最后一次用户失败没有留下可用日志，具体触发链目前无法从机器上还原，只能重新复现。

## 2. 代码进展

### 2.1 规模

| 项目 | 数值 |
| --- | --- |
| 提交数 / 时间跨度 | 42 次，2026-10-09 至 10-10 |
| 应用源码（Swift） | 约 31,400 行，137 个文件 |
| 测试源码（Swift） | 约 29,600 行，1,361 个测试函数 |
| 最大单文件 | `ClipboardPanelController.swift` 3,339 行；`ClipShelfApplication.swift` 2,287 行 |

### 2.2 技术栈与目录

- 有效实现全部在 `native/`，Swift 5 / AppKit，SwiftPM 构建，依赖 Sparkle 2.10.0 和系统 SQLite。
- 根目录的 Tauri / React / Vite 脚手架是历史遗留：`src-tauri/src/main.rs` 只有 2 行，不存在 `src/` 目录。README 已说明它仅作项目历史保留。
- 模块划分：`ClipShelfCore`（存储、同步、配额）、`ClipShelf`（面板、系统集成、粘贴协调）、`ClipShelfLocalization`、`ShareInboxShared`、`ClipShelfShareExtension`。

### 2.3 功能覆盖

实现状态文档对 F01 至 F19 全部标为“已有实现”，包括：历史采集与冻结快照、全库搜索与 trigram 索引、Pinboard 分组与拖动排序、多对象预览、编辑与严格撤销、OCR、顺序粘贴 Stack、存储配额与回收、CloudKit 私有同步与共享、Sparkle 更新、MCP 服务器与 OAuth、16 种界面语言含希伯来语 RTL、系统 Services 与分享扩展。

这些能力绝大多数只有合成数据与不显示窗口的测试证据，没有在真实桌面上验收。

### 2.4 本机状态（整理时）

- `~/Applications/ClipShelf.app` 使用本地开发证书签名，15:19 构建的进程仍在运行。
- 偏好域 `io.github.bestbbb.clipshelf.dev`：`hasSeenWelcome = 1`，`recordingEnabled = 1`。采集本身工作正常，数据目录约 4.7 MB。
- 辅助功能授权状态无法从外部读取；最近一次记录显示界面曾出现“直接粘贴可用”。

## 3. 核心链路的技术卡点

链路在代码中分四段。每段都有未闭合的风险点。

### 3.1 全局热键从未被物理验证

- 实现：`native/Sources/ClipShelf/GlobalHotKey.swift` 使用 Carbon `RegisterEventHotKey`，默认 ⌘⇧V，按物理键码注册，不受输入法影响。
- 问题：注册失败（被系统或其他应用占用）时，错误只写入面板状态栏（`shortcutRegistrationMessage`），而面板恰恰打不开，用户看不到任何反馈。
- 证据：`build/daily-qa/acceptance.json` 与 `build/return-target-qa/acceptance.json` 的 `unverified` / `limits` 字段都明确列出“Physical global-hotkey activation”未验证。所有自动化都用“打开应用触发 reopen”唤起面板。

### 3.2 原目标捕获依赖“非激活面板”假设

- 实现：面板为 `.nonactivatingPanel`，设计上 ClipShelf 不会抢前台，`PasteEnvironment.captureTarget()` 直接读取当前前台应用作为粘贴目标。
- 问题：`Info.plist` 中 `LSUIElement = true`，没有 Dock 图标。若热键无反应，用户唯一能想到的入口就是在访达中双击应用，此时 ClipShelf 自身成为前台，目标为空。
- 证据：`build/return-target-qa/runtime.log` 14:57 连续四次 `captured bundle=none ... outcome=copied_only failure=restore_unavailable`；15:05 再次重现。
- 已做修补：提交 `0490b41` 增加 `PasteTargetHistory`，记住最近一个外部应用。这是对错误入口的补丁，没有回答“热键为什么没反应”。

### 3.3 粘贴派发的就绪检查过严

`PasteCoordinator.waitAndDispatch` 在发出合成 ⌘V 前要求以下条件全部成立，并在 0.9 秒内以 15 毫秒间隔轮询：

1. `AXIsProcessTrusted()` 为真；
2. 目标进程仍在运行并且有窗口；
3. 目标应用是当前前台；
4. 所有修饰键全部松开（Stack 模式仅允许 Command）；
5. AX 焦点窗口与捕获时 `CFEqual`；
6. AX 焦点元素与捕获时 `CFEqual`（捕获到元素时才检查）；
7. 剪贴板 `changeCount` 与写入时一致。

任一条件不满足即降级为 `copied_only`，提示“内容已复制，请手动 ⌘V”。Paste 官方说明中的直接粘贴只是“依赖辅助功能并发送 ⌘V”，没有这套逐项校验。对于 AX 元素身份不稳定的接收方（Electron 应用、即时通讯软件、输入法组合状态），条件 5 和 6 会稳定失败。

### 3.4 失败原因显示在已经关闭的面板里

派发流程先调用 `dismiss()` 关闭面板，之后的失败消息写入面板状态栏。用户看到的现象只是“按了没反应”。复盘已指出这一点，但未改为独立 HUD 或系统通知。

### 3.5 已确认并已修复的历史问题

| 问题 | 原因 | 状态 |
| --- | --- | --- |
| 更新后直接粘贴失效 | ad-hoc 签名的 designated requirement 只含随构建变化的 cdhash，辅助功能授权绑定旧哈希 | 改为本地开发证书签名并固定安装路径，已修复 |
| 首次可粘贴，重复超时 | 旧实现用 HID 事件源且 V 抬起仍带 Command，系统组合状态残留 Command | 改用独立事件源并恢复修饰键，已修复 |
| 搜索后 Esc 不收起 | 先清空关键词而非关闭 | 已修复 |
| 卡片菜单 Return 误触粘贴 | 菜单将 Return 注册为 Paste 的 keyEquivalent | 已移除 |

每次修复都要求用户配合：解锁、重新授权、手动按下并松开 Command。验收成本被转嫁给了用户。

### 3.6 最后一次失败没有证据

- 统一日志中 15:22 之后没有任何 `captured` 或 `outcome` 记录。
- 更严重的是，15:05 至 15:21 在 `runtime.log` 中确实存在的条目，整理时用 `log show` 已查不到，`--last 3h` 结果为 0 条。日志很可能被测试进程刷掉。
- 因此“最后到底卡在哪一步”无法还原，不能归因于任何已知问题。

## 4. 工程卫生问题

### 4.1 测试污染用户系统目录

`~/Library/Preferences` 下有 1,770 个 ClipShelf 测试遗留的 plist：

| 前缀 | 数量 |
| --- | --- |
| `ClipShelf.cleanup-tests.*` | 556 |
| `clipshelf-language-tests.*` | 253 |
| `io.github.bestbbb.clipshelf.validation.*` | 41 |
| `clipshelf-sharing-lifecycle-*`、`clipshelf-shortcut-commit-test-*` 等 | 其余 |

原因是测试用 `UserDefaults(suiteName:)` 建立独立域后未全部调用 `removePersistentDomain`。这些文件可以安全删除，但在修复测试之前每跑一次全量测试都会继续增加。

### 4.2 其他

- `package-lock.json` 未纳入版本控制，但 `node_modules/` 存在；前端部分已无实际用途。
- README 声称的面板高度（默认 330 pt、紧凑 240 pt）与实现状态文档中“标签行后提高至 376 pt”的说法不一致，代码当前为 240 / 330。
- 文档体量巨大（技术规格 106 KB、实现状态 91 KB、产品动线 77 KB），维护成本高于其验证价值。

## 5. 流程层面的根因

1. **核心可用性没有成为扩展功能的门槛。** 两天内铺开 19 个功能面，核心链路一次都没在真实键盘上跑通。
2. **测试入口与用户入口不一致。** 定向窗口输入、reopen 唤起、合成剪贴板数据，恰好绕开了焦点与激活问题。
3. **测试数量被当作进度。** 1,100 多个单元测试和 CI 通过不能证明一个按键在用户手里有反应。
4. **诊断手段在需要时失效。** 日志被测试刷掉，失败现场无法还原。
5. **验证负担转嫁用户。** 每轮修复都需要用户配合授权、解锁或清除按键状态。

## 6. 重启建议

以下顺序以“先取证，再改最小的东西”为原则。前五步完成之前，冻结其余功能面的开发。

### 6.1 不改代码，先复现最小链路

应用仍在运行。开一个终端实时跟踪：

```sh
log stream --predicate 'subsystem == "io.github.bestbbb.clipshelf"' --style compact
```

然后在文本编辑中物理按一次 ⌘⇧V：

- 面板不出现：问题在热键注册或系统占用，与粘贴逻辑无关。
- 面板出现但选中后没回填：日志会给出 `failure=` 枚举（`restore_unavailable`、`deadline`、`finalReadinessChanged` 等），直接定位到 3.2 或 3.3。

也可以用 `open ~/Applications/ClipShelf.app --args --validation-trace` 把结构化事件打到 stderr。

### 6.2 代码侧最小修改

1. 热键注册失败改为系统通知或弹窗，并在菜单栏菜单中显示当前热键与注册状态。
2. AX 焦点元素 `CFEqual` 检查降级为告警；失败时仍按 Paste 的方式激活目标、提升窗口、发送 ⌘V。
3. 粘贴失败时保留面板或弹出独立 HUD，让失败原因可见。
4. 修复测试的偏好域泄漏，避免继续刷掉日志和 Preferences。

### 6.3 最小验收门槛

只有以下流程在用户亲自操作下连续通过，才算核心可用：

1. 在任意应用中复制；
2. 物理按 ⌘⇧V，面板出现；
3. 选中一条，面板消失；
4. 内容恰好一次出现在原应用原光标处；
5. 继续输入正常；
6. 重复一次与 Esc 取消一次均正常。

没有这条流程的证据，不扩展功能，不以测试数量替代结果。

## 7. 证据索引

- 源码：`native/Sources/ClipShelf/GlobalHotKey.swift`、`GlobalShortcutCoordinator.swift`、`PasteEnvironment.swift`、`PasteTargetHistory.swift`、`PasteCoordinator.swift`、`ClipShelfApplication.swift`（`performTogglePanel`、`installObservers`）、`ClipboardPanelController.swift`（`present`、`dismiss`）。
- 本机诊断（忽略目录）：`build/return-target-qa/runtime.log`、`build/return-target-qa/acceptance.json`、`build/daily-qa/acceptance.json`。
- 既有记录：[失败复盘](REPLICATION_FAILURE_RETROSPECTIVE.zh-CN.md)、[本地测试记录](LOCAL_USABILITY_QA.zh-CN.md)、[问题与修复记录](USABILITY_ALIGNMENT.zh-CN.md)、[实现状态](IMPLEMENTATION_STATUS.zh-CN.md)。
