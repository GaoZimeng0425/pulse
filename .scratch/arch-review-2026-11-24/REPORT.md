# 架构审查总报告(2026-11-24)

范围:develop @ `f9085a2`,全仓只读审查,未改代码。五路并行评审(App 装配 / Feature-Live 边界 / PulseCore 包 / SwiftUI 视图层 / 进程边界与持久化),跨轴去重后按严重度排序。上次审查见 `.scratch/arch-review-2026-10-18/REPORT.md` 与 `.scratch/p2-review/REPORT.md`;已记档取舍(ADR-0003/0006/0007/0009、视觉宪法已知偏差)不计入发现,只在代码违反时报告。

## 核实结论(2026-11-24,逐票对照代码)

现象基本属实,严重度多数被夸大。仍是真问题且会让用户看到错误数据的只有 **01**(能耗快照无判龄)
与 **04**(top_disk_io 全 0,已实测)。05/06/08/10 由 `.scratch/arch-clean/` 取代;09 暂缓;
02/03/07/11/12 降级并收窄 Brief;核实时另发现 13(主窗口离屏拉回的坐标系疑似缺陷)。
各票末尾「核实」段有依据。

## 总体判断

架构决策本身成熟:模块间只走 `MonitorHost` + `FeatureEvent`,不互持引用;`@unchecked Sendable` 盒子前提与实现一致;历史层纯/脏分离、`GaugeKey.aggregation` 口径单点;组件抽象(CardFamily / RowMetrics / RankingListCard)是真内聚。当前债务集中在四个系统性主题:

1. **边界只靠评审守护**——ADR-0003 的"视图只读模块状态、不直调 Live"在清理/卸载功能上正面失守,且已造成一次线上静默失效;
2. **装配点散落**——`MainWindowView.init` 与 `PulseApp.init` 是清理/卸载的真实工厂,与 `MonitorAssembly` 的"统一工厂"分工不一致;
3. **跨进程契约缺闭环**——helper 快照的时间戳只写不判,清理事务的超时两端不一致,IPC 的连接取消不传给业务;
4. **读写契约靠注释与手写夹具维持**——生产不写的列被 MCP 查询当真数据源,测试用 INSERT 造假掩盖;结构性断言只到表名。

上次审查的"SystemMonitor 单点膨胀"今天表现为**门面对象 + 五份手工清单**;新功能沿最省力路径绕开既定边界,是这批债的共同成因。

---

## 高风险(建议立即立票,见 issues/01–04)

### 高1. 助手快照无新鲜度校验,假健康读数持续灌进历史 → `issues/01`
- `Packages/PulseHelper/Sources/PulseHelperCore/Collector.swift:85,106-114`:采集失败直接 return,保留旧 `collectedAt`(注释明写"调用方按 collectedAt 判龄");
- `Packages/PulseHelper/Sources/pulse-helper/main.swift:34-37`:每 60s 无条件重写快照文件,mtime 永远新、`epochMs` 陈旧;
- `Pulse/Live/EnergyHelperClient.swift:14-33`:只做形状/值域校验,零时间比较;
- `Pulse/Features/EnergyImpactFeature.swift:96-125`:拿 `collectedAt` 只用于展示,每轮照常 `broadcast(.gauges([.energyImpact: total]))`;
- `Pulse/Features/EnergyHelperGate.swift:27-35`:只在**抛异常**时置 `fetchFailing`,陈旧文件读取是"成功"。
- **后果**:助手被卸载/被杀/powermetrics 连续失败后,系统说 enabled → Gate 永远判 `.approvedAwaitingReading`,UI 冻结值,`gauge_min` 每 60s 写一条假水平线。energy-gate-fix 的"四态说实话"对此漏网路径完全失效。

