# 通用输入位置恢复：修复与验收边界

日期：2026-10-10。验收目标是任何 App 中当前的可编辑位置：**保留光标或选区 → 打开 ClipShelf → 搜索历史 → 单击卡片 → 插入原位置并继续输入**。目标不按 Codex、Cursor 等应用名称设白名单。此前 Cursor 通过不能代表 Codex 或全应用通过。

## 已确认的问题与尚未确认的原因

用户反馈 Codex 输入框中单击后仍须手动粘贴。旧追踪在 17:14:43 已记录 Codex 窗口、输入元素就绪以及一次派发，因此旧的 `dispatched` 结果没有证明接收方真正插入。

原实现只保存 App、窗口和 AX 焦点元素，未保存可读取的文本选区；焦点检查第一次通过后立刻发送合成 ⌘V，没有等待焦点稳定。这是源代码中确认的缺口，尚不能断言它们就是 Codex 失败的全部原因。

只读查看本机安装的 Codex 公开应用资源，确认其 Electron 菜单包含标准 Paste role；这支持提供通用原生菜单路径，不代表已经验证 Codex 回填。没有修改 Codex，没有将提取的资源上传到仓库。

## 通用修复

1. 在调用面板时保存原 App、窗口、焦点元素，以及控件支持的 `AXSelectedTextRange`。选区长度为零就是插入点；不持续读取所有 App 的输入内容。
2. App 没有提供焦点元素时，尝试系统级焦点元素，并核验它仍属于同一个目标进程。
3. 收起面板后恢复原窗口、输入控件和可读取的选区；派发前继续核验选区。恢复失败、目标改变或剪贴板被替换时停止派发。
4. 原位置和修饰键连续就绪至少 80 ms 后，才准备粘贴；准备完成后再次核验目标、剪贴板及期限。
5. 普通粘贴优先使用目标 App 中唯一、启用且支持 AXPress 的标准 ⌘V 菜单项，通过快捷键属性识别，不依赖菜单语言。找不到或存在歧义时使用原有键盘路径；需要保持 Command 的 Paste Stack 使用键盘路径。
6. 一个请求只执行一次动作。菜单动作执行失败后不再发送第二组按键，避免不确定结果导致重复插入。追踪记录 `menu` 或 `keyboard`；`dispatched` 仍只表示动作提交，不能作为内容插入的验收断言。

控件不提供文本范围时，只能恢复其保留的输入位置，不能承诺读取并精确恢复不可访问的内部选区。完整兼容性需要实际接收方结果。

标准菜单快捷键的 Command 位采用 macOS AX 的默认语义，参见 [Apple AXMenuItemModifiers](https://developer.apple.com/documentation/applicationservices/axmenuitemmodifiers?language=objc)。

## 本轮实际通过

使用普通运行模式、现有辅助功能授权和独立 Cursor 测试工作区；通过应用打开/reopen 入口调用面板。没有发送聊天消息，也没有要求用户操作测试文档。

| 场景 | 实际观察 |
| --- | --- |
| Cursor 代码编辑区 | 在已有文本中间定位；单击卡片插入一次；随后 `_NEXT` 接在新插入文本后面 |
| Cursor 代码编辑区选区替换 | 选中 `_CONTINUE`，打开面板后单击历史，原选区被替换一次 |
| Cursor 聊天框搜索旧内容 | 草稿 `CURSOR_DRAFT:left\|right`，原剪贴板为另一条记录；在 ClipShelf 搜索 `CURSOR_SINGLE_CLICK_1010` 并单击，得到 `CURSOR_DRAFT:leftCURSOR_SINGLE_CLICK_1010\|right`；继续输入得到 `CURSOR_DRAFT:leftCURSOR_SINGLE_CLICK_1010_NEXT\|right` |

受控的三次请求追踪均使用 `keyboard`。**原生菜单路径的真实桌面结果仍未验收。**

91 项相关回归测试通过，覆盖菜单识别、一次派发与失败后不重试、焦点稳定等待、选区不符和最终边界取消、剪贴板并发变化、选区 AXValue 解码、卡片交互、面板回调和 Paste Stack。界面本地化审计和签名构建通过。

安装位置：`/Users/liubin/Applications/ClipShelf.app`。可执行文件 SHA-256：`23b8a12568d63173ede505bf583842eb77fccde51210a2eac7326c1cb3100203`。签名要求仍为 `io.github.bestbbb.clipshelf.dev` 和原稳定证书，授权没有重置。

## 未通过验收的项目

- Codex：桌面工具明确禁止控制 `com.openai.codex`，不能完成受控的输入框内容检查；没有改用其他自动化手段绕过限制。用户反馈的失败不能因代码修改或日志派发而标成已解决。
- TextEdit、Chrome：工具操作了测试输入框，但 ClipShelf 捕获的系统真实前台仍是另一个 App。因目标不符，未点击卡片执行错误目标粘贴，未计为通过。Chrome 测试使用只提供人工构造内容的本地 HTTP 站点，无文件系统读取路由；测试标签页和服务器已关闭。
- 中文与表情：已在独立 Cursor 草稿准备 Unicode 来源；随后真实前台发生变化，面板被外部点击取消，没有完成回填内容验收。测试草稿已清空。
- 本轮没有受控验证物理全局热键。用户真实操作日志出现了热键回调，但不等于所有热键场景验收通过。
- 富文本、图片、文件接收和长期日常使用验收没有在本轮完成。

所以本轮结论是：**通用恢复机制已修改并安装，Cursor 的上述文本动线通过；不能宣称 Codex 故障已解决或所有 App 已兼容。**

## 本机证据

`build/codex-paste-fix/` 在 Git 忽略范围内，保存 `diagnostic.jsonl`、`cursor-editor-result.ax.txt`、`cursor-selection-result.ax.txt`、`cursor-chat-result.ax.txt`、`cursor-chat-result.png`、`acceptance.json`、`tests-final.log`、`build.log` 和 `localization-audit.log`。完整 AX 快照、截图及提取的第三方资源仅留在本机。

前轮 Cursor 的单击修改保留在[单击回填验收记录](SINGLE_CLICK_WORKFLOW.zh-CN.md)，该轮的构建哈希与范围为历史记录，不能替代本文所列的当前状态。
