# 历史查询与开库基准

2026-10-09 在 Apple M5 Pro、macOS 26.4.1（25E253）、Swift 6.3.2 / Swift 5 language mode 上执行 release 构建。对照基线为提交 `45edfd6`（schema v7），优化后为 schema v8。基线从该提交的独立临时源码副本构建；两边使用完全相同的夹具 v1 和基准程序。每次运行只创建并清理专用临时目录，不接触用户历史、真实剪贴板或云账号。

优化后用 FTS5 trigram 筛出候选，再执行原来的完整字面子串校验。稀有词与无结果查询显著缩短；高频词新增候选集合开销。短于三个 Unicode scalar 的查询继续扫描，这里的“编辑器”为三个 scalar，不能代表全部短词性能。没有将候选索引等同于分词搜索，也没有更改 SQLite 原有 ASCII 大小写转换语义。

**这里只测 `HistoryStore.searchMetadata` 的同步查询及元数据解码。** 不包含来源/设备筛选菜单聚合、深页定位、UI debounce、中文输入法、绘制或动画，因此不构成 spec 中“输入到结果稳定 p95 ≤ 100 ms”的端到端验收。App 对来源/设备列表另有按数据库变更失效的缓存；首次聚合和变更后重算仍有成本。夹具来源设备为空，不能用它证明真实设备聚合性能。

## 复现

在仓库 `native` 目录执行；标准输出保留全部原始样本：

```sh
swift run -c release ClipShelfHistoryBenchmark --rows 10000 --iterations 100 > Benchmarks/results/f03-after-10000.json
swift run -c release ClipShelfHistoryBenchmark --rows 100000 --iterations 30 > Benchmarks/results/f03-after-100000.json
```

要重跑旧版，可在提交 `45edfd6` 的独立副本中执行同样命令。夹具含 80% 文本（总量的 5% 带 HTML 表示）、5% 链接、10% 合成图片字节、5% 文件 URL 引用、5 个来源应用和 5 个 Pinboard，含中英文及 OCR 字段。图片字节用于存储测试，不是可渲染图片。10k 正文/OCR为 6,405,586 bytes、表示为 4,516,888 bytes；100k 对应 64,160,574 / 45,179,028 bytes。

每个场景预热5次，随后记录100次（10k）或30次（100k），按nearest-rank计算p50/p95。两版本结果条数一致，每次运行内部检查ID及顺序稳定；字面语义与独立原SQL查询的对照在 `SearchIndexTests` 中执行。操作系统文件缓存温热，后台系统负载未隔离，本结果不能代表冷磁盘、Intel Mac或低内存机器。

## 同夹具对照

单位为ms；列出p95，p50与全部样本见JSON。保留旧场景名中的`full_scan`便于对照，优化后这些场景已走候选索引。

| 场景 | 10k条数 | v7 p95 | v8 p95 | 100k条数 | v7 p95 | v8 p95 |
|---|---:|---:|---:|---:|---:|---:|
| `latest_300_metadata` | 300 | 0.457 | 0.496 | 300 | 0.451 | 0.454 |
| `common_ascii` | 300 | 0.527 | 1.693 | 300 | 0.531 | 11.790 |
| `common_chinese` | 300 | 0.525 | 1.070 | 300 | 0.549 | 5.280 |
| `rare_mixed_language_full_scan` | 9 | 8.246 | 0.098 | 80 | 81.004 | 0.323 |
| `absent_literal_full_scan` | 0 | 8.589 | 0.076 | 0 | 85.466 | 0.116 |
| `ocr_only` | 300 | 4.864 | 1.011 | 300 | 4.752 | 1.990 |
| `type_source_date_board` | 96 | 0.272 | 0.271 | 300 | 0.886 | 1.021 |
| `first_300_after_connection_reopen` | 300 | 0.508 | 0.559 | 300 | 0.520 | 0.569 |

夹具逐条写入耗时与第一次300条读取（ms）：

