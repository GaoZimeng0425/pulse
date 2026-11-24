# 04: top_disk_io 读写契约——生产不写的列被 MCP 当真数据源

**What to build:** 修复 REPORT 高5:`sample_min.disk_r/disk_w` 生产恒空,但 `InsightQuery.topDiskGroups` 用它排名、MCP `top_disk_io` 对用户输出全 0 并附错误解释;测试手写 INSERT 造假掩盖矛盾。

**Status:** needs-triage

**待拍板(用户稍后处理):** 二选一——(a) 暂不做组级磁盘账:撤掉 `topDiskGroups`/对应 MCP 工具或让它明确返回"暂不支持";(b) 补组级磁盘增量:`GroupSample`/`MinuteAggregate` 增加字段并在 `HistoryEngine.insertMinute` 真正落列。拍板前不要实现。

证据见 `../REPORT.md` §高5。关键锚点:`HistoryDatabase.swift:15-16`、`HistoryEngine.swift:524-539`、`InsightQueries.swift:363-400`、`McpEyesSupport.swift:199-200`、`McpEyesTests.swift:32`、`HistoryDatabaseTests.swift:53-74`。

**Agent Brief(拍板后):**
1. 按选定方向改写/读两侧,删掉制造假数据的手写 INSERT;用**真实 ingest→query 闭环测试**钉死(生产写入路径产出 → 查询断言),而不是另写一条手写夹具。
2. 加一条"查询引用的列必须有生产写入方"的结构性断言(列级,不只是 `HistoryDatabase.tableNames` 的表级断言),防同类契约漂移复发。

**验收:** 生产真实数据下 `top_disk_io` 的输出与语义一致;闭环测试绿;不再有手写不存在的列值的测试。

## 核实(2026-11-24)

真问题,已实测:MCP `top_disk_io` 返回 3 个组读写全 0 KB 并称「部分分钟缺数据」;生产 sample_min 11237 行 disk_r/disk_w 全空。待用户二选一(撤工具 / 补组级磁盘采集)。
