# 单击回填可靠性：修复与实际验收

日期：2026-10-10。用户仍反馈单击历史后必须手动粘贴，因此上一轮交付不能视为核心动线全部完成。本轮验收直接检查接收方内容：**原光标或选区 → 调用面板 → 找到历史 → 单击 → 原位置插入一次 → 继续输入**。

## 问题与修复

1. **粘贴派发依赖全局输入路由。** 非激活面板可以取得键盘焦点，而原 App 仍是前台进程；前台检查通过不能证明全局按键送到了原输入框。现在保留窗口、控件、选区恢复和派发前检查，将一组 ⌘V 按键通过 `CGEvent.postToPid` 发给捕获的目标进程。不按 App 名称维护白名单。
2. **菜单动作接受不等于插入成功。** 旧日志存在 `menu` 派发，但没有接收方内容证据。当前系统路径不再调用 AX 菜单 Paste，也不在派发后自动重试另一条路径，以免重复插入。`dispatched` 仍仅表示命令提交，不能独立用于验收。
3. **迟到的鼠标事件可能取消较新的粘贴请求。** 旧日志确认两次焦点就绪后被外部鼠标回调取消，但旧追踪没有事件创建时间，不能断定它们都是旧点击。当前按事件创建时间与请求开始时间比较，忽略旧点击；新点击仍取消待派发请求。位置判断使用事件本身的位置，不使用回调执行时鼠标已移动到的位置。
4. **异步激活后的输入恢复。** 初次恢复可能早于目标 App 激活完成。目标进程成为前台后，若原控件或选区尚未恢复，最多再恢复一次，再执行原有稳定等待与最终核验。

这些是通用机制的修复；尚未证明它们覆盖了 Codex 失败的全部原因。

## 本轮真实桌面结果

测试使用正常安装包及既有辅助功能授权，通过应用 reopen 入口调用面板。没有补按 ⌘V，没有发送聊天消息，没有要求用户操作测试文档。浏览器使用仅含人工构造内容的 localhost 页面，来源复制通过实际 Chrome 窗口完成；确认系统前台和 ClipShelf 目标一致后才点卡片。

表中 `|` 是人工插入的定位字符，回填发生在它前面；`_NEXT` 是回填后继续输入的内容。

| 场景 | 实际接收方结果 | 结论 |
| --- | --- | --- |
| Chrome 单行输入框 | `leftGENERIC_BROWSER_1010_NEXT\|right` | 单击插入一次，直接继续输入 |
| Chrome 多行输入框 | `left中文🙂` 换行后 `第二行_1010_NEXT\|right` | 中文、表情、换行保留，直接继续输入 |
| Chrome contenteditable 搜索旧历史 | `leftGENERIC_BROWSER_1010_NEXT\|right` | 当前剪贴板为另一条记录；搜索后单击回填，直接继续输入 |
| Chrome contenteditable 选区替换 | `leftRELIABLE_PASTE_1010_NEXT\|right` | 仅替换已选中的历史文本，原前后缀保留 |
| Cursor 代码编辑区 | `TARGET: leftRELIABLE_PASTE_1010_NEXT\|right` | 单击插入一次，直接继续输入 |
| Cursor 代码编辑区选区替换 | `SELECTION: before[GENERIC_BROWSER_1010]after` | 仅替换 `replace_me`，原前后缀保留 |
| Cursor 聊天输入框 | `CHAT:leftRELIABLE_PASTE_1010_NEXT\|right` | 单击插入一次，直接继续输入；证据保存后已清空草稿 |

每个验收请求对应一次 `keyboard` 派发。Cursor 编辑区最终结果已保存到独立测试工作区的文件中；网页结果由实际输入框值和截图核验，不能用派发日志替代。

日志另有一次 Chrome 派发，来自测试框架只聚焦后台测试标签页、未切换真实前台标签页的准备失误；目标输入框没有变化，已排除在通过计数之外。之后先选中实际 Chrome 测试标签页，再通过原生窗口复制、定位与回填，才获得上表四项浏览器结果。

## 自动回归与安装

最终运行 **78 项相关测试，0 失败**，覆盖旧鼠标事件过滤、新点击取消、异步激活后再恢复选区、目标进程按键路由、修饰键释放、一次派发、剪贴板变化、目标与选区变化、面板回调、应用生命周期、Paste Stack 和追踪格式。

```sh
swift test --disable-keychain --disable-netrc --package-path native \
  --filter 'PasteCoordinatorTests|PasteEventTests|PasteSelectionRangeTests|PasteTargetHistoryTests|StackPasteGestureCoordinatorTests|StackDispatchTests|PanelPendingOutputTests|ValidationTraceTests|ApplicationInteractionLifecycleTests'
```

构建、应用本地化审计和严格签名核验通过。已安装到 `/Users/liubin/Applications/ClipShelf.app`，沿用稳定签名身份，既有辅助功能授权有效。

可执行文件 SHA-256：`d50f70423a13b8a1467f42f16ea5a8928e52240732e4a407798bb4d9aa289e1e`。

## 尚未验收与剩余问题

- **Codex 的用户报告仍未完成受控复验。** 桌面工具明确禁止控制 Codex，无法直接核对其输入框结果；没有改用其他方式绕过限制。因此不能宣布 Codex 故障已解决。
- **TextEdit 未通过本轮验收。** 桌面工具能操作测试文档的 AX 控件，但系统真实前台仍为 Cursor，ClipShelf 也显示目标为 Cursor。该请求已取消，未向错误目标粘贴；不能计入通过。
- **物理全局快捷键未在本轮受控验证。** 当前结果覆盖 reopen 调用后的回填。此前用户日志有热键回调，但不能代替本轮端到端验证。
- 当前测试覆盖文本与富文本编辑区域中的纯文本插入；未验收格式保真、图片、文件、多对象粘贴、所有 App、自定义控件或长期连续使用。
- 日志仍有 `NSCollectionViewFlowLayout` 卡片尺寸警告，属于待修正的布局问题。此次回填修复未处理它。
- 不提供可读取选区的控件仍依赖自身保留输入位置；无法保证恢复其不可访问的内部选区。

当前结论：**已安装的修复版在上表 7 个文本场景通过；全应用兼容和完整复刻仍未完成。**

## 本机证据

`build/paste-reliability-1010/` 在 Git 忽略范围内，保存 `diagnostic.jsonl`、`browser.ax.txt`、`browser-passed.png`、`cursor-editor.ax.txt`、`cursor-chat.ax.txt`、`cursor-chat.png`、`regressions-final.log` 和 `build.log`。旧安装包备份为 `ClipShelf-before.app`。完整 AX 快照、截图和运行日志只留本机，不上传公共仓库。

测试浏览器标签页和临时 localhost 服务已关闭，聊天测试草稿已清空；本地 ClipShelf 保持运行。
