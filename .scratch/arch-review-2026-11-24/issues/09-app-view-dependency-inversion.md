# 09: App ↔ Views 依赖倒置与全局服务定位器

**What to build:** 修复 REPORT 中9:窗口管理逻辑住在 SwiftUI View 的静态方法中被 App 层反向调用;开窗能力靠全局可变静态量传递;`PulseApp.init` 构造即启动、没有对称关停;设置页在 View 里直接调 SMAppService。

**Status:** wontfix

证据见 `../REPORT.md` §中9。关键锚点:`MainWindowView.swift:224-255`、`PulseApp.swift:6-10,69,88-93,110-145`、`DockPresence.swift:30`、`MenuBarController.swift:321,447-460,489-499`、`GeneralSettingsView.swift:154-173`、`EnergyImpactFeature.swift:166-226`。

**Agent Brief:**
1. `repositionIfOffscreen` 抽到 `Pulse/App/`(判据纯函数可进 PulseCore,AppKit 副作用留 App);panel 尺寸改从共享 metrics 常量取(文档真源 DESIGN.md);视图只保留触发调用。
2. `MainWindowBridge.openWindow` 改为依赖注入:定义 `@MainActor protocol WindowOpening`,具体 router 由捕获视图注册到 `PulseApp` 持有的实例,显式注入 `MenuBarController` 与 `KeepAliveAppDelegate`,删除全局可变静态量。
3. `PulseApp.init` 拆出 `AppServices`/`AppComposition`(`init(env: live/inert)` + `start()/stop()`);构造不启动,`MenuBarController.init` 不再调 `monitor.start()`;TestHostApp 改用 inert 环境,消除"双 App"缺口。注意:本票不改产品运行期行为(monitor 与 app 同寿命),stop 仅用于测试/预览。
4. 设置页的登录项/助手注册动作收进 Feature/Live(`GeneralSettingsView` 只持有绑定与文案);与 `EnergyImpactFeature` 的助手状态桥统一到一个事实源,3s 轮询 Task 也归 Feature 持有并在关窗/停用时取消。

**验收:** App 层不再 import 具体 View 类型当工具命名空间;无全局可变开窗句柄;测试宿主走 inert 装配;SwiftUI 视图里没有 SMAppService/日志目录读取等系统副作用。

## 核实(2026-11-24)

多为分层风格,无现存缺陷;openWindow 全局静态有 LaunchHiddenWindow 缓解;3s 轮询仅「待批准」时运行且会自退。重构启动编排触碰多处实机回归过的时序,**暂缓**。核实时另发现坐标系疑似缺陷,单开 13。
