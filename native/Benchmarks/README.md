# 历史元数据检索基准

2026-10-09 在 Apple M5 Pro、macOS 26.4.1（25E253）、Swift 6.3.2 / Swift 5 language mode 上执行 release 构建。SQLite schema v6，无外部依赖。每次运行只创建并清理专用临时目录，不接触用户历史、真实剪贴板或云端账号。

10,000 条日常混合夹具的核心检索 p95 最大为 8.265 ms，当前保留 SQLite literal substring 查询即可。100,000 条压力夹具的稀有词与无结果全表扫描明显退化；不能将 10,000 条结果外推到压力规模。

这只测 `HistoryStore.searchMetadata` 的同步查询与元数据解码。**不包含 UI debounce、中文组合输入、卡片绘制、动画或屏幕呈现，因此不构成 spec 中“输入到结果稳定 p95 ≤ 100 ms”的端到端验收。** 数据库重开时操作系统文件缓存仍是温热状态，也不构成冷磁盘测试。后台系统负载没有被隔离。

## 复现

在仓库 `native` 目录执行，标准输出即含所有原始样本的 JSON：

```sh
swift run -c release ClipShelfHistoryBenchmark --rows 10000 --iterations 100 > Benchmarks/results/history-10000.json
swift run -c release ClipShelfHistoryBenchmark --rows 100000 --iterations 30 > Benchmarks/results/history-100000.json
```

夹具 v1 包含 80% 文本（其中总量的 5% 带 HTML 表示）、5% 链接、10% 合成图片字节和 5% 文件 URL 引用，分布于 5 个来源应用和 5 个 Pinboard；正文含中文、英文、换行、重命名和 OCR 字段。图片字节用于元数据存储测试，并非可渲染图片夹具。10k 夹具正文/OCR共 6,405,586 bytes、表示 4,516,888 bytes；100k 对应 64,160,574 / 45,179,028 bytes。

每个查询预热 5 次，然后记录 100 次（10k）或 30 次（100k），按 nearest-rank 计算 p50/p95。每次检查返回 ID 集合和顺序稳定。元数据查询不会读取图片、HTML 等附件内容。

## 本次结果

单位：ms。结果条数是分页上限内的数量。

| 场景 | 10k 结果数 | 10k p50 | 10k p95 | 100k 结果数 | 100k p50 | 100k p95 |
|---|---:|---:|---:|---:|---:|---:|
| `latest_300_metadata` | 300 | 0.429 | 0.452 | 300 | 0.434 | 0.475 |
| `common_ascii` | 300 | 0.520 | 0.560 | 300 | 0.526 | 0.559 |
| `common_chinese` | 300 | 0.527 | 0.579 | 300 | 0.520 | 0.540 |
| `rare_mixed_language_full_scan` | 9 | 7.769 | 8.089 | 80 | 78.304 | 81.738 |
| `absent_literal_full_scan` | 0 | 8.066 | 8.265 | 0 | 82.734 | 86.676 |
| `ocr_only` | 300 | 4.766 | 5.023 | 300 | 4.619 | 4.782 |
| `type_source_date_board` | 96 | 0.263 | 0.280 | 300 | 0.842 | 0.910 |
| `first_300_after_connection_reopen` | 300 | 0.507 | 0.541 | 300 | 0.487 | 0.511 |

第一次重开连接耗时：10k 1.020 ms，100k 1.290 ms。第一次读取 300 条元数据：10k 0.581 ms，100k 0.607 ms。夹具写入耗时：10k 1314.0 ms，100k 11760.4 ms；写入不计入检索样本。

原始结果：[10k JSON](results/history-10000.json)、[100k JSON](results/history-100000.json)。[源文件摘要](results/source-fingerprints.json) 记录本次核心与夹具源码 SHA-256，供结果追溯。测试机器不能代表 Intel Mac、低内存机器或更大单条正文；后续优化应先补实际端到端与目标硬件数据，再决定 FTS 或其他索引方案。
