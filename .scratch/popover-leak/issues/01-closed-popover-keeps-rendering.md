# 01: 弹窗关闭后视图树不销毁、逐轮继续重算——隐形观看态吞掉稳态

**What to build:** 让菜单栏弹窗(`MenuBarExtra` `.window` 样式,内容 `DashboardView`)**关闭后不再逐轮重算**。现状:弹窗被点开一次再关掉,视图树(含 `RankingCardView` / `RankingRowView` / `StripChartView` 等)仍活着,每轮采样落地都重评估 + 布局周期,直到进程重启——辅助功能报 0 个窗口,采样栈里却整页在渲染。结果是"窗口全关"的稳态在用户看过一眼弹窗之后**悄悄变成观看态**,常驻成本账全部失真。

**Status:** needs-triage
**Category:** bug(性能)

## 为什么现在开(2026-10-21)

- badge-hysteresis/01 复测时抓到:用户每次都关了窗,AX 查 Pulse 0 窗口,15s `sample` 里仍有 RankingRowView 27 / RankingListRow 12 / DashboardView 8 / StripChartView+OverviewCards 4;30s sample 里 `NSDisplayCycleFlush` → `_sizeThatFits` 768 点,主线程其余空闲——**没有窗口却在做布局周期**。优雅退出 + `-ApplePersistenceIgnoreState YES` 重启、不碰弹窗后指纹全 0,同口径稳态窗 2.79% → 0.96%。
- 影响面:只要本次启动后点开过一次弹窗,之后的"稳态"都是观看态。resident-cost/01 的 1.07–1.09% 基线是在刚合并重启、未开弹窗的会话里测的,所以没撞上;但用户日常常驻**天天都会点弹窗**——真实常驻成本比账面高得多(当晚观测 2.79% 含机器负载放大)。这比徽标迟滞的杠杆大。
- 与 resident-cost/01 记录的"点不开"事件(主线程单趟 CA 提交撞繁忙 WindowServer)可能同源:关着的弹窗仍在逐轮提交布局。

## 方案要点与开放问题

1. **先复现定位(30 秒协议,立票时未做,避免扰动复测)**:干净重启 → 15s 指纹全 0 → 用户点开弹窗再关 → 再 15s 指纹。若视图名回来 = 弹窗树泄漏确认;同时用主窗口做一遍区分两者(`MainWindowView` 关窗注释写着"关窗只藏窗",可能同病)。
2. **既有可见性信号已到位但只管数据不管视图**:`DashboardView` 的 `.onAppear` / `.onDisappear` 已驱动 `monitor.setPopoverVisible`(采样 1s/5s 节奏 + `MonitorVisibility.popover` 门控排行传感器,nettop 确实停了);泄漏的是 SwiftUI 视图层——树活着、observable 读数每轮变、body 每轮重算。
3. **候选修法(实施者按复现结果定)**:
   - A. 用同一可见性信号门控视图:弹窗不可见时 `DashboardView` body 短路为占位(不读任何 observable),可见时再读——改动面小、与现有信号同源;开弹窗瞬间要立刻恢复真数据(onAppear 先于首帧)。
   - B. 查清 `MenuBarExtra(.window)` 为何不销毁内容(SwiftUI 行为,可能不可控),若能销毁优先销毁。
   - 主窗口若同病,同一门控思路(`MonitorVisibility.moduleRankings` 已有)。
4. **验证口径**:同 badge-hysteresis/01 复测协议(指纹模式含 RankingRowView / RankingCardView / DashboardView / MainWindowView,窗 ≥15s)。修复后"开过弹窗再关"与"从未开过"两种状态的 150s 稳态窗应一致。

## 验收

- [ ] 复现协议三步记档(干净重启 → 开关弹窗 → 指纹),弹窗 / 主窗口各自结论明确
- [ ] 修复后:开关弹窗后 15s 指纹观看态视图全 0;150s 稳态窗与从未开窗一致(负载相近)
- [ ] 弹窗打开时功能与观感零变化;关闭再打开数据即时(不出现空白帧 / 旧数据闪现)
- [ ] 门控逻辑若可单测则有单测;既有测试零回归;`sh scripts/check.sh` 全绿

## Comments

> 2026-10-21 晚主会话手写立票(未走 /to-tickets),证据来自 badge-hysteresis/01 复测记录。请维护者跑 `/triage`;复现协议第 1 步需要用户点一下弹窗。关联代码:`Pulse/Views/DashboardView.swift`、`Pulse/App/PulseApp.swift`(MenuBarExtra 装配与 onAppear/onDisappear)、`Pulse/App/SystemMonitor.swift`(setPopoverVisible)、`Packages/PulseCore/Sources/PulseCore/MonitorSpine.swift`(MonitorVisibility)。