| 规模 | v7写入 | v8写入 | v7首屏查询 | v8首屏查询 |
|---|---:|---:|---:|---:|
| 10,000 | 1946.9 | 2548.1 | 0.576 | 0.602 |
| 100,000 | 74479.4 | 81376.8 | 0.581 | 0.587 |

这些写入值包含逐条事务、附件落盘和板顺序分配；它们不是批量导入或每次真实复制延迟。未单独测量索引磁盘增量与旧大库迁移耗时，不能据此宣称索引零成本。

原始样本：[v7 10k](results/f03-before-10000.json)、[v7 100k](results/f03-before-100000.json)、[v8 10k](results/f03-after-10000.json)、[v8 100k](results/f03-after-100000.json)。[源文件及结果SHA-256](results/f03-source-fingerprints.json)记录两个实现与相同基准程序，供追溯。

较早的schema v6测量仍保留为[10k](results/history-10000.json)、[100k](results/history-100000.json)及[源码摘要](results/source-fingerprints.json)，不与本次v7/v8对照混算。

## Schema v12 刷新：提交 `08f4998`

2026-10-10 04:19:38–04:21:06（Asia/Taipei），从精确提交 `08f499876cc73bda7a5e1e73b29b32c9e0feee58` 的独立 `git archive` 副本构建 release 基准，按顺序执行 10k × 100 次和 100k × 30 次。它测量的是该提交，不代表后续更新器或发布配置改动已经重测。环境为 Apple M5 Pro、18 核、64 GiB、macOS 26.4.1（25E253）、Xcode 26.5（17F42）、Swift 6.3.2 / Swift 5 language mode。

基准源码与 `e78ef3f9c62152329a41c26fb58c003e47dc8ce9` 逐字一致，SHA-256 为 `f810a72b4a42590f9bc0e155305daa9ac3bf632f837f4a6072904f6673581020`。使用相同 fixture v1，各规模的正文/表示字节数、场景结果条数均一致，程序继续检查每轮 ID 与顺序稳定；重新核对全部原始样本的 nearest-rank p50/p95。运行只使用并清理独立临时数据库，不访问真实资料库、剪贴板或云账号；没有覆盖旧结果。

下表为查询 p95，单位 ms。系统缓存温热、后台负载未隔离，旧数据不是本次在匹配负载下重新测量；小幅差异不能直接归因为代码优化或退化。

| 场景 | 10k v8 | 10k v12 | 100k v8 | 100k v12 |
| --- | ---: | ---: | ---: | ---: |
| `latest_300_metadata` | 0.496 | 0.452 | 0.454 | 0.467 |
| `common_ascii` | 1.693 | 1.581 | 11.790 | 11.619 |
| `common_chinese` | 1.070 | 0.987 | 5.280 | 5.218 |
| `rare_mixed_language_full_scan` | 0.098 | 0.095 | 0.323 | 0.287 |
| `absent_literal_full_scan` | 0.076 | 0.072 | 0.116 | 0.086 |
| `ocr_only` | 1.011 | 0.974 | 1.990 | 1.887 |
| `type_source_date_board` | 0.271 | 0.276 | 1.021 | 0.860 |
| `first_300_after_connection_reopen` | 0.559 | 0.589 | 0.569 | 0.594 |

单次夹具准备、打开连接和首次查询，单位 ms：

| 规模 | v8 写入 | v12 写入 | v8 打开连接 | v12 打开连接 | v8 首次查询 | v12 首次查询 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 2548.105 | 2561.876 | 1.504 | 5.744 | 0.602 | 0.667 |
| 100,000 | 81376.826 | 81447.593 | 1.698 | 38.313 | 0.587 | 0.735 |

**100k 的单次打开连接耗时明显增加，需独立重复采样与语句剖析。** `first_300_after_connection_reopen` 只计连接创建后的查询，不含打开连接成本，因此查询 p95 接近旧值不能证明启动成本没有回归。源码中已有的 cleanup-token 初始化会在当前 schema 开库时执行全表 `INSERT OR IGNORE … SELECT`，这只是可检验候选，尚未证明是上述差异的原因，更不能推断为 schema v12 GC 所致。本次没有运行 GC、额外开库剖析或调整 production 代码。

