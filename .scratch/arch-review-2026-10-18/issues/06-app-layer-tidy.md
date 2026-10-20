# 06: app target 收边——视图文件去规则、Sensor / Model 命名归位、按层分目录

**What to build:** 05 之后核心层 ↔ app 的边界已由编译器守门,但 app 内部仍难读:视图文件夹带规则与编排、`*Sensor` 一词跨两层指两样东西、55 个文件平铺。本票只做搬家、改名、改注释与目录归位,**运行期行为零变化**。

**Status:** ready-for-agent

**Blocked by:** 无(05 已结项)

背景(2026-10-20 架构复查,用户拍板立票):

- 视图文件里一半是规则:`OverviewCards.swift` 夹 `StatusBadgeRules` 与 `MetricCardModel` 折叠;`MenuBarBadge.swift` 夹槽位配置、组合规则与 LRU;`DashboardView.swift` 夹结束进程编排 `KillRequestFlow`
- 命名漂移:纯逻辑进包后叫 `DiskModel` / `NetworkModel` / `BatteryModel`,app 侧 `*Sensor.swift` 只剩 Live 适配器与 Provider;但 `PulseTests/*SensorTests` 大半在测核心类型,五处注释仍写"纯逻辑在 XxxSensor";app 的 `CoreTickDiffer.swift` 里只有 `LiveCoreTickSource`(`CoreTickDiffer` 本身是核心类型,撞名)
- app 的三层(Live 适配器 / 功能模块 / 视图)目录上不可见

## 范围

视图文件去规则(准入线同 05:只依赖 Foundation 的进包;碰 SwiftUI `Color` / AppKit / `SystemMonitor` 的留 app,但单独成文件):

- [ ] `StatusBadge` + `StatusBadgeRules` → PulseCore;`StatusBadge.chip`(SwiftUI Color)留 app
- [ ] `MetricCardModel` / `MetricCardStat` / `MetricCardChip` 及各卡 builder、`BatteryChargeStatus.chip` → app 独立文件(字段含 `Color`,不进包)
- [ ] `MenuBarBadgeMetric` / `MenuBarBadgeConfiguration` / `MenuBarBadgeData` / `LRUBoundedCache` → PulseCore;`MenuBarBadgeContent` + `MenuBarBadgeComposer`(NSFont 量字宽)→ app 独立文件;`MenuBarBadge.swift` 只留渲染器
- [ ] `KillConfirmationDialog` + `KillRequestFlow`(NSAlert + SystemMonitor)→ app 独立文件;`KillFailureAlert`(ViewModifier)留视图

命名归位(约定:**PulseCore 的 `XxxModel` = 纯逻辑与协议;app 的 `XxxSensor` = Live 适配器 + SensorProvider**):

- [ ] `PulseTests/{Disk,Network,Battery}SensorTests` 拆分:测核心类型的用例移进包测试 `{Disk,Network,Battery}ModelTests`;只测 Provider / Live 的留原名
- [ ] `CoreTickDifferTests` 同理拆分:`CoreTickDiffer` 用例进包,Live 冒烟留 app
- [ ] app `CoreTickDiffer.swift` → `LiveCoreTickSource.swift`
- [ ] 修正过时注释:`DiskCardViews.swift:5`、`NetworkCardViews.swift:5`、`MenuBarBadge.swift:76`、`LiveBatterySourceSmokeTests.swift:6`、`LiveDiskSourceSmokeTests.swift:6`

分目录(`createIntermediateGroups` 已开,xcodegen 自动成组):

- [ ] `Pulse/App/`:入口与装配(PulseApp、MonitorAssembly、SystemMonitor、LogService、InertSources)
- [ ] `Pulse/Live/`:OS 接缝的真实现(`Live*`、`*Sensor`、nettop、通知发送、ProcArgs、HostInfo 等)
- [ ] `Pulse/Features/`:`@Observable` 功能模块与其偏好存储、处置编排
- [ ] `Pulse/Views/`:SwiftUI 与视图模型(含 DashboardModel、MetricCardModel)
- [ ] ADR-0003 补记目录约定与 Sensor / Model 命名约定

## 不做

- app 内再加编译器墙(视图层独立模块):目前无越界实例,收益低于成本
- `PulseTests/` 分目录、包的 public 面收窄(05 留的后续)
- 任何行为或外观变化

## 约束与验收

- 无新行为,不加新测试缝;已有用例随被测代码搬家,`sh scripts/test.sh` 全绿且**用例总数不减**(基线:核心 222 + app 376 = 598,开工前实测复核)
- 漂移断言(`StatusBadgeRules.systemHighLoadThreshold == SystemMonitor.redThreshold`、徽标 CPU 红线同款)要用 app 类型,留 PulseTests
- 改名 / 搬类型先 ripwire 查影响面;`xcodegen generate` → `sh scripts/check.sh` 全绿

## Comments
