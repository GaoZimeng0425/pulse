# 06: SystemMonitor 门面收敛——读表面与协调者拆开、清单单一真源

**What to build:** 修复 REPORT 高3:`SystemMonitor` 18 个透传 accessor 把 19 个功能模块聚合到一个 `@Observable` 门面,视图经它拿到全部越权入口;模块登记还要同步五份清单。

**Status:** wontfix

证据见 `../REPORT.md` §高3。关键锚点:`SystemMonitor.swift:43-134,402-437`;`MonitorAssembly.swift:40-47,50-93`(自认两份清单靠 Mirror 测试防漂移);`InertSources.swift:336-380`;`MonitorAssemblyTests.swift:46-64`。

**Agent Brief:**
1. 按类型取模块的 `subscript<M: MonitorFeature>(_ type: M.Type) -> M` 从 registry 派生;删除具名字段与 18 个 accessor,或先保留少量高频 accessor 但收窄视图实际注入面(视图改为只注入具体 feature 或小投影协议,如 `BatteryReading`、`RankRows`)。注意 `@Observable` 追踪语义:视图读的 observable 必须仍是对应 feature 实例,不能变成值快照。
2. registry 作唯一真源;`SystemMonitor.live` 与 preview 共用同一个 `FeatureFactory(env: .live/.inert)`,新模块只在一处登记依赖。保留 Mirror 测试作兜底,但补齐 accessor/装配完整性检查。
3. 本票范围只包含门面与清单;历史喂入编排、磁盘记账账本等粘合逻辑若仍在 SystemMonitor,评估能否下沉为可测类型(与 2026-10-18 高1 的方向一致,已部分完成,不要重复拆已迁出的部分)。

**验收:** 9 个视图不再持有整个 `SystemMonitor`(或只持有不暴露全模块的瘦接口);新增一个功能模块只需改一处登记;全量测试绿。

## 核实(2026-11-24)

真但被夸大:五份清单中四份由编译器强制同步,registry 一份有 Mirror 计数 + 去重测试;未找到越权调用实例。**由 arch-clean/03 取代**(收窄:不做投影协议)。