本轮仍只覆盖同步 `searchMetadata` 和元数据解码，不覆盖 UI/IME/debounce/绘制、菜单 facet 聚合、深页、输出附件或输入到结果稳定延迟，**F03 端到端 p95 ≤ 100 ms 的真实 UI 验收仍未完成**。

保存的证据：[v12 10k 原始样本](results/f03-schema12-10000.json)、[v12 100k 原始样本](results/f03-schema12-100000.json)、[逐项 p50/p95 与历史比较](results/f03-schema12-comparison.json)、[精确源码/环境/命令/时间与 SHA-256](results/f03-schema12-source-fingerprints.json)。复跑时用独立输出名或临时目录，保留这些对应提交的测量结果。


## Schema v13 开库回填：同夹具重开对照

2026-10-10 在同一台 Apple M5 Pro、64 GiB、macOS 26.4.1（25E253）、Swift 6.3.2 上重新测量。基线为精确提交 `d7d134b93a78383e083cd991c31430e3b5e531ca` 的独立源码副本；优化版为本次提交中的 Core 实现。两边均为 schema13、release 构建，使用逐字相同的基准程序和 fixture v1。这里新增独立计时项 `connection_reopen_including_schema_checks`，包含 `HistoryStore` 初始化和 schema 检查；`first_300_after_connection_reopen` 仍只计完成开库后的查询。

每种规模、每个版本各记录30次重开，保留全部样本并复算 nearest-rank p50/p95。重开不额外预热，OS文件缓存温热；查询场景仍先预热5次。两边的正文/表示字节量及所有场景结果条数相同，每轮查询继续验证ID及顺序。运行顺序为基线100k、基线10k、优化10k、优化100k；用于报告的计时阶段未与本任务的其他构建、测试或基准重叠，系统后台负载未隔离。一次与100k建库开始阶段重叠的预备10k测量已排除并重跑。

下表为打开已有资料库的耗时，单位ms；不含提前逐条生成合成数据的时间。

| 条目数 | 基线p50 | 优化p50 | 基线p95 | 优化p95 |
| --- | ---: | ---: | ---: | ---: |
| 10,000 | 4.679 | 1.178 | 5.108 | 1.388 |
| 100,000 | 37.362 | 1.156 | 39.776 | 1.408 |

重开后单独读取首批300条的p95分别为：10k基线0.618、优化0.569；100k基线0.679、优化0.565。优化版当前schema重开不再执行三条全表回填，改为必要结构检查；连接级SQL trace回归检查实际初始化语句。旧schema7/10之前的迁移仍执行对应回填，取得写锁后重读版本，避免并发连接已升级后仍按旧版本操作。迁移、损坏拒绝、清理确认与同步内容/排序头分叉另由功能测试覆盖。

这是同一夹具下的开库对照，不用旧schema12的单次38.313ms估算本轮收益。夹具未启用云同步，不代表大同步日志、旧库迁移、冷磁盘或其他机器；仍未包含真实剪贴板、菜单聚合、IME、UI debounce、绘制、动画及跨App切换。**本结果不能证明120ms面板唤起或100ms搜索端到端指标通过。**

原始样本：[基线10k](results/f03-startup-schema13-before-10000.json)、[基线100k](results/f03-startup-schema13-before-100000.json)、[优化10k](results/f03-startup-schema13-after-10000.json)、[优化100k](results/f03-startup-schema13-after-100000.json)。[源码、二进制、结果SHA-256及环境](results/f03-startup-schema13-source-fingerprints.json)保留完整Core输入摘要、相同基准程序摘要与复算值。复跑基线时，从`d7d134b`独立副本构建，并复制本次基准源文件；两边均使用`--iterations 30`，为结果选择新的输出文件名。
