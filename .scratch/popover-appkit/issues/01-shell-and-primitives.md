# 01 外壳 + 刷新机制 + 卡片零件

Status: done(2026-10-30,feat/popover-appkit)
Blocked by: —

## 做什么
- `Pulse/Popover/`(新目录):AppKit 版面板根视图,替换 `PopupPanel` 里的 NSHostingView。
  - 图标页签栏(单行满宽均分,选中 = 强调色 15% 胶囊 + 同色前景;←/→ 切换;tab 记忆跨开合)。
  - 页头:页名 + `hostSummary` 一行 + 右侧运行时长(每分钟刷新)。
  - 滚动区定高 520、无滚动条;告警横幅(有告警才出);底排(开窗 / 设置 / 退出,纯图标 + toolTip)。
  - 处置失败汇总 NSAlert(`DashboardModel.killFailureReport` 有失败才弹)。
  - 可见性:面板开 `setPopoverTab(tab)`、关 `nil`;关时卸下内容树。
- 观察回路 `ObservedUpdater`(withObservationTracking 下一拍合并重放),单测钉:只在读到的属性变化时重放、多次变化合并为一次、停止后不再重放。
- 卡片零件(DESIGN.md §Components 卡片家族同数值):卡壳(两档)、`CardHeader` / `CardSubHeader`、
  `StatValue`、`CardEmptyState`(可带 link 动作)、`CardRowValue`、大数字 `FigureText`(圆体 bold + 等宽 + 负字距 + 半号单位)、
  `MetricBadge`、状态 chip、`MeterBar`、44 柱 `StripChart`、56 点 `AreaTrendChart`、颜色桥。
- 页面分发:每个 tab 一个页面构造入口,本票只接总览以外的空页占位。

## 参照
DashboardView.swift、MenuBarPopoverGate.swift、PillTabBar.swift(MetricIconTabBar)、CardFamily.swift、
OverviewCards.swift(FigureText / MetricBadge / MetricChipView)、StripChartView.swift、MetricTabViews.swift(AreaTrendChartView)、
MeterBar.swift、AlertViews.swift。

## 验收
起 app 点菜单栏:页签栏 / 页头 / 底排与旧版一致,切页签与记忆正常,告警横幅出现时位置一致。
