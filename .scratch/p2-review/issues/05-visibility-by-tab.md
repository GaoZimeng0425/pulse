# 05: 可见性按 tab 门控——弹窗停在 CPU 页不该开 P2 采集

**What to build:** 2026-10-24 P2 收尾审查架构轴 2、3(`p2-review/REPORT.md`)。可见性目前是
"弹窗开着"一个布尔 + 主窗口四个互斥的页 bool,导致两个问题:

1. **门控过粗**:GPU / Power / SMC / 蓝牙 / 容器五个 feature 的闸都是 `visibility.popover || xxxPage`,
   而弹窗有 tab 栏(`DashboardView.swift:53`)——弹窗停在 CPU tab 也全开 P2 采集(docker 每容器 stats、
   蓝牙扫描 + GATT、SMC 全键)。与 spec Story 12「只在设备页/弹窗组可见时进行」、Story 24 成本纪律不符。
2. **加一页要改多处**:`MonitorVisibility` 旗标与构造参数、`SystemMonitor` 四个 `set*PageVisible`
   (:311-339)、`MainWindowView` 三处调用(:70-73、:77-80、:99-102);切一次页派发 5 次 × 14 模块。

**方向(2026-10-25 收尾会话定稿,证据在 Comments)**:`MonitorVisibility` 改为 `popoverTab: MetricTab?` +
`mainWindowTab: MetricTab?`,家族闸按**内容**门控:`shows(_ family:)` = 任一在场窗口停在展示该家族的
tab(`MetricTab.displayedFamilies`,与 MetricTabStack 卡片组成对齐)。

**Blocked by:** None

**Status:** done

- [x] `MetricSensorFamily` + `MetricTab.displayedFamilies`(总览含 GPU 卡→gpu;GPU 页→gpu+power;传感器/外设/容器各本族)
- [x] `MonitorVisibility` 双 tab 槽 + 派生 popover/mainWindow/moduleRankings/anyWindow(语义不变)+ `shows(_:)`
- [x] 五个 feature 闸改 `shows(.family)`;SystemMonitor 写路径收成 `setPopoverTab` / `setMainWindowTab` 两个
- [x] 弹窗门控上报 tab(进场还原上次所在页、onTabChange 续报);主窗口 gate 引导值与 MainWindowView.init 同式(深链不闪闸)
- [x] ADR-0006 追加修订段;核心包 8 例新测试(displayedFamilies 全表 + shows 语义)
- [x] check.sh 全绿(791 例 = 核心 434 + app 357)

## Comments

### 形状定稿(2026-10-25,收尾会话按票面"待定"三项逐条落)

1. **弹窗 tab 切换的成本收益**:按内容门控的对称推论——首读口径 = 卡片立即显示 lastGood
   (30s 历史档不看闸,数据至多 30s 旧)+ 开闸后 ≤5s 内新鲜(驱动循环 tick 先行,gate 在
   provider 内消费)。与主窗口页切换既有行为**同款**(GPU 页今天就是这么切的),一致性即答案。
2. **历史档不受影响**:写进 `MonitorVisibility.shows` 文档注释与 ADR-0006 修订段——家族闸只管 5s UI 档。
3. **排行闸(anyWindow)刻意不细化到 tab**:弹窗任何 tab 都承载组排行卡(总览/CPU/内存都有
   ranking 槽),细化无收益;nettop 行为与今天逐位一致。
4. **行为变化记档**:主窗口总览页 GPU 卡从仅 30s 档升为总览在场即 5s(观看态成本,稳态不变);
   弹窗停在 CPU/内存/磁盘/网络/电池/历史 tab 不再开五族采集——即本票目的。

### 执行记录(2026-10-25)

分支 `feat/p2-review-05`(基于 develop ea090a1)。改 14 文件:核心 `MetricTabModel`(+family 映射)、
`MonitorSpine`(双槽重写)、`MonitorVisibilityTests`(新,8 例);app 侧 SystemMonitor(7 setter → 2)、
五 feature 闸、三视图接线(MenuBarPopoverGate 上报 tab / MainWindowGate 深链同式引导 + 关窗 nil /
MainWindowView 五写一 + onDisappear 块删除,关窗归 gate)、PulseApp 注释、ADR-0006 修订段。
三个既有测试文件的 `MonitorVisibility(popover: true)` 构造按家族展示地改写(GPU→.gpu、蓝牙→.peripherals、功率→.gpu)。
