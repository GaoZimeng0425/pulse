# arch-clean/03 视图按类型取模块,删 SystemMonitor 转发属性

Status: ready-for-agent
Type: task

## 背景

`Pulse/App/SystemMonitor.swift:43-134` 有 18 个只做 `features.x` 转发的属性;9 个视图类型持有整个
`SystemMonitor`(MetricTabStack 读 34 处、DashboardModel 读 27 处),因而都能拿到 `terminate()` /
`setPopoverTab()` 等与自己无关的入口——接口隔离违反最明显的一处。

核实记录见 `.scratch/arch-review-2026-11-24/issues/06`(原票「五份清单漏一份即静默失联」被夸大:
四份由编译器强制同步,registry 一份有 Mirror 计数测试拦着)。

## 要做

1. 用从 registry 派生的按类型取模块(`monitor[BatteryFeature.self]` 一类)替换 18 个转发属性;
   `@Observable` 追踪仍落在各 feature 实例上,不得变成值快照。
2. 只读单一模块的视图改为直接接收那个 feature;同时读多个模块的视图(MetricTabStack、DashboardModel)
   可保留持有 monitor,不为它们设计投影接口。
3. 不动 registry / Mirror 测试 / 装配清单(已由编译器与测试守住)。

## 验收

- [ ] SystemMonitor 无转发属性;只需一个模块的视图不再持有整个 monitor
- [ ] 视图刷新行为不变(手动验收:弹窗与主窗口各 tab 数值照常跳动)
- [ ] `sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票,取代 arch-review-2026-11-24/06(收窄:不做投影协议、不重做清单)。优先级最低,可等触及时顺手做。
