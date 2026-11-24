# 12: 低风险结构债包——目录分组、句柄封装、格式化与样板收敛

**What to build:** 打包处理 REPORT 低风险段:①PulseCore 105 文件平铺、②GRDB 裸句柄进入 public API、③格式化函数散落在 View 文件、④三处同构历史编排与三份 UserDefaults 样板。

**Status:** ready-for-agent

证据见 `../REPORT.md` §低风险。关键锚点:`Packages/PulseCore/Package.swift:20-28`;`HistoryDatabase.swift:49,98`、`HistoryEngine.swift:97`;`AgentViews.swift:14-52`、`CleanerViews.swift:88-107`;`GpuFeature.swift:47-60`/`PowerFeature.swift:54-68`/`SmcFeature.swift:29-42`;`CleanExclusionsStore`/`CleanScanRootsStore`/`ProjectRootsStore`。

**Agent Brief:**
1. PulseCore:先做目录分组(History/Grouping/Ranking/Sampling/Sensor/Clean/Agent/Mcp)并在 ADR-0003 补记写子域依赖方向;**不为拆 target 而拆**——`FeatureEvent` ↔ `RoundContext` 目前成环,真要拆需先抽中立类型层,那是更大的单向门,不在本票。可加 arch lint 防新文件乱放。
2. 连接工厂收口:public 面只暴露 `read`/`write` 闭包与 `openReader`,调用方拿不到裸 `DatabaseQueue`;加测试断言 `openReader` 连接写路径确实被拒。注意 app 侧 `import GRDB` 读外部 agent 库的场景,不要误伤。
3. 格式化:View 文件里的文件级全局函数迁 `PulseFormat`/`AgentFormat`(纯 Foundation 逻辑进 PulseCore),`agentsAccent` 归入 `MetricAccent.swift` 身份色表;口径一处、调用多处。
4. 同构编排:在 Core 增 `GaugeHistoryRelay`(持有 throttle + 广播闭包)与 `TimedTrendRing<Value>`(值/时刻成对 append,等长由类型保证),三个 feature 改用;三份 `[String]` UserDefaults store 抽一个薄泛型/模板(键名仍是持久化契约,不改 UserDefaults 键)。

**验收:** 不引入行为/口径变化(逐位等价);各子域有明确目录与依赖说明;check.sh 全绿。若任一小项成本超预期,可单独拆票,不必全部塞进一次提交。

## 核实(2026-11-24)

一半风格偏好。值得做:GRDB 句柄收口(openInMemory/openReader/HistoryEngine.init 暴露 DatabaseQueue)、agentsAccent 归身份色表。其余(目录分组、三处同构编排、三份 UserDefaults 样板)维持现状,碰到再顺手。注:PulseCore 现 100 文件,CleanerViews.swift:87 是 private static 非全局函数。
