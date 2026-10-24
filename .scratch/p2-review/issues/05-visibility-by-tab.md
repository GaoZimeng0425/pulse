# 05: 可见性按 tab 门控——弹窗停在 CPU 页不该开 P2 采集

**What to build:** 2026-10-24 P2 收尾审查架构轴 2、3(`p2-review/REPORT.md`)。可见性目前是
"弹窗开着"一个布尔 + 主窗口四个互斥的页 bool,导致两个问题:

1. **门控过粗**:GPU / Power / SMC / 蓝牙 / 容器五个 feature 的闸都是 `visibility.popover || xxxPage`,
   而弹窗有 tab 栏(`DashboardView.swift:53`)——弹窗停在 CPU tab 也全开 P2 采集(docker 每容器 stats、
   蓝牙扫描 + GATT、SMC 全键)。与 spec Story 12「只在设备页/弹窗组可见时进行」、Story 24 成本纪律不符。
2. **加一页要改多处**:`MonitorVisibility` 旗标与构造参数、`SystemMonitor` 四个 `set*PageVisible`
   (:311-339)、`MainWindowView` 三处调用(:70-73、:77-80、:99-102);切一次页派发 5 次 × 14 模块。

**方向(待定稿)**:`MonitorVisibility` 改为 `popoverTab: MetricTab?` + `mainWindowTab: MetricTab?`,
提供 `isShowing(_ tab:)`;feature 闸改问"我的 tab 是否在任一处显示";切页 = 一次赋值、一次派发。
需与 ADR-0006(窗口可见性门控)对齐,必要时追加 ADR。

**Blocked by:** None

**Status:** needs-triage

**待定**:弹窗 tab 切换的成本收益(切到 GPU tab 时首读延迟 vs 常驻采集);历史档(30s,不看闸)
不受影响需在方案里写明;建议先 `/grill-with-docs` 或 `/improve-codebase-architecture` 定形状再出 Agent Brief。

## Comments
