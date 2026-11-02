# 01: 弹窗面板定高 + 每个 tab 一个页头(统一组件,本机一行只在总览)

**What to build:** 两处用户实见的弹窗 / 页头问题(2026-11-02 用户报):

1. **弹窗上下错位**:面板高度在 `openPanel()` 时读一次 `hosting.fittingSize`(此刻 SwiftUI 还没把透明占位换成真内容,量到的是上次关闭时记的占位尺寸),之后再不调;内容侧是一摞刚性元素(tab 栏 / 页头 / **定值 520 滚动区** / 可选告警横幅 / 底排),根视图也没有 `maxHeight: .infinity`。两边一旦不等——面板比内容高 → 内容被宿主居中、上下留白、底色铺不到边(「没撑满」);面板比内容矮 → 刚性内容居中溢出、上下对称被裁(「top/bottom 显示不全」)。告警横幅在开着时出现 / 消失就是最常见触发。
2. **标题重复 + 本机一行到处有**:弹窗与主窗口页头各自手写(两份副本),每个 tab 都画「页名 + 芯片·核数·内存」;清理页主窗口页头画一次「清理」26pt,`CleanerTabView` 自己又画一次「清理」26pt + 扫描状态 + 按钮——同页两个大标题。

**Status:** ready-for-agent(立票即分诊:用户直报 + 两拍板已定,无冗余票;`.out-of-scope/` 无冲突)

**拍板(2026-11-02)**:
- **A 面板定高**(用户选 A,弃 B「随内容伸缩」):面板尺寸是设计令牌 `{layout.popover-size}` 360×648,AppKit 侧直接给,不再读 `hosting.fittingSize`;中间滚动区 `maxHeight: .infinity` 吃掉剩余高度,根视图撑满宿主——tab 栏 / 页头钉顶、底排钉底,横幅出没只挤中间,切 tab 面板不动。
- **页头统一组件 `PageHeader`**:主窗口 / 弹窗 / 清理页三处同一出处;标题一行 + 可选副标题(**只有总览带本机一行**;清理页 = 扫描状态)+ 右侧配件槽(弹窗运行时长 / 清理页扫描按钮);两档 `.full`(26 bold / 12 secondary)与 `.compact`(11 / 11 secondary,弹窗既有观感不变)。清理页标题由 `CleanerPageHeader` 经主窗口页头槽画,`CleanerTabView` 不再自画 → 每个 tab 恰一个标题。

- [x] `DashboardView`:滚动区 520 定值 → `maxHeight: .infinity`;根 `.frame(maxHeight: .infinity, alignment: .top)`;`panelSize` 令牌常量;页头换 `PageHeader(.compact)`
- [x] `PopupPanel`:删 `fittingSize`(读 hosting 的那段逻辑整段删),初始 / 开面板尺寸取 `DashboardView.panelSize`;`hosting.sizingOptions = []`(与 `NativeListCell` 同纪律,固定帧宿主不报固有尺寸)
- [x] `MenuBarPopoverGate`:删 `contentSize` 实测与 `onGeometryChange`,占位帧 = 令牌尺寸
- [x] 新 `Pulse/Views/PageHeader.swift`;`MainWindowView` / `CleanerViews` 接入;本机一行判据 `PageHeader.init(tab:)` 单点;`scanDurationText` 上提为 `CleanerModel` 扩展(页头与「扫描完成」卡共用)
- [x] DESIGN.md:`{layout.popover-size}` 令牌、`page-header` 组件条目、弹窗 DashboardView 条目「全 tab 一致」改「本机一行只在总览」
- [x] `xcodegen generate` → `sh scripts/check.sh`:lint 过、构建过、402 宿主例 + 核心包全绿(唯一一挂 `AcceptanceAnchorEndToEndTests` 为忙循环组 CPU% 98.7 未过 100 的调度毛刺,单跑即绿,与本票无关)→ 合 develop(hook 装机)
- [ ] 用户目验:弹窗切到声音 / 容器 tab 底排钉底不悬空;触发一条告警横幅挤出来、底排仍完整;弹窗 CPU tab 页头只剩「CPU」+ 运行时长、总览才有本机一行;主窗口清理页只一个「清理」(副标题 11 → 12pt 随统一组件收编)

## Comments

- **诊断依据**:`MenuBarController.swift` `PopupPanel.fittingSize`(hosting.fittingSize 夹 [480, 720])/ `openPanel()` 先 `setPopoverTab` 再同步读尺寸;`DashboardView.swift` `contentHeight = 520`(注释自认是 MenuBarExtra 时代「ScrollView 理想高恒 0 会压扁」的权宜,换 NSPanel 后前提已不在)。
