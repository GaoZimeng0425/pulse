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

**方向(2026-10-25 收尾会话定稿,拆两段落地)**:
- ✅ **轴 1/2/3(本票落地)**:分档单循环——每 provider 一条驱动,可见 5s / 不可见 30s
  (`SensorDriver.adaptiveInterval`,每轮休眠前求值),历史广播 `HistoryThrottle` 节流(每满 30s
  放行 fresh);单循环天然串行,01 加的两把锁删除;功率差分窗回到实测时差。走势环收编核心
  `TrendRing<Value>`(GPU/ANE/网络三处)。
- ➡️ **轴 4(单向门,拆 `p2-review/09` 单独走 ADR + 用户拍板)**:historyGauges 自报 + 窄表/列描述
  迁移——30 天存量数据的 schema 单向门不适合与本票混飞,票面已立 09 并写明方案方向与待定项。

**Blocked by:** ~~`p2-review/01`~~(已合,本票删其锁)

**Status:** done

- [x] `SensorDriver.adaptiveInterval`(nil = 静态档,既有登记不受影响)+ 调度器每轮求值
- [x] `HistoryThrottle`(首轮放行、每满 30s 放行 fresh;时间可注入)
- [x] GPU/功率/SMC 三 provider:gate 从"挡读"改"选节奏",`historySnapshot` 删除,双档并发入口消失
- [x] p2-audit/01 ② / p2-review/01 ① 的两把 NSLock 删除(EnergyModelSensor、SmcSensor),注释改为单驱动串行保证
- [x] 三个 feature 双驱动收一,历史广播走节流;`TrendRing<Value>` 收编三处走势环(GPU/ANE/网络)
- [x] 容器 stats 并发上限:评估后**不加**(见 Comments)
- [x] ADR-0004 追加修订段;核心包 +13 例(HistoryThrottle/TrendRing/分档间隔/单驱动结构)
- [x] check.sh 全绿(799 例 = 核心 441 + app 358)

## Comments

### 容器 stats 并发上限——评估结论:不加(2026-10-25)

①每容器单发 stats 本就有 recv 超时上限(5s),不会无限挂;②p2-audit/02 已把阻塞段挪出
Swift 协作线程池(执行域已归位);③典型 N(运行中容器)<20,docker daemon 侧自己排队,客户端
并发只会省往返;④真加窗口化,慢容器会拖长整轮(整表 all-or-nothing 等全部返回),观感更差。
N>50 的重负载场景出现时再立票。

### 行为变化记档(2026-10-25)

- 不可见期三个传感器的 `reading` 照常更新(30s 节奏,门控视图不读,观察不打脏);走势环在
  不可见期以 30s 节拍继续积累——窗口从"仅可见期"变为"最近 N 个样本(混排节拍)",重开窗口
  走势连续不缺口。
- 稳态成本不变:不可见 30s 恒采与旧历史档逐位同频;可见期 5s 与旧 UI 档同频;省掉的只有
  两档撞车时的那次重复读。
- Live 冒烟 `LiveCoreTickSourceSmokeTests` 在构建负载下自扰一次(87.8% 负载触发静息态断言),
  单跑与整体复跑均绿——与本票改动无关,真机自扰特性记档。

### 执行记录(2026-10-25)

分支 `feat/p2-review-06`(基于 develop,含 05)。核心:`SensorProvider.swift`(协议 + 驱动 +
调度器 + HistoryThrottle)、`TrendRing.swift`(新)、`NetworkModel`(环收编)、`MonitorSpine`
(FeatureEvent 三条注释);Live:三 provider 改造删锁;app:三 feature 单驱动化;测试:三个
传感器测试文件的门控/并发断言改为节奏与单驱动结构断言,`ReentryProbe.swift` 与两个并发探针源
随锁退役删除;ADR-0004 修订段;立票 09。
