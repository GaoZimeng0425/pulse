# 09: 历史管线收敛——historyGauges 自报 + 窄表迁移(自 06 拆出,单向门)

**What to build:** p2-review/06 的第三轴:历史管线加一个趋势量要改 7 文件 ~11 处
(迁移两张表各加一列、`HistoryIngest`、`HistoryEngine.ingest` 参数、Rollup、两段 SQL、
Queries、`FeatureEvent`、`HistoryFeature` 的 switch);另 SMC"全机最热"口径住在
`HistoryFeed.recordSmc` 而非 SMC 模型。06 已落地分档单循环(轴 1 根治)与走势环收编;
本票收尾最后一段——**涉及 30 天存量数据迁移,schema 单向门,须 ADR + 用户过目**。

**方案方向(p2-review/06 票面原文,待 grill 定稿)**:

- 传感器模型自报 `historyGauges: [GaugeKey: Double]`,`FeatureEvent` 收成 `.gauges` case,
  Feed/Rollup 按 key 累加;
- 存储二选一:**A. 窄表** `(ts, key, avg, max)`——一次迁移覆盖所有未来量,查询按 key 过滤;
  **B. 列描述生成 SQL**——保持宽表查询效率,列清单单点维护,每个新量仍是一次迁移。
- 存量迁移必须**变换不丢弃**(宽行 → 每 gauge 一行窄记录);回滚路径与失败兜底在 ADR 写明。

**Blocked by:** 用户拍板(A/B 取舍 + 存量迁移口径)

**Status:** needs-triage

**待定**:A/B 取舍的量化对比(查询路径:07 票刚落的历史分项药丸查询在两种方案下的形状);
`GaugeKey` 的命名域(与 `Metric`/`MetricSensorFamily` 的关系);迁移放在哪个启动阶段
(与 p2-sensors-v2 迁移的先后链)。

## Comments
