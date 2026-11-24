# 10: Feature 注入缝不再绑死 Live 具体类型

**What to build:** 修复 REPORT 中10:`UninstallModel` 的注入参数是 Live 层 DTO/锁盒子,`CleanerModel` 直接调 Live 的领域规则函数——"编译期测试缝"只是把 Live 实现换了层闭包。

**Status:** wontfix

证据见 `../REPORT.md` §中10。关键锚点:`UninstallModel.swift:61,68,82-96,333,408`;`CleanBoundary.swift:190` 的 `CleanActivitySource` 缝;`CleanerModel.swift:109`(正确用法)与 `:408,453-458`(直调 Live)。

**Agent Brief:**
1. 把 `LiveAppCatalogFacts` 正名为纯值 `AppCatalogFacts` 迁回 PulseCore,定义 `AppCatalogFactSource` 协议,由 `MonitorAssembly` 注入 `LiveAppCatalogSource`;`UninstallModel` 不再 import Live。
2. 活动数据:给 Core 增加只读原始样本缝(如 `CleanActivitySampleReading.current() -> [CleanActivitySample]`,含 `executablePath`),由 `SystemMonitor`/工厂持有并注入,替换两处 `board?.current().compactMap(\.executablePath)`;判定口径落到 Core 的推导函数并由 PulseCoreTests 钉死,与 `CleanActivityDerivation` 同源。
3. `LiveCleanDirectoryEnumerator.isUserDomain(_:)` 的领域规则迁到 PulseCore(如 `CleanPathDomain` 纯函数 + 正反例测试),Live 适配器改为调用它;`CleanerModel` 只依赖 Core 缝。
4. 与 `issues/05` 协同:本票只改类型归属与缝,不改装配所在文件;避免两票同处改同一段代码时冲突(先做 05 再做 10,或由实施者合并处理)。

**验收:** `Pulse/Features/` 中不再出现 `Live*` 类型引用;新增同类功能可直接复用 Core 缝;相关测试可在 `swift test` 覆盖。

## 核实(2026-11-24)

真但被夸大:引用位置属实,但「假枚举器覆盖不到」不成立(isUserDomain 是纯函数);真实代价只是进不了 swift test。**由 arch-clean/02 取代**(不新开活动数据接口)。
