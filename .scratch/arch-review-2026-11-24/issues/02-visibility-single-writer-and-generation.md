# 02: 可见性闸收口——节奏消息加代号 + tab 写路径单一所有权

**What to build:** 修复 REPORT 高4:排行闸已有 generation 防乱序(`Sampler.swift:262-274`),同一次可见性变化触发的节奏闸(`setPopoverVisible`)却无代号;弹窗 tab 双主(AppKit 控制器 + SwiftUI 门控),主窗口关窗无 AppKit 兜底。

**Status:** wontfix

证据见 `../REPORT.md` §高4。关键锚点:`SystemMonitor.swift:275-281`(有代号)/`:329-336`(无代号);`MenuBarController.swift:44,124-126,156-159` vs `MenuBarPopoverGate.swift:21-23,36-53`;`MainWindowGate.swift:53-54` 是 `setMainWindowTab(nil)` 全仓唯一写者。

**Agent Brief:**
1. `Sampler` 增 `applyVisibility(_ visibility: ..., generation:)`(或给 `setPopoverVisible` 加 generation 参数),按 `generation > stored` 丢弃旧消息;`SystemMonitor.updateVisibility` 作唯一提交点,递增代号并把 `popover`/`anyWindow` 合并下发;`stop()` 递增代号作废在途消息。沿用排行闸的现成写法与测试。
2. 弹窗:`MenuBarController` 作为 `setPopoverTab` 唯一所有者(含 `lastTab` 记忆);`MenuBarPopoverGate` 退为纯渲染,删掉门控里的 `lastTab` 与 `onAppear/onDisappear` 写路径,用户切 tab 事件上抛(注入闭包),`initialTab` 由控制器传入。保留 `.task { monitor.start() }`。
3. 主窗口:在 AppKit 侧加 `windowWillClose` 回调写 `setMainWindowTab(nil)` 作权威信号,SwiftUI `onDisappear` 保留为幂等补写(等值 no-op 已由 `updateVisibility` 的 guard 保证)。
4. 测试:可见性快速开→关乱序注入(假 Sampler 乱序交付)断言最终节奏与 visibility 一致;两个写路径不再互相覆盖。

**验收:** 关窗后不会残留 1s 热采样;重开弹窗 tab 不被迟到钩子清空;ADR-0006 的稳态零成本口径不被破坏。

## 核实(2026-11-24)

真但被夸大,降为中。节奏消息确无代号、弹窗 tab 两处写,但:MainActor 同优先级 Task 实际按序、0.3s 防抖,乱序后下次开关即自纠(非「不会自纠」);「弹窗空白」无证据;主窗口 onDisappear 实测会触发。**Brief 收窄**:只给 setPopoverVisible 加代号;弹窗 tab 收为控制器单写者(先实测门控 onAppear);主窗口复用 DockPresence.swift:41 已有的 willClose 监听加一行兜底。

2026-11-25 **由 unified-cadence 取代**(用户拍板采样统一 5 秒):第 1 项不需要——节奏固定后这条消息整个删除,无代号可言;第 2、3 项保留,归 unified-cadence/02。
