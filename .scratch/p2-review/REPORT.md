# P2 收尾审查报告(2026-10-24)

范围:`git diff d5f9d6f...HEAD`(P2 立项合并 25f41e4 之前的 develop → ae7de84,27 个非合并提交,
约 9k 行)。`/code-review` 三轴并行:架构 / Standards(`CODING_STANDARDS.md` + `AGENTS.md` +
`DESIGN.md` + Fowler smell 基线)/ Spec(`.scratch/p2-sensors/spec.md` + 01..08 票 + p2-audit 01..04 票)。
已在 p2-audit 修过的项不重复报;修了一半的照报。高影响项均经主会话对照代码复核。

## 总评

分层守住了:PulseCore 新增文件只 import Foundation,六个源协议都在核心包,registry 防漂移测试在场。
问题集中在三处:**p2-audit/01 ②双档竞态只修了一半**(两轴独立报出、已复核)、数据口径的几处
"伪造 0 / 冻结值"、以及调度与可见性按家族手写导致的 Shotgun Surgery 苗头。

## 架构轴(7)

1. **【高】双档竞态只修了一半**:`EnergyModelSensor.swift:152`、`SmcSensor.swift:223` 的
   `source.read()` 在锁外;`LiveEnergyModelSource.ensureSubscription()` 与
   `LiveSmcSource.discoveredKeys` 无锁并发写;注释声称"锁也护源"与代码不符;乱序折算
   elapsed≤0 → 交 fresh 全 0。→ `p2-review/01`(止血);根治见 `p2-review/06`。
2. **【中高】弹窗门控过粗**:五 feature 闸 = `visibility.popover || xxxPage`,弹窗停在 CPU tab 也全开
   P2 采集(docker stats / 蓝牙扫描 / SMC 全键)。→ `p2-review/05`。
3. **【中】加一页 Shotgun Surgery**:`MonitorVisibility` 四个互斥 bool + `SystemMonitor` 四个
   `set*PageVisible` + `MainWindowView` 三处调用;切一次页派发 5 次 × 14 模块。→ `p2-review/05`。
4. **【中】历史管线加一个趋势量改 7 文件 ~11 处**;SMC"全机最热"口径住在 `HistoryFeed.recordSmc`。
   → `p2-review/06`。
5. **【中】30s 历史驱动(Gpu/Power/Smc)与走势环各写多份**;功率两档共用差分账本,可见时历史档
   只覆盖最近 5s 窗。→ `p2-review/06`。
6. **【低】蓝牙授权只在刷新事件时推一次闸**,provider tick 前不复核;GATT 探针关闸后不取消
   (后者 → `p2-review/02`)。
7. **【低】分层小漏**:`MetricCardModel.swift:270` 调视图层 `PowerDomainsCardView.wattsText`
   (与 `PulseFormat.watts` 两套);容器 stats 每容器一条阻塞线程无并发上限。→ `p2-review/03`。

## Standards 轴(6 硬伤 + 判断题)

硬伤:
1. 双档竞态(同架构 1,违反"并发纪律"第 2、3 条)。→ `p2-review/01`
2. 单测碰真栈(违反"测试纪律":蓝牙/音频栈不进单测):`BluetoothSensorTests.swift:130` Live 冒烟
   调 IOBluetooth;`SoundSensorTests.swift:60` 真读 CoreAudio;`MonitorAssemblyTests.swift:30`
   走 `BluetoothFeature` 便利构造器 → `LiveBluetoothAccessControl` + `UserDefaults.standard`。→ `p2-review/02`
3. 伪造 0(违反"读失败 nil 穿透"):`PowerFeature.swift:33,77` `watts[.ane] ?? 0`;
   `ContainerModel.swift:167` CPU 字段缺失给 0.0。→ `p2-review/01`
4. DESIGN.md:五个新卡片文件数字用 `design: .monospaced`(应 `monospacedDigit()`);定宽
   36/44/48/52/56/64 与 `Color.secondary.opacity(0.4)` 不在令牌表。→ `p2-review/03`
5. 新写注释工单未写全名(issue-tracker.md 末条)约 13 处。→ `p2-review/03`
6. 注释失真:`MetricModel.swift:11`"声音/蓝牙有意砍掉"(case 已在);`ContainerCardViews.swift:10`
   "运行中置顶"(全链路无排序,行序随 TaskGroup 完成序乱跳)。→ `p2-review/03`

判断题:`ContainerSensorTests:118` 心跳断言几乎不可能失败;关蓝牙开关后在途 GATT 探针仍扫 ~20s;
卡片"名称 + 数值"行结构五处重复(Duplicated Code);容器状态字符串 `"running"` 三处比较
(Primitive Obsession);`drainGattBuffer` Middle Man。

## Spec 轴

已落实:节奏矩阵、11 tab、徽章四槽不动、无网络/子进程、未知键归组、功率差分三防御。

实现有误(c):
- 电池功率冻结:`DashboardModel.swift:53` 读 `monitor.smc.reading`,该值只有 UI 档更新
  (`SmcFeature.swift:43-47`)——只开电池页时显示上次访问传感器页的 PPBR 冻结值,不回退 V×A。→ `p2-review/01`
- 唤醒首轮未丢弃:首读与断档轮以 `.fresh` 交全 0(`PowerModel.swift:127,134`),被
  `HistoryFeed.swift:134` 入历史、进 ANE 走势,拉低分钟均值。→ `p2-review/01`
- 蓝牙"歧义即弃"未做到:级②名 / 级③ID 只查锚侧唯一(`BluetoothModel.swift:339,346`),两条同名
  候选挂同一锚、同级后到者胜;歧义候选进无锚池单独成行带电量。→ `p2-review/02`

缺失(a):派生值无"最快风扇";风扇 `minRpm` 解析未用;历史页温度只看 CPU 均值、功率只看合计
(各路列已落库)。→ `p2-review/04`(先拍板做或删)

Spec 漂移(d):Story 12 蓝牙默认关;Story 21 阈值原文自相矛盾;Story 16/17 弹窗组形态(温度组
带明细卡违背 Story 17,**需拍板**);Story 23 窗口未加宽,靠 `.selectedOnly`;蓝牙睡眠停扫靠进程
挂起。→ `p2-review/04`

## 票

| 票 | 内容 | Status |
| --- | --- | --- |
| `p2-review/01` | 数据正确性:双档竞态止血 / 电池功率冻结 / 首轮 0 入历史 / 伪造 0 | ready-for-agent |
| `p2-review/02` | 蓝牙:歧义即弃 / GATT 关闸取消 / 单测隔离真栈 | ready-for-agent |
| `p2-review/03` | 小修:注释 / DESIGN 令牌 / 容器排序 / 格式化收口 / 测试断言 | ready-for-agent |
| `p2-review/04` | Spec 回写(拍板项 A–D 已定,2026-10-24) | ready-for-agent |
| `p2-review/05` | 可见性按 tab 门控(架构) | needs-triage |
| `p2-review/06` | 分档驱动 + 历史量收敛(架构) | needs-triage |
| `p2-review/07` | 历史页分项查看(次级药丸选择器) | ready-for-agent |
| `p2-review/08` | 传感器 tab:弹窗只放派生值 + 最快风扇 + 风扇进度条按上下限 | ready-for-agent |
