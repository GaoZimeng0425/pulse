# 11: PulseCore 平台准入线与 SQL 参数绑定

**What to build:** 修复 REPORT 中11:纯逻辑层宣称只依赖 Foundation/GRDB,实际有 Darwin ABI 结构与 CoreGraphics 类型;查询层把 `GaugeKey.rawValue` 直接拼进 SQL,靠无断言的"rawValue 永远 SQL 安全"约定。

**Status:** ready-for-agent

证据见 `../REPORT.md` §中11。关键锚点:`Package.swift:4-6`;`NetworkModel.swift:222-224,250-274`(`if_msghdr2` 布局解析);`RankingBoard.swift:1`、`DevServerModel.swift:1`(仅 `pid_t`);`ChartHoverGeometry.swift:14-20`、`HistoryCurveHover.swift:1`;`HistoryQueries.swift:388,395,402,417,422-431`。

**Agent Brief:**
1. ABI 边界:把 `NetworkRouteRecord.parse` 的 sysctl 回包解析(依赖 `if_msghdr2` 内存布局)移到 `Pulse/Live`,核心层保留按注入偏移/布局描述的纯解析;CoreGraphics 几何函数改用 `Double` 值类型,视图侧转换;删 `RankingBoard`/`DevServerModel` 的多余 `import Darwin`(注意 `GroupingEngine.swift:189` 的 `pid_t` 仅 Foundation 可用,说明这两处可删)。
2. 若评估后决定保留 Darwin 常量(如信号值白名单),修订 ADR-0003 补记写明白名单,不要让注释与代码长期不一致。
3. `HistoryQueries` 的 `key IN (...)` 改成绑定参数(`键集合.map { "?" }.joined()` + arguments),`key.rawValue` 任意字符串都安全;为 `GaugeKey.allCases` 加结构性断言(每个键至少有一条可达查询路径/默认分项),并把 ADR-0007 的边界如实写清:存储零迁移,展示仍需登记。
4. 引用 ADR-0007 的窄表口径,不要顺手改 schema 或迁移逻辑。

**验收:** 核心包不再直接引用内核 C 结构布局与 UI 几何类型;SQL 无字符串拼值;新增 GaugeKey 漏登记会被测试抓住。

## 核实(2026-11-24)

真但被夸大,降为低。报告只引 Package.swift 准入线前半句,原文是「不碰 AppKit / SwiftUI / Darwin **采集调用**」——七处 import 只用类型/常量,属多余 import 非越界;if_msghdr2 解析是纯字节解析 + 稳定 ABI。SQL 拼接只剩 HistoryQueries.swift:422-427 一处,值为封闭枚举字面量,不可注入。**Brief 收窄**:只改这一处为绑定参数 + 删多余 import。
