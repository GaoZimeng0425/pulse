# 02: 弹窗可见性单写者,主窗口关窗加系统层信号

**What to build:** 弹窗的「开、关、当前页」只由菜单栏控制器上报,弹窗内容只负责
显示;主窗口的关闭多一条系统层信号作为主信号,原来的界面回调留作备份;加一条
结构检查规则,防止有人在别处再直接写弹窗可见性。用户看到的是:快速关掉再打开
弹窗时照常显示并停在上次的页;其余不变。

**Blocked by:** None (02 的代码不依赖 01,可独立合并)。

**Status:** ready-for-agent

## Agent Brief

**Category:** refactor

**Summary:** 删除弹窗内容的第二处可见性上报;控制器成为唯一写者并独占「上次所在
页」;主窗口关窗接入「窗口即将关闭」通知;ast-grep 规则守住单写者。

**Current behavior:**

弹窗可见性(`MonitorVisibility.popoverTab`,写入口 `SystemMonitor.setPopoverTab`)
有两处写者:

- `MenuBarController`(AppKit 层):`openPanel()` 上报 `lastTab`;`closePanel()`
  回读当前页补记 `lastTab` 后上报 nil。面板的显示与隐藏只经由这两个方法(状态
  按钮切换、失焦收起、自动化探针都走它们)。
- `MenuBarPopoverGate`(SwiftUI):自己持有一份 `@State lastTab`,`onAppear` /
  `onDisappear` 各写一次,`onTabChange` 里再写一次。`openPanel()` 的注释记着
  SwiftUI 的 onAppear 在 AppKit 宿主里触发时机不可依赖(首轮实测首开不触发),
  所以控制器那一处才是实际生效的信号,视图这一处是可能迟到的第二写者。

主窗口:`setMainWindowTab(nil)` 全仓只有 `MainWindowGate.onDisappear` 一处。
`DockPresence` 已经在监听系统层的 `NSWindow.willCloseNotification` 来切换 Dock
图标策略。

**Desired behavior:**

- 弹窗:
  - `MenuBarController` 是 `setPopoverTab` 的唯一调用者,`lastTab` 只在控制器里有
    一份。`openPanel()` 上报 `lastTab`;`closePanel()` 上报 nil,不再回读补记;
    新增一个私有方法处理「用户切页」:记住该页并上报。
  - `MenuBarPopoverGate.init` 增加必填参数 `onTabChange: @MainActor (MetricTab)
    -> Void`,由控制器构造时注入(面板是惰性属性,初始化时再捕获 self)。
  - `MenuBarPopoverGate` 删除 `@State lastTab` 与 `onAppear` / `onDisappear` 两处
    写入。渲染条件改为读 `monitor.currentPopoverTab`(可见性的单一事实源):非 nil
    时画 `DashboardView`,初始页取该值;nil 时画透明占位。保留
    `.task { monitor.start() }` 与常驻的 `DashboardModel`。
  - `DashboardView` 的 `initialTab` / `onTabChange` 接口不变。
- 主窗口:
  - 复用 `DockPresence` 已有的 `willClose` 监听与主窗口识别口径
    (`DockPresence.isMainWindow`):主窗口即将关闭时,经注入的回调通知
    `SystemMonitor.setMainWindowTab(nil)`。信号在关闭瞬间同步落地。
  - `MainWindowGate.onDisappear { setMainWindowTab(nil) }` 保留,作为重复无害的
    备份(`updateVisibility` 的等值守卫保证不产生派发)。
  - 主窗口的开启与切页上报(`MainWindowGate.onAppear`、`MainWindowView` 的
    onChange / onAppear)不动。
- 结构检查:在 `.ast-grep/` 加一条规则,error 级:对弹窗可见性的写调用
  (`$RECV.setPopoverTab($$$ARGS)` 一类的形状)不得出现在 `Pulse/App/` 之外;
  message 写明「弹窗可见性只由菜单栏控制器上报」。规则写法走 ast-grep 技能;
  注意 `ignores` 的 glob 相对 scanned 路径怎么解析,写完用故意越界验证。
- 排行采集开关(`MonitorHost.setRankingsActive` →
  `Sampler.setRankingsActive(_:generation:)`)及其测试不动。

**Key interfaces:**

- `MenuBarPopoverGate.init(monitor:onTabChange:)`:`onTabChange` 必填。
- `DockPresence.install(...)`:增加一个主窗口即将关闭的回调参数(或等价的注入
  方式);`PulseApp` 安装时传入关窗时上报 nil 的闭包。
- `SystemMonitor`:无接口变化。票 01 只删 `setPopoverTab` 内部发给采样循环的一步;
  两票先后合并时核对这里没有互相覆盖。
- 新增结构规则一条。

**Concurrency notes:**

- 通知回调是非隔离上下文,`NSWindow` / `Notification` 不可发送。按 `DockPresence`
  现有写法在主 actor 侧落地(`MainActor.assumeIsolated`),不要引入新的 Task 跳转。
- 面板是惰性属性:注入闭包里捕获 `self` 用 weak。

**Acceptance criteria:**

- [ ] 全仓 `setPopoverTab(` 的调用只出现在 `MenuBarController`;视图层与功能
      模块层零调用
- [ ] `MenuBarPopoverGate` 不持有页记忆、没有 onAppear / onDisappear 上报;初始页
      读自 `monitor.currentPopoverTab`;`.task { monitor.start() }` 保留
- [ ] 「上次所在页」只由控制器持有
- [ ] 主窗口关闭:系统层「窗口即将关闭」为主信号,`MainWindowGate.onDisappear`
      保留为幂等备份;`DockPresenceTests` 现有用例照常通过
- [ ] 结构规则已加:故意在视图里写一处越界调用时 lint 失败并给出指向控制器的
      提示,移除后通过;对控制器内的调用与 `SystemMonitor` 里的定义不误报
- [ ] 排行采集开关相关测试(`SamplerRankingTests`)原样通过
- [ ] 全量检查通过
- [ ] 人工验收:
  - 快速连点菜单栏图标,关掉再打开,弹窗正常显示并停在上次的页
  - 弹窗切到 GPU 页再切走,GPU 卡读数照常刷新
  - 关闭主窗口再打开,重复几次,内容正常显示、不出透明空窗;Dock 图标随主窗口
    出没照旧
- [ ] 探针(不动鼠标):启动后不开任何窗口,量一次改动前后的稳态成本,确认启动
      时的隐藏窗口没有让主窗口被当成在场;改动前就没有差额则记录数字

**Out of scope:** 主窗口可见性写入点的结构规则;用读最新状态替换排行采集开关的
消息;弹窗打开时立即补采;`DashboardView` 内部;系统层面的收起(例如隐藏 app)
——控制器的关闭动作没有发生,本票不改这条路径。

## Comments

- 2026-11-25 立票(unified-cadence/spec.md),承接 arch-review-2026-11-24/02 的
  第 2、3 项。原票的「先实测门控 onAppear」没有做(需要在用户屏幕上开弹窗),
  改为读代码确认:面板的显示与隐藏只经由控制器的 `openPanel` / `closePanel`。
- 与 popover-header/01 记录的「`openPanel()` 先 `setPopoverTab` 再读面板尺寸」
  顺序不冲突:`openPanel()` 仍先上报 `lastTab`。
- 机器高负载时两条磁盘扫描用例会偶发失败(见票 01 的备注),与本票无关。
