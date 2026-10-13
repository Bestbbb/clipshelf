# 改进规格续改记录：2026-10-13

依据：[IMPROVEMENT_SPEC.zh-CN.md](IMPROVEMENT_SPEC.zh-CN.md)，2026-10-11 v1。
续改基线：`ec8054b8445c9622cbf07b4e69d42e5e6fa9dc8b`。
前一轮记录：[IMPROVEMENT_IMPLEMENTATION.zh-CN.md](IMPROVEMENT_IMPLEMENTATION.zh-CN.md)。

以下保留本日存储和测试卫生续改的历史结果。Mac 解锁后的原光标测试、额外焦点修复和最终构建的验收边界见[本机接收端验收记录](PASTE_ACCEPTANCE_2026-10-13.zh-CN.md)。

## 当前结论

本轮补齐 P1 兼容模式的一处遗漏，修复空间预算的设备编号问题、冷启动并发问题与图片拖出完成回调的竞态，并落实 W3.1 的内存偏好、测试隔离和 CI 检查。新版已安装到本机并恢复正常运行模式。

**最终全量 Swift 测试 1,411 项，0 失败、1 项跳过。** 跳过的是本机不可用的 Apple Intelligence 真模型检查，与原光标粘贴验收无关。

**P1 的真实键盘与鼠标验收仍未完成。** 本轮桌面工具返回“Mac 已锁定”，没有接收端插入结果，也没有把启动或热键注册日志算作粘贴成功。按规格不开始 P2；按用户此前范围不测试微信。

## 修改与依据

| 项目 | 原问题 | 本轮修改 |
| --- | --- | --- |
| W1.1 兼容模式 | 虽然放宽了 AX 焦点身份检查，入口仍要求 AX 窗口可读；应用选择和面板提示也有相同限制 | `compatible` 可在没有窗口快照时继续尽力恢复和派发；`strict` 保留窗口要求。权限、进程、前台、修饰键、剪贴板所有权、取消和截止时间检查保留；模式仍在每次尝试入口冻结 |
| W1.1 截止时间 | 兼容模式诊断发现 AX 元素或选区变化时还会再次恢复、再次读取，消耗派发预算 | 兼容模式保留一次尽力恢复和诊断，不因诊断差异重复读取；严格模式保留恢复后的复查 |
| 存储预算身份 | 本机备用注册表的已保存设备编号与当前编号不同，inode 未变；设备编号被当作持久身份，导致 `coordinationUnavailable` | 新节点记录卷 UUID，持久比较使用卷 UUID、inode、generation、创建时间；进程内路径校验继续保留设备编号。没有卷 UUID 的文件系统保持保守检查 |
| 旧注册表升级 | 直接忽略设备编号或清空注册表会绕过正在使用的预算 | 只升级内容为空、最新日志无待写入/保留项、对象完整印记匹配且没有未知文件的旧注册表。升级头写到原预留区域；原校验头、索引和日志保留。非空或异常的旧注册表不会被自动重绑定 |
| 注册表冷启动并发 | 创建锁文件与获取锁之间，另一个进程可能先读到未初始化的头部 | 创建时使用 `O_EXLOCK` 原子获取锁；加强回归，用 50 个新注册表重复并发争用预算 |
| 图片拖出 | 文件承诺先调用完成回调，再通过 `defer` 释放预算；接收方马上继续写入或清理目录时会竞态 | 写入与预算释放先在内部函数中结束，再调用成功或失败回调；新增固定容量回归，验证完成回调中可以立即申请完整预算 |
| W3.1 偏好隔离 | 测试和验证模式创建真实 `UserDefaults` suite，中断后可能留下 plist | 增加 `PreferencesStore`；正常运行仍使用 `UserDefaults`，验证与测试改用独立的 `InMemoryPreferences`。语言设置与热键/存储/同步设置通过同一接口读写 |
| W3.1 测试存储隔离 | 部分 OCR、图片、编辑测试虽使用临时输出目录，空间预算却落在真实用户缓存 | 显式注入测试专属预算协调器；OCR 缓存的预算目录独立于可清空的缓存目录；文件承诺的异步写入在完成回调前结束 |
| W3.1 自动检查与旧文件处理 | 缺少偏好文件副作用检查 | 新增 `scripts/tests/test_preferences_hygiene.py`，CI 的原 Swift 测试步骤改由它执行；检查相关偏好文件的新增/删除。提供清理脚本，默认只列出，明确确认后移到回收站；本轮未执行旧偏好清理 |
| 打包 | App Intents 的独立编译未包含新偏好接口；当前 Swift 驱动未输出脚本期待的常量文件 | 元数据编译补齐 `PreferencesStore.swift`，显式通过驱动声明常量输出，生成后检查文件存在；本机成功导出 3 项 App Intents |

