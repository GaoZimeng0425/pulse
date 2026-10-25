# 历史仪表量走窄表 (ts, key, avg, max),不再逐量加列

P2 传感器趋势量(p2-sensors/08)落成「宽表逐量列」:加一个趋势量要动 7 文件 ~11 处(两张表各
加列的迁移、引擎参数、聚合缓冲、两段 SQL、查询、事件 case、switch)。P3 root helper 会一次
带来多个特权传感器量,这个成本马上被放大。p2-audit/01 ② 与 p2-review/01 ① 的锁补丁已经暴露
过同类「逐量复制形状」的税。

决定(p2-review/09,用户 2026-10-25 拍板):

- **窄表** `gauge_min` / `gauge_hour (ts, key, avg, max)`(key 前置索引);列描述生成方案否——
  它保住宽表查询但每个新量仍要一次迁移,还引入「描述符与 schema 不漂移」的常驻防呆,复杂度
  只是搬家不是消失。
- **读数模型自报** `historyGauges: [GaugeKey: Double]`——口径的唯一出处从 HistoryFeed 搬回
  模型(SMC「全机最热」折算随迁);`FeatureEvent` 三个 per-family 样本 case 收成 `.gauges`。
  加新量 = `GaugeKey` 加 case + 模型自报一行,**零 schema 迁移**。
- **聚合口径单点** `GaugeKey.aggregation`:最热是峰(写 max 列、查询 MAX),其余是均(avg 列、
  AVG);分钟卷积与小时卷积共用。非口径列 NULL——窄行形状新旧一致。
- **存量迁移单向门**:宽列变换进窄表后立即 DROP(用户拍板);迁移首跑前 `HistoryDatabase`
  自动备份库文件三件套(`.pre-gauge-<epoch>.bak`,已有不重复)。GRDB 迁移事务性保证失败
  整体回滚,库停在宽表态。真机库对拍(2026-10-25,131MB 库 20326 行变换):五个既有量在
  固定窗口的 count 与聚合值迁移前后逐位相等。

被否的替代:①列描述生成(见上);②双读过渡(旧数据留宽表、查询层双读直到 30 天存量出窗)
——复杂度要活一个月,一次性变换有备份与事务兜底后没有理由背它;③窄表但保留宽列一个版本作
回滚窗——用户拍板立即删,备份文件即回滚窗。

后果:查询按 key 过滤(量级 30 天 ≈30 万行,SQLite 毫秒级);功率「合计」分项从宽表
COALESCE+FILTER 改为按 ts SUM 在域键再桶均——语义逐位等价(缺域键不计 = COALESCE 0,
全无功率行的分钟不进 AVG = FILTER 剔除)。
