# 历史元数据检索基准

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