### 高2. 清理/卸载的生产装配住在 View 与 App 入口,View 直接 new Live → `issues/05`
- `Pulse/Views/MainWindowView.swift:59-95`:构造 `CleanerModel`/`UninstallModel` 时直接 `LiveCleanTrashExecutor()`、`LiveCleanActivitySource(...)`、`LiveCleanVolumeSummaries()`、`LiveCleanPermanentDeleter()`;
- `Pulse/App/PulseApp.swift:97-108`:MCP 影子模型把同一套 Live 依赖又 new 一遍(全仓 `CleanerModel(` 仅此两处);
- `:66-68` 自述代价:`scanCache` 漏传 → "测试全绿而正式版从未落盘,关窗即回空态"(2026-11-03 实机)。
- **后果**:击穿 ADR-0003 边界;两份装配无单一事实源,新增依赖必再漏一次;View 无法脱离真 IO 测试。

### 高3. SystemMonitor 门面上帝对象 + 五份模块清单手工同步 → `issues/06`
- `Pulse/App/SystemMonitor.swift:43-134`:18 个透传 accessor;9 个视图持有整个 monitor,约 101 处 `monitor.` 读取(`Pulse/Views/MetricTabStack.swift:133-196` 一个视图读 9 个模块);
- `Pulse/App/MonitorAssembly.swift:40-47,50-93`:注释自认"具名字段 × registry 两份清单靠测试防漂移,漏登记 = 模块静默失联";再加 accessor、`SystemMonitor.live` 装配、`Pulse/App/InertSources.swift:336-380` preview 装配,共五份;
- `PulseTests/MonitorAssemblyTests.swift:46-64` 的 Mirror 断言只数 registry 条数,覆盖不到 accessor 与两份装配。
- **后果**:视图越权(只需电池一行读数却拿到 `terminate()`/`setPopoverTab()`/历史查询);新增功能必拓宽门面。

### 高4. 可见性闸两条消息只有一条防乱序;写路径双主 → `issues/02`
- 排行闸 `SystemMonitor.swift:275-281` 有 `rankingsGateGeneration &+= 1`,`Packages/PulseCore/Sources/PulseCore/Sampler.swift:262-274` 按代号丢弃旧消息;节奏闸 `SystemMonitor.swift:329-336` 的 `Task { await sampler.setPopoverVisible(visible) }` **无代号**,`Sampler.swift:257-260` 接口也无;
- 弹窗 tab 双主:`Pulse/App/MenuBarController.swift:44,126,156-159`(AppKit,实际生效)与 `Pulse/Views/MenuBarPopoverGate.swift:21-23,36-53`(SwiftUI,自己留了 `lastTab` + `onAppear/onDisappear` 写入);控制器 `:124-125` 明说 SwiftUI 钩子时机不可依赖;
- 主窗口相反:`setMainWindowTab(nil)` 全仓只有 `Pulse/Views/MainWindowGate.swift:54` 一处 `onDisappear`,无 AppKit 兜底,ADR-0006 的常驻成本账全押在这个 nil 上。
- **后果**:开→关快速切换 Task 乱序 → 关窗后仍 1s 热采样且布尔幂等写入不会自纠;迟到的 `onDisappear` 可覆盖刚还原的 tab → 弹窗空白。

### 高5. MCP `top_disk_io` 读的是生产永不写入的列,测试造假掩盖 → `issues/04`
- `Packages/PulseCore/Sources/PulseCore/HistoryDatabase.swift:15-16`:明说 `sample_min.disk_r/disk_w` 恒空;
- `Packages/PulseCore/Sources/PulseCore/HistoryEngine.swift:524-539`:INSERT 列清单无 disk 两列,且是唯一写入方;
- `Packages/PulseCore/Sources/PulseCore/InsightQueries.swift:363-400`:`COALESCE(SUM(s.disk_r),0)` 排名;`Packages/PulseCore/Sources/PulseCore/McpEyesSupport.swift:199-200`:把空结果解释成"app 未运行/该时段无样本";
- `Packages/PulseCore/Tests/PulseCoreTests/McpEyesTests.swift:32`:手写 `INSERT ... disk_r, disk_w`;`HistoryDatabaseTests.swift:53-74` 又专门断言该列恒 NULL。
- **后果**:读写契约漂移,MCP 对用户输出全 0 + 错误解释,全量测试绿灯。结构性断言(`HistoryDatabase.swift:460-467`)只到表名,覆盖不到列级写入契约。

