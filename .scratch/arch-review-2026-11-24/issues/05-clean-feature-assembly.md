# 05: 清理/卸载装配收口——View 不再 new Live

**What to build:** 修复 REPORT 高2:`MainWindowView.init` 与 `PulseApp.init` 是清理/卸载的真实生产工厂,直接实例化 Live 删除/扫描/落盘适配器;两份装配已造成 `scanCache` 漏传的线上静默失效。

**Status:** wontfix

证据见 `../REPORT.md` §高2。关键锚点:`MainWindowView.swift:59-95`(含 `:66-68` 漏传自述)、`PulseApp.swift:97-108`(影子模型同款装配),全仓 `CleanerModel(` 仅此两处。

**Agent Brief:**
1. 新建 `Pulse/App/CleanFeatureAssembly.swift`(或并入 `MonitorAssembly`),提供 `.live(...)` / `.preview` / `.inert`,统一产出 `CleanerModel`、`UninstallModel`、`McpCleanBridge`,注入 `LiveCleanTrashExecutor`、`LiveCleanActivitySource`、`LiveCleanVolumeSummaries`、`LiveCleanPermanentDeleter`、各种 Store 与 history;两个调用点只收成品。
2. `Pulse/Views/MainWindowView.swift` 的 `init` 只剩纯赋值:新增 `cleanerModel`/`uninstallModel` 参数,删除所有 `Live*` 构造式与真删除/真落盘闭包;预览使用工厂的 `.preview`。
3. `CleanerModel.swift:405-411,453-458` 直调 `LiveCleanDirectoryEnumerator.isUserDomain`/无条件 new Live 的分支,改为注入/合成(若涉及领域规则下沉,与 `issues/10` 协同,不要在本票重复改 `UninstallModel`)。
4. 加结构性测试:窗口模型与 MCP 影子模型的关键依赖(至少 `history`/`activity`/`scanCache`/`trash`)同源,防 registry-漏登病再犯。

**验收:** `Views/` 与 `Features/` 中不再出现 `Live*` 具体类型构造式(允许 `Pulse/Live/` 与工厂);一份装配变更同时作用于两处产物;check.sh 全绿。

## 核实(2026-11-24)

真但被夸大(维护风险,非现存 bug):两份装配参数逐个同源;「scanCache 事故由两份装配造成」与 git 历史不符(8ceff7c 修于影子模型 6d3b4ae 之前)。**由 arch-clean/01 取代**(加 ast-grep 规则把约定变机制)。
