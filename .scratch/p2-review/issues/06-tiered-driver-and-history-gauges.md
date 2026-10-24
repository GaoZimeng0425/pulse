# 06: 分档驱动 + 历史量收敛——一个 provider 一条循环,加一个趋势量只动一处

**What to build:** 2026-10-24 P2 收尾审查架构轴 1(根治)、4、5(`p2-review/REPORT.md`)。

1. **双档 = 并发入口**:Gpu / Power / Smc 各由 5s UI 档 + 30s 历史档两条 driver 驱动,同一 provider
   并发被读——p2-audit/01 ② 与 `p2-review/01` ① 都是给这个形状打锁补丁。功率两档共用一个差分账本,
   可见时历史档只拿到最近 5s 的窗,只覆盖 1/6 时间,历史口径随可见性变。
2. **30s 历史驱动与走势环手写多份**:`GpuFeature.swift:33-46`、`SmcFeature.swift:27-40`、
   `PowerFeature.swift:42-54` 三份历史 driver;GPU / 功率 / 网络各写走势环。
3. **历史管线加一个量改 7 文件 ~11 处**:迁移两张表各加一列、`HistoryIngest`、`HistoryEngine.ingest`
   参数、Rollup、两段 SQL、Queries、`FeatureEvent`(:200-204)、`HistoryFeature` 的 switch;另 SMC
   "全机最热"口径住在 `HistoryFeed.recordSmc`(:121)而非 SMC 模型。

**方向(待定稿)**:
- 核心包一个分档驱动:每 provider 一条循环,可见 5s / 不可见 30s,每满 30s 顺带广播历史——单循环
  天然串行,锁可删;历史档差分窗 = 实测 30s 而非最近 5s。
- 传感器模型自报 `historyGauges: [GaugeKey: Double]`,`FeatureEvent` 收成一个 `.gauges` case,
  Feed/Rollup 按 key 累加;存储改窄表 `(ts, key, avg, max)` 或由列描述表生成 SQL——涉及 schema
  迁移(30 天存量数据),是单向门,需 ADR。
- 走势环收成核心包一个类型。
- 顺带评估:容器 stats 每容器一条阻塞线程,加并发上限。

**Blocked by:** `p2-review/01`(先止血,再根治;根治落地后删 01 加的锁并改注释)

**Status:** needs-triage

**待定**:窄表迁移 vs 列描述生成的取舍;分档驱动与 `SensorScheduler` / ADR-0004 薄协议的关系;
建议走 `/improve-codebase-architecture` → `/grill-with-docs` 定形状,再 `/to-spec` 拆票。

## Comments