---

## 中风险(见 issues/03、07–11)

### 中6. MCP 清理事务超时不闭合 → `issues/03`
`Pulse/Features/McpCleanBridge.swift:38-41` 窗口 60s + 确认 600s 串行相加(最坏 660s),`Packages/PulseMCP/Sources/pulse-mcp/main.swift:212,227,251` 客户端 610s + 5s 宽限 = 615s 就报"未运行/连接失败"。客户端报失败后用户仍可确认,删除照常发生,发起方拿不到结果,AI 可能据错论重试。

### 中7. root daemon 固定路径写 `/tmp` → `issues/07`
`Packages/PulseHelper/Sources/PulseHelperCore/Collector.swift:7-18`:`/tmp/pulse-helper-debug.log` 跟随符号链接打开/创建,root 身份 + 可预测文件名 + 默认权限;特权进程平白多一个文件写原语,日志泄露全机进程名。

### 中8. 核心测试外迁宿主 target → `issues/08`
ADR-0003 承诺"核心测试不起宿主",但 `PulseTests/HistoryEngineTests.swift`(645 行)、`GroupingEngineTests.swift`(891 行)、`RoundSpineTests.swift` 等纯 PulseCore 行为测试都在 PulseTests(`@testable import Pulse` + PulseCore);包内缺写引擎主路径覆盖。拆包的核心收益没拿到,而宿主测试有挂死史(AGENTS.md 记档)。

### 中9. App ↔ Views 依赖倒置、全局服务定位器、构造即启动 → `issues/09`
- `Pulse/Views/MainWindowView.swift:224-255` 的 `static func repositionIfOffscreen()` 是 AppKit/CG 窗口管理,被 `Pulse/App/PulseApp.swift:139,143` 与 `Pulse/App/DockPresence.swift:30` 反向静态调用;`Pulse/App/MenuBarController.swift:321` 直接依赖 `DashboardView.panelSize`;
- `MenuBarController.swift:447-460,489-499` 的 `MainWindowBridge.openWindow` 是全局可变静态量,靠"谁先 onAppear 谁填",不可注入/测试;
- `PulseApp.init` 同时装配、开生产库、绑端口、启动采样、装通知观察者;无法"只构造不启动",测试宿主只能另起空壳(`PulseApp.swift:6-10`);`SystemMonitor.stop()` 从不调用,内层 `Task { @MainActor ... }`(`SystemMonitor.swift:231-250`)无句柄;
- `Pulse/Views/GeneralSettingsView.swift:154-173` 在 View 里直接 `SMAppService.mainApp.register/unregister`、3s 助手轮询;与 `Pulse/Features/EnergyImpactFeature.swift:166-226` 的助手状态桥各管一摊。

### 中10. Feature 注入缝绑死 Live 具体类型 → `issues/10`
`Pulse/Features/UninstallModel.swift:61,68,82-96` 参数是 `LiveAppCatalogFacts`、`CleanActivityBoard`(Live 层 struct),两次直读 `board.current().executablePath`,绕开 `Packages/PulseCore/Sources/PulseCore/CleanBoundary.swift:190` 的 `CleanActivitySource` 缝(对照 `CleanerModel.swift:109` 正确用法);`CleanerModel.swift:408` 直接调 `LiveCleanDirectoryEnumerator.isUserDomain(entry.path)`——"什么算用户域才配 EPERM 提示"是领域规则却住在 Live,注入假枚举器覆盖不到。

