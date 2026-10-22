# 窗口内容按可见性门控:MonitorVisibility 三旗标与两道门(popover-leak/01)

MenuBarExtra(`.window` 样式)的弹窗与 SwiftUI 的 Window 场景,**关闭后都不销毁内容视图树**——辅助功能已报 0 窗口,采样栈里排行 / 走势整页仍随采样轮逐轮重算(弹窗 77 点 / 15s、主窗口 25 点 / 15s,2026-10-21/22 实测)。用户点过一次窗口,之后的"稳态"就悄悄变观看态,常驻成本账全部失真。决定:两个场景的内容根各设一道**可见性门控**——不可见时只渲染一块与上次同尺寸的透明占位,**不读任何逐轮变化的 observable**,采样轮落地不再翻搅视图树;可见性信号收进 `MonitorVisibility`,单一事实源。

**状态语义(三旗标,别混)**:

- `popover` —— 弹窗在场。写路径 `setPopoverVisible`(弹窗门控根的 onAppear/onDisappear);**额外驱动采样节奏 1s/5s** 与传感闸门。
- `moduleRankings` —— 主窗口停在电池/磁盘/网络模块页。写路径 `setModuleRankingsVisible`(MainWindowView 的 tab onChange / onAppear / onDisappear);只进传感闸门。
- `mainWindow` —— 主窗口整体在场。写路径 `setMainWindowVisible`(主窗口门控根);**只作视图门控,刻意不进 `anyWindow`**——主窗口停在历史页等非排行页时不该白跑 nettop。

`anyWindow = popover || moduleRankings`,是**传感闸门**(排行数据有没有人看),与"哪个窗口的视图树活着"是两回事。读数出口:`SystemMonitor.popoverVisible` / `mainWindowVisible`(计算属性,读即被 Observation 追踪)。

**门控规则(MenuBarPopoverGate / MainWindowGate 同款)**:① 条件渲染,隐藏分支零 observable 读;② 占位帧用上次实测尺寸撑(`onGeometryChange` 记忆;首开用默认值,打开动画内一帧不可感知);③ 会话状态按需提升——弹窗的 tab 与 DashboardModel 提到门控层持有(重开不回总览、不丢展开),主窗口的 @State **不提升**,随关窗丢弃(标准 macOS 行为;泄漏时代"跨开关记住页面"的副作用就此取消,已在票内记档);④ `.task { monitor.start() }` 挂在门控根。

**被否的替代**:① "查明并修好 SwiftUI 为何不销毁树"——框架行为不可控,门控是能在应用层钉死的那半;② 只在 onDisappear 里停数据不停视图——视图树活着就随任何 observable 读数重评估,数据停了视图照样翻(本次实测 nettop 已停而排行行照算,即此状);③ mainWindow 并进 anyWindow——语义省一个旗标,代价是主窗口开在历史页时白跑 nettop。

**验收口径**:干净拉起 → 15s `sample` 指纹(模式带 `.body` 后缀,防 `文件名.swift:行号` 注释假阳性)全 0 → 开关两窗各一次 → 指纹仍全 0;nettop 0(传感闸门行为不变)。修复前对照 77 点 / 15s。
