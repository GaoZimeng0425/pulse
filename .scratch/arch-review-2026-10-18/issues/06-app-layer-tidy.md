# 06: app target 收边——视图文件去规则、Sensor / Model 命名归位、按层分目录

**What to build:** 05 之后核心层 ↔ app 的边界已由编译器守门,但 app 内部仍难读:视图文件夹带规则与编排、`*Sensor` 一词跨两层指两样东西、55 个文件平铺。本票只做搬家、改名、改注释与目录归位,**运行期行为零变化**。

**Status:** done

**Blocked by:** 无(05 已结项)

背景(2026-10-20 架构复查,用户拍板立票):

- 视图文件里一半是规则:`OverviewCards.swift` 夹 `StatusBadgeRules` 与 `MetricCardModel` 折叠;`MenuBarBadge.swift` 夹槽位配置、组合规则与 LRU;`DashboardView.swift` 夹结束进程编排 `KillRequestFlow`
- 命名漂移:纯逻辑进包后叫 `DiskModel` / `NetworkModel` / `BatteryModel`,app 侧 `*Sensor.swift` 只剩 Live 适配器与 Provider;但 `PulseTests/*SensorTests` 大半在测核心类型,五处注释仍写"纯逻辑在 XxxSensor";app 的 `CoreTickDiffer.swift` 里只有 `LiveCoreTickSource`(`CoreTickDiffer` 本身是核心类型,撞名)
- app 的三层(Live 适配器 / 功能模块 / 视图)目录上不可见

## 范围

视图文件去规则(准入线同 05:只依赖 Foundation 的进包;碰 SwiftUI `Color` / AppKit / `SystemMonitor` 的留 app,但单独成文件):

- [x] `StatusBadge` + `StatusBadgeRules` → PulseCore;`StatusBadge.chip`(SwiftUI Color)留 app
- [x] `MetricCardModel` / `MetricCardStat` / `MetricCardChip` 及各卡 builder、`BatteryChargeStatus.chip` → app 独立文件(字段含 `Color`,不进包)
- [x] `MenuBarBadgeMetric` / `MenuBarBadgeConfiguration` / `MenuBarBadgeData` / `LRUBoundedCache` → PulseCore;`MenuBarBadgeContent` + `MenuBarBadgeComposer`(NSFont 量字宽)→ app 独立文件;`MenuBarBadge.swift` 只留渲染器
- [x] `KillConfirmationDialog` + `KillRequestFlow`(NSAlert + SystemMonitor)→ app 独立文件;`KillFailureAlert`(ViewModifier)留视图

命名归位(约定:**PulseCore 的 `XxxModel` = 纯逻辑与协议;app 的 `XxxSensor` = Live 适配器 + SensorProvider**):

- [x] `PulseTests/{Disk,Network,Battery}SensorTests` 拆分:测核心类型的用例移进包测试 `{Disk,Network,Battery}ModelTests`;只测 Provider / Live 的留原名
- [x] `CoreTickDifferTests` 同理拆分:`CoreTickDiffer` 用例进包,Live 冒烟留 app
- [x] app `CoreTickDiffer.swift` → `LiveCoreTickSource.swift`
- [x] 修正过时注释:`DiskCardViews.swift:5`、`NetworkCardViews.swift:5`、`MenuBarBadge.swift:76`、`LiveBatterySourceSmokeTests.swift:6`、`LiveDiskSourceSmokeTests.swift:6`

分目录(`createIntermediateGroups` 已开,xcodegen 自动成组):

- [x] `Pulse/App/`:入口与装配(PulseApp、MonitorAssembly、SystemMonitor、LogService、InertSources)
- [x] `Pulse/Live/`:OS 接缝的真实现(`Live*`、`*Sensor`、nettop、通知发送、ProcArgs、HostInfo 等)
- [x] `Pulse/Features/`:`@Observable` 功能模块与其偏好存储、处置编排
- [x] `Pulse/Views/`:SwiftUI 与视图模型(含 DashboardModel、MetricCardModel)
- [x] ADR-0003 补记目录约定与 Sensor / Model 命名约定

## 不做

- app 内再加编译器墙(视图层独立模块):目前无越界实例,收益低于成本
- `PulseTests/` 分目录、包的 public 面收窄(05 留的后续)
- 任何行为或外观变化

## 约束与验收

- 无新行为,不加新测试缝;已有用例随被测代码搬家,`sh scripts/test.sh` 全绿且**用例总数不减**(基线实测:`func test` 598 个,核心 300 + app 298 例执行)
- 漂移断言(`StatusBadgeRules.systemHighLoadThreshold == SystemMonitor.redThreshold`、徽标 CPU 红线同款)要用 app 类型,留 PulseTests
- 改名 / 搬类型先 ripwire 查影响面;`xcodegen generate` → `sh scripts/check.sh` 全绿

## Comments

- 2026-10-20 落地(分支 refactor/app-layer-tidy):
  - **偏离票面**:`MetricCardModel` / `KillRequestFlow` 原拟进包,实际依赖 SwiftUI `Color` / NSAlert / `SystemMonitor`,改为 app 内独立文件(`Pulse/Views/MetricCardModel.swift`、`Pulse/Features/KillRequestFlow.swift`)。
  - 票外顺手:设置页的配置编辑动作(`replacingSlot` 等四个,原在 `MenuBarBadgeSettingsView.swift`)随 `MenuBarBadgeConfiguration` 进包;进包类型补 `Sendable`(Swift 6 静态属性要求,编译期约束);DESIGN.md / ADR-0003 / `CoreTickModel.swift` / `PulseApp.swift` 里的过时路径与出处一并修正。
  - 测试:`func test` 598 个前后一致,核心 300 + app 298 全绿。
  - 两轴评审(Standards + Spec)意见已收:新写注释的裸工单号改全名、过时引用、`NetworkSensorTests` 死夹具已清。
- 2026-10-20 收尾(用户要求把遗留问题一并修掉):
  - `scripts/test.sh` 计数剔除 `Test Suite '...' passed/failed` 套件行(此前每多一个套件虚高一,拆分后显示 676);现与实际用例数一致(598)。
  - 拆分产生的重复夹具(Disk `raw` / `counters`、Network `counters`、Battery `raw`)收进包内新 target `PulseCoreTestSupport`(`DiskFixture` / `NetworkFixture` / `BatteryFixture`),调用点经 ast-grep 改写。包内测试按 target 依赖;PulseTests 由 project.yml 直接编译同一目录源码——作为产品链接时 Xcode 会把 PulseCore 静态链进测试包,与动态库冲突(05 的双份元数据坑,实测构建即报错)。
  - `NetworkModelTests` 里拆分后无人调用的 `state(_:running:)` 重载删除(删后编译通过即证)。
  - `docs/probes/06-network-rate.swift` 补运行脚本 `docs/probes/06-network-rate.sh`(两层源去 `import PulseCore` 同模块编译),本机实跑通过;`docs/research/dust-reference.md` 路径更新。