### 中11. PulseCore 平台准入线破口 + 查询层 SQL 拼接 → `issues/11`
- `Packages/PulseCore/Package.swift:4-6` 宣称"只依赖 Foundation/GRDB",实际 5 文件 `import Darwin`、2 文件 `import CoreGraphics`;最实质 `NetworkModel.swift:250-274` 用 `MemoryLayout<if_msghdr2>` + `loadUnaligned` 解析内核 C 结构(内核 ABI 进"纯逻辑层");`RankingBoard.swift:1`、`DevServerModel.swift:1` 只为了 `pid_t`,属多余 import(`GroupingEngine.swift:189` 仅 Foundation 也能用);
- `HistoryQueries.swift:388-431` 把 `GaugeKey.rawValue` 拼进 `WHERE key IN ('...')`,依赖"rawValue 永远 SQL 安全"的无断言约定;ADR-0007 的"零迁移"只解决存储,查询枚举仍有 9 路 switch 要同步登记。

### 中12. IPC 健壮性三连 → `issues/03`
`McpCleanSupport.swift:12-21,55-141` 端点/DTO 无 `protocolVersion`,app 更新后旧 MCP 进程解码失败统一报"查询失败";`Pulse/App/CleanIPCService.swift:113-137` 半开连接可永久挂住回调,`:158-168` 连接取消不传桥,无并发连接上限;`:11-31,62-104` 的 `@unchecked Sendable` 注释声称"全部触点被队列约束",但 `stop()` 在调用者线程写 `listener = nil`、`deinit` 在释放线程读同一属性。

---

## 低风险 / 结构债(见 issues/12)

- PulseCore 105 文件平铺单一 target(`Packages/PulseCore/Package.swift:20-28`),子域无目录/边界,且 `FeatureEvent` ↔ `RoundContext` 让 spine 与 feature 类型层互为依赖;建议先目录分组 + arch lint,不为拆而拆。
- GRDB 句柄进入 public API(`HistoryDatabase.swift:49,98`、`HistoryEngine.swift:97`),单写者/`query_only` 纪律靠注释与注入。
- 格式化散落:`Pulse/Views/AgentViews.swift:14-52`、`CleanerViews.swift:88-107` 文件级全局格式化函数绕过 `PulseFormat` 单一出处。
- 同构编排三抄:`GpuFeature.swift:47-60`/`PowerFeature.swift:54-68`/`SmcFeature.swift:29-42` 逐字复制 `HistoryThrottle + markedDriver + 广播`,Gpu/Power "双环同容量"靠注释守;`CleanExclusionsStore`/`CleanScanRootsStore`/`ProjectRootsStore` 三份同款 UserDefaults 路径数组样板。

---

## 做得好的地方

1. **模块间通信边界兑现 ADR-0003**:`MonitorSpine.swift:156-191` 的 `MonitorHost` 四回调 + `FeatureEvent` 广播是模块触碰主干/彼此的唯一出口,实际只有 3 个 `onEvent` 实现、5 个广播点,无 Feature 互持实例。
2. **并发纪律细节到位**:约 20 处 `@unchecked Sendable` 几乎都有前提注释且与实现一致,锁内无 await,`HistoryFeature` 的 AsyncStream 有唯一长寿消费者并 `finish()`;排行闸 generation 是事故沉淀的写法。
3. **历史层纯/脏分离扎实**:`HistoryRollup` 全纯值,`HistoryEngine` 写入收在单事务、时间全注入,`GaugeKey.aggregation` 是写/迁移/查询共用真口径,`openReader()` 的 `query_only` 让读者无法误写。
4. **组件抽象内聚**:`CardFamily`/`RowMetrics`/`PageHeader`/`RankingListCard` + `MetricTabStack.blocks` 让 SwiftUI List 与 NativeList 读同一份卡片序列,不是为抽象而抽象。

## 建议修复顺序

- **P0(数据可信度与状态漂移)**:01 助手判龄 → 02 节奏闸代号 + 写路径所有权 → 03 清理事务超时闭合 → 04 磁盘列读写契约(需产品拍板）。
- **P1(边界回归)**:05 清理装配收口 → 06 门面/清单 → 07 root 日志。
- **P2(可维护性)**:08 测试归位 → 09/10 依赖方向 → 11/12 协议健壮性与查询守门。