卷 UUID API 见 [Apple 文档](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeuuidstringkey)；原子文件锁语义见 [Apple 的 open 手册](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/open.2.html)。本轮确认的是已保存和当前编号确实不一致，没有通过重启或重新挂载机器做验证。

## 验证证据

证据保存在被 Git 忽略的 `build/improvement-followup-1013/`，不上传用户运行日志、注册表备份或应用备份。

- 最终 Swift 全量测试：**1,411 项、1 跳过、0 失败**，`full-tests-final.log`。相关 109 项先行回归也通过；数量与全量重叠，不相加。
- 之前的 18 个存储相关失败已不再出现。第一轮全量运行仍发现一个图片拖出清理竞态；固定容量新回归在修复前稳定失败（`requiredBytes: 10172, availableBytes: 10000`），修复后与全量一起通过。
- 偏好卫生检查：ClipShelf 相关文件 **1,882 → 1,882**，新增、删除均为空，测试退出码 0，见 `preferences-hygiene-final.json`。这证明本次运行没有新增/删除相关偏好文件，不代表已有历史文件已清理，也不检查所有系统日志副作用。
- Python：**88 项通过**，`python-tests-final.log`；16 种语言资源审计通过。
- macOS 优化构建、资源打包、3 项 App Intents 元数据、严格深度签名校验通过，见 `build-final.log`。
- 真实本机备用缓存与开发历史库预算注册表：备份元数据后，申请 1 字节预算、重新校验、释放均成功，原头部保留、最终条目数为 0，见 `storage-smoke.jsonl`。没有写入测试历史内容，也没有清空注册表。
- 正常应用进程的 activation 与 Stack 热键注册状态均为 `0`；注册成功仍不等于物理按键入口或接收端插入成功。

### 当前环境限制

桌面工具在尝试打开独立 TextEdit 文稿时返回“Mac 已锁定，无法自动解锁”。本轮没有开始粘贴尝试；`validation.jsonl` 的汇总见 `validation-summary.md`。没有使用 reopen、定向输入或注册日志替代第 5 节验收。

额外尝试本机 Xcode 分享扩展构建，在编译项目之前因系统 `DVTDownloads` 与 `IDESimulatorFoundation` 的符号不匹配退出。`xcode-build.log` 保留原错误。没有改动系统 Xcode 安装；本轮不能声称本机分享扩展构建通过。交付的 SwiftPM 桌面应用构建已通过，CI 的分享扩展构建仍需验证。

## 安装与剩余工作

安装：`/Users/liubin/Applications/ClipShelf.app`，正常本地历史模式。
可执行文件 SHA-256：`ad72bdc88fb9807620469052d787a2927e1626ef1019e10e666a07e486a7fd9b`。
保持既有 `io.github.bestbbb.clipshelf.dev` 及本地证书签名；没有重新设置证书、辅助功能或录制偏好。
旧应用和预算注册表元数据备份均在本轮证据目录中。

剩余：P1 的真实原光标连续验收；P2 的模块、内存、体积与采集预算；W3.2 日志隔离、W3.3 控制器拆分、W3.4 遗留清理。CI 偏好卫生已接入，远端 CI 状态应以具体提交的 Actions 结果为准。
