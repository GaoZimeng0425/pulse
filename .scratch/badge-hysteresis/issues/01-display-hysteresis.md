# 01: 菜单栏徽标显示量化/迟滞——压掉 runloop 提交期的属性图/CA 逐轮翻搅

**What to build:** 给菜单栏徽标的**显示值**加死区迟滞(deadband):读数在阈值内抖动时显示数字不换,并且**迟滞后的显示值成为唯一发布给标签的数据源**——每轮读数落在死区内就不触发任何 SwiftUI 状态赋值,属性图重评估 + CoreAnimation 提交 + 位图 LRU miss 三项一并归零。目标:压掉 resident-cost/01 具名的稳态残差 0.4–0.6 个百分点(负载相依,忙时 ~1pp);北极星 0.1% 不设硬指标,沿锚点④诚实口径,达到多少写多少。**观感变化(数字刷新最多滞后一个阈值)是本票成立的前提**——维护者已拍板做 A(2026-10-21),迟滞参数须 grill 后定,不得静默上线。

**Status:** needs-triage
**Category:** enhancement(性能)

## 为什么现在开(2026-10-21)

- resident-cost/01 已结项(develop @8a2b313):稳态 1.09%(安静对安静),仪表具名 0.77pp,残差 0.4–0.6pp 已具名 = **runloop 提交期的属性图/CA 翻搅**(徽标族,负载相依,抓栈双向印证),治理杠杆就是本票——结项 comment 原文"留给维护者另立项拍板"。
- 拍板门 A 已过:维护者 2026-10-21 晚拍"继续做 A",交接(handoff)随会话落在 $TMPDIR,不进仓库。
- 3b 直绘已被拍板跳过(仪表证明位图重绘只占 0.03–0.1pp,残差大头在属性图);通往 0.1% 的最大已具名杠杆只剩本票。

## 方案要点与开放问题

1. **机制——迟滞必须挡在"发布"这一层,只改 composer 折算不够**(立票时现场确认,实施者勿走样):
   - 现状链路:`Pulse/App/PulseApp.swift` 的 `MenuBarLoadLabel.body` 直读 `monitor.systemCPULoad` / `memory` / `disk` / `network` 原始值;CPU% 经 `PulseFormat.cpuPercent` 四舍五入成整数,几乎每轮变 → ① body 逐轮失效,属性图 + CA 提交逐轮翻搅(残差大头);② `MenuBarBadgeRenderer` 的 LRU 键(全部徽标内容)逐轮 miss,位图逐轮重渲(小头)。
   - 若只在 `MenuBarBadgeComposer` 里折算、label 照旧读原始值,①省不掉——body 照样逐轮重算。正确形态:**label 不再读 monitor 原始读数**,改读一个 MainActor 显示快照(@Observable);每轮对快照应用迟滞状态机,**输出不变就不赋值**——不赋值就没有 SwiftUI 失效,属性图/CA 一次都不跑,LRU 键稳定连查询都省在原值上。
   - 迟滞器本体是纯值状态机((已显示值, 新读数, 强调级) → 输出),放 PulseCore,沿 `ProcessIdentityCache` / `NettopHealthLog` 的"纯值 + app 薄壳"先例,可单测;app 侧只留挂轮与赋值薄壳。
   - label 保留依赖的三样:`@AppStorage` 槽位配置、`colorScheme`、显示快照——前两者低频失效,无妨。
2. **适用范围(建议,grill 拍板)**:百分比槽位 CPU / RAM / 磁盘剩余用同一死区机制(RAM/磁盘本就慢,阈值与 CPU 一致即可);**网络速率槽刻意排除**——数字频繁刷新是功能(resident-cost/01 结项前已定的口径)。如实接受:开了网络槽的配置每轮照旧发布(显示值逐轮变),稳态翻搅对该配置不降——本票收益口径 = 不含网络槽的配置(默认 CPU+RAM)。
3. **迟滞参数(全部 grill 拍板,以下为推荐)**:
   - **死区阈值**:推荐 |round(新读数) − 已显示整数| ≥ **2 个百分点**才换数字,以"上次显示值"为锚(不是上次原始值)——锚在显示值上,显示误差上限即阈值,不会累积;备选 1pp(更跟手,收益打折)。
   - **强调级越权立即**:emphasis(CPU>70 红、RAM 压力橙/红)**跟随原始值**计算,变化立即发布,不受死区约束——迟滞不得盖住 critical;数字本身仍按死区走。占位切换(nil→读数、读数→nil)同样立即。
   - **回滞方向**:推荐对称死区(显示值锚定天然防边界抖动、误差 ≤ 阈值);备选"回落更快"(下行 1pp / 上行 2pp)防"钉高值",若 grill 认为对称已够就不加复杂度。
4. **验证口径(全按 resident-cost/01 结项口径,不另起炉灶)**:
   - 稳态 = 弹窗 + 主窗口全关、落地 ≥5min、150s cputime ÷ 墙钟;测前 `sample <pid> 5` 栈指纹确认无 `RankingCard` / `RankingListRow`(有人在看就别测)。
   - 基线对照 1.07–1.09%(安静对安静,采集成本随负载漂,窗口选相近负载状态)。诊断报告"阶段耗时"应基本不变——省的是阶段之外的提交期翻搅;主看 **150s 窗总量 + `sample` 里 AttributeGraph/CA 采样点数**(安静时段应趋近于零)。
   - **观感必须用户目验拍板**(设门的全部原因):数字刷新迟滞的观感、强调级即时变色、改槽位/切外观正常。实施前读 DESIGN.md——本票改显示行为不改样式,预计零令牌变化,若发现需要动令牌先补表。

## 验收

- [ ] 迟滞状态机进 PulseCore 纯值实现:死区阈值、强调级越权、占位切换、对称/非对称行为各有单测(含 CPU 70 红线立即生效、显示误差 ≤ 阈值不累积)
- [ ] `MenuBarLoadLabel` 不再直读 monitor 原始读数(显示快照为唯一数据源;`@AppStorage` / `colorScheme` 依赖保留)
- [ ] 网络槽行为零变化(逐轮刷新、两行叠排、占位规则)
- [ ] 稳态复测按上述口径记档:150s 窗数字 + `sample` AttributeGraph/CA 点数,与 1.07–1.09% 安静对安静对比,如实写
- [ ] 观感用户目验通过(数字迟滞、强调级即时、槽位/外观切换)
- [ ] 既有 641 例零回归 + 新增测试全绿;`sh scripts/check.sh` 全绿
- [ ] GLOSSARY 若 grill 落新词条(如"显示迟滞")则补

## Comments

> 2026-10-21 主会话手写立票(未走 /to-tickets),依据 = resident-cost/01 结项 comment 的拍板门 A + 晚间 handoff($TMPDIR,不进仓库)。请维护者跑 `/triage`;迟滞参数(阈值/适用范围/回滞方向)建议 `/grill-with-docs` 一轮收口。关联代码:`Pulse/App/PulseApp.swift`(MenuBarLoadLabel)、`Pulse/Views/MenuBarBadgeComposer.swift`、`Pulse/Views/MenuBarBadge.swift`(LRU)、`Packages/PulseCore/Sources/PulseCore/MenuBarBadgeConfiguration.swift`(槽位配置与数据快照)。
