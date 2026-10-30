# 窗口内容按可见性门控:MonitorVisibility 三旗标与两道门(popover-leak/01)

> 2026-10-30 更新(popover-appkit):弹窗已改 AppKit 原生,`MenuBarPopoverGate` 删除——面板内容每次打开现建、收起即从窗口卸下,观察回路随离窗停止(同一门控语义的 AppKit 形态);会话状态(tab 记忆、DashboardModel)由 `MenuBarController` 持有。主窗口门控不变。

MenuBarExtra(`.window` 样式)的弹窗与 SwiftUI 的 Window 场景,**关闭后都不销毁内容视图树**——辅助功能已报 0 窗口,采样栈里排行 / 走势整页仍随采样轮逐轮重算(弹窗 77 点 / 15s、主窗口 25 点 / 15s,2026-10-21/22 实测)。用户点过一次窗口,之后的"稳态"就悄悄变观看态,常驻成本账全部失真。决定:两个场景的内容根各设一道**可见性门控**——不可见时只渲染一块与上次同尺寸的透明占位,**不读任何逐轮变化的 observable**,采样轮落地不再翻搅视图树;可见性信号收进 `MonitorVisibility`,单一事实源。

**状态语义(三旗标,别混)**:

- `popover` —— 弹窗在场。写路径 `setPopoverVisible`(弹窗门控根的 onAppear/onDisappear);**额外驱动采样节奏 1s/5s** 与传感闸门。
- `moduleRankings` —— 主窗口停在电池/磁盘/网络模块页。写路径 `setModuleRankingsVisible`(MainWindowView 的 tab onChange / onAppear / onDisappear);只进传感闸门。
- `mainWindow` —— 主窗口整体在场。写路径 `setMainWindowVisible`(主窗口门控根);**只作视图门控,刻意不进 `anyWindow`**——主窗口停在历史页等非排行页时不该白跑 nettop。

`anyWindow = popover || moduleRankings`,是**传感闸门**(排行数据有没有人看),与"哪个窗口的视图树活着"是两回事。读数出口:`SystemMonitor.popoverVisible` / `mainWindowVisible`(计算属性,读即被 Observation 追踪)。

**门控规则(MenuBarPopoverGate / MainWindowGate 同款)**:① 条件渲染,隐藏分支零 observable 读;② 占位帧用上次实测尺寸撑(`onGeometryChange` 记忆;首开用默认值,打开动画内一帧不可感知);③ 会话状态按需提升——弹窗的 tab 与 DashboardModel 提到门控层持有(重开不回总览、不丢展开),主窗口的 @State **不提升**,随关窗丢弃(标准 macOS 行为;泄漏时代"跨开关记住页面"的副作用就此取消,已在票内记档);④ `.task { monitor.start() }` 挂在门控根。

**被否的替代**:① "查明并修好 SwiftUI 为何不销毁树"——框架行为不可控,门控是能在应用层钉死的那半;② 只在 onDisappear 里停数据不停视图——视图树活着就随任何 observable 读数重评估,数据停了视图照样翻(本次实测 nettop 已停而排行行照算,即此状);③ mainWindow 并进 anyWindow——语义省一个旗标,代价是主窗口开在历史页时白跑 nettop。

**验收口径**:干净拉起 → 15s `sample` 指纹(模式带 `.body` 后缀,防 `文件名.swift:行号` 注释假阳性)全 0 → 开关两窗各一次 → 指纹仍全 0;nettop 0(传感闸门行为不变)。修复前对照 77 点 / 15s。

---

## 修订(2026-10-25,p2-review/05):三旗标 + 各页旗 → 两 tab 槽

上述三旗标落地后,传感闸门随后续页(GPU/传感器/外设/容器)长成了"弹窗裸布尔 + 每页一旗"
共七个字段——**门控过粗**:弹窗停在 CPU tab 也全开 P2 采集(docker 每容器 stats、蓝牙扫描、
SMC 全键);**加一页要改多处**(旗标 + 构造参数 + N 个 set*PageVisible + 三处 UI 接线)。
收编为两槽:

- `popoverTab: MetricTab?` —— 弹窗所在 tab,nil = 关。写路径 `setPopoverTab`
  (MenuBarPopoverGate:进场还原上次所在页、onTabChange 续报、关窗 = nil)。
- `mainWindowTab: MetricTab?` —— 主窗口所在 tab,nil = 关。写路径 `setMainWindowTab`
  (MainWindowGate.onAppear 写引导值——与 MainWindowView.init 初值**同式**
  `pendingTab ?? .overview`,深链开窗不闪错误闸;MainWindowView onChange/onAppear 续报;
  关窗由 gate 写 nil,一次写清在场与所在页)。

原三旗标全部降为**派生读数**,语义不变:`popover = popoverTab != nil`(仍驱动采样节奏
1s/5s)、`mainWindow = mainWindowTab != nil`(仍只作视图门控)、`moduleRankings =
mainWindowTab?.hostsModuleRanking ?? false`;`anyWindow` 照旧。**传感家族闸**升级为
按内容门控:`shows(_ family:)` = 任一在场窗口停在**展示该家族**的 tab
(`MetricTab.displayedFamilies`,与 MetricTabStack 卡片组成对齐)——总览的 GPU 卡吃
GPU 家族,功率只在 GPU 页,SMC/蓝牙/容器各只在本页。切 tab 首读口径:卡片立即显示
lastGood(历史 30s 档不看闸,数据至多 30s 旧),5s UI 档开闸后 ≤5s 内新鲜——与主窗口
页切换既有行为同款。排行闸(`anyWindow`)刻意不细化到 tab:弹窗任何 tab 都承载组排行卡。

**行为变化记档**:主窗口总览页的 GPU 卡从"仅 30s 历史档"升为"总览在场即 5s"——
按内容门控的对称推论,观看态成本,稳态(两窗全关)不变;弹窗停在无传感器内容的
tab(CPU/内存/磁盘/网络/电池/历史)不再白开五族采集,即本修订的目的。
