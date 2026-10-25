# 02 — 项目根归因优先于 App 归属:layerSelf 判定顺序对调(自 01 勘误拆出)

**What to build:** 归组引擎自身归属的判定顺序对调:`GroupingEngine.layerSelf`
(Packages/PulseCore/Sources/PulseCore/GroupingEngine.swift:477)现在先判 App 归属
(`.app` 容器谓词)后判项目归因(cwd/argv 命中项目根),bundle 命中即返回、项目根
没机会发言。改为**项目归因整层先于 App 归属**(层内顺序不变:cwd 优先、argv 次之),
bundle 退为项目未命中时的兜底。

**用户痛点(2026-10-25 用户再次立题,原话"App 的优先级优于项目根……我希望项目根
的优先级更高,把那些进程应该合并到项目根里面"):** 01 号票 2026-10-23 诊断有误——
"引擎已经是项目优先"不成立(详见 01 的勘误评论):项目层只先于**父链继承**,
不先于**自身 App 归属**。可执行在 `.app` 容器内、cwd 命中项目根的进程
(01 样本没覆盖这一类)现行全归 App。两个放大器:

1. `appContainerPrefix` 放宽口径(2026-10-16)把 `/Applications/Xcode.app/Contents/
   Developer/Toolchains/...` 下的 swift-frontend / clang 等编译器全归 Xcode.app——
   构建项目时编译大头记在 Xcode 头上,项目组近乎为空;
2. ZCode agent 会话的 Helper / node(可执行在 ZCode.app 内)cwd 在项目根里,
   现行规则下归 ZCode.app。

改后这些进程归项目组(命中 `.worktrees/<名>` 仍显示"项目名 @ 名"),用户能直接
回答"哪个项目在消耗资源"。主榜单与三个模块排行卡(能耗影响/读写最多/每进程流量)
吃同一份 RoundContext.groups,翻转全局一致生效。

**与 01 的分工:** 本票只修"cwd/argv 命中根却被 bundle 抢走"的半边;01 保留
"cwd 根本没命中根"(draft 目录 / 项目父目录 / `/` 与 home / /tmp worktree)的
半边及其 A–E 候选。01 的候选 B(宿主下钻标注)与本票互斥视角,triage 应两票同看。

**Blocked by:** None

**Status:** needs-triage

## Comments

### 调查记录(2026-10-25,主会话)

**规则复刻探针**(全机 765 进程空闲快照,复刻 layerSelf / appContainerPrefix /
projectMatch 三份判定;probe 脚本 /tmp/project_priority_probe.swift 一次性未入库):
翻转 4 个进程,全部是 ZCode Helper(本会话类 agent 进程)→ pulse ×2、NemoNotch ×2,
合计 0.1% CPU。空闲时刻量小符合预期;**机制层已从代码验证**:Xcode 工具链编译器
cwd 在项目里时,现行放宽口径归 Xcode.app、新规则归项目——构建 / agent 运行时才是
翻转量大头。这也补了 01 样本的盲区:01 只采了 cwd 命中根的非 bundle 进程
(repl-mcp)与 cwd miss 的进程,没采 bundled ∧ 命中根。

**测试面盘点**(现有用例无一锁死"App 压项目"):

- 门禁树锚点(GroupingEngineTests `testOctokGateTree…` / GroupingPipelineTests
  `testGateTreeFlows…`):Zcode 宿主夹具**没设 cwd**,新规则下仍归 App;node/cargo/
  rustc 非 bundle 仍归项目——两锚点不翻,预期保持绿。
- `testEmptyProjectRootsDegradeDevChainToHostAppBundle`:根为空 → 项目层必不命中 →
  退化路径不变。
- GroupingLaunchdManifestTests(BDLDaemon 类 bundle 守护):cwd 不在项目根,不受影响。

**与 ADR-0005 ④ 的关系(票面必须记档的对齐):** ADR-0005 记有 2026-10-20 triage
拍板"程序在 .app 容器内的守护(BDLDaemon 类)仍被 App 归属先收走,判定顺序不动"。
该拍板针对 **App vs 后台服务** 轴(守护不该因 launchd 域被读成后台服务),本票翻的是
**项目 vs App** 轴;BDLDaemon cwd 在 `/`,项目层不会命中,行为不变——不冲突,
但两条判定顺序记录需互指,避免后人读出矛盾。

**待 triage / grill 的点(带倾向):**

1. **无条件翻,还是只翻"工具类"进程?** 倾向:无条件。评审 S4 已废除 dev 可执行
   名单闸("zig 与 rustc 同权"),给项目层再加"哪些 bundle 进程可翻"的名单等于把
   名单闸请回来。后果:从项目目录里启动的 GUI(cwd 在项目)也归项目——量小,
   且符合"这个项目会话拉起来的都算项目"的直觉。
2. **argv 命中也压过 bundle?** 倾向:是。项目层内部顺序(cwd→argv)不变,整层
   上移;argv 含项目路径的 bundle 进程(如带项目参数拉起的 Helper)归项目。
   注意 01 实测 zap/zcode CLI 的 argv 只含 argv[0]——argv 通道对本痛点贡献有限,
   但翻过去无害。
3. **历史分钟/小时表口径:** 新样本按新口径,存量行保留旧口径不迁移——与既往
   谓词修正(c21d2be)一致。组身份键(`.project`/`.app`)零改动,无 schema 影响。
4. **要不要 ADR:** 非单向门(无 schema/数据迁移),倾向 GLOSSARY 措辞修正 + 票面
   记档即可;若 triage 觉得判定顺序是架构承诺,再补短 ADR。

### Agent Brief(实施提示)

- **改动面**(预计 3 文件 + 测试):
  - `GroupingEngine.swift`:`layerSelf(_ identity:)` 两段对调;文件头"判定顺序"
    注释列表 1↔2 对调;`GroupingConfiguration` 注释里"到达项目归因层(未先被 App
    归属)"措辞同步。
  - `GLOSSARY.md`:"App 归属"/"项目归因"两条措辞对调优先级描述;"孤儿进程"条里
    "无 App 归属、无项目归因"顺序无行为含义,顺笔即可。
  - `PulseTests/GroupingEngineTests.swift` 新增用例锁新序:① bundle 进程 cwd 命中
    根 → 项目组;② bundle 进程无项目命中 → App 组(防翻过头);③ argv 命中的
    bundle 进程 → 项目组;④ 门禁树锚点保持绿。
- **不要动**:系统判定优先级(仍在最前,WindowServer);`appContainerPrefix`
  谓词本身;继承机制(活链/登记链走同一 layerSelf,自动跟随);
  `SelfAttributionCache`(按 pid+身份三元组键,项目根变化已自会作废)。
- 注释引用工单写全名 `project-visibility/02`。
- 验收:引擎新用例 + 全量 `sh scripts/check.sh` 绿;真机口径由用户目验——
  "起 Pulse 开主窗口,在任一项目里跑构建/agent,榜单项目组应包含编译器与 Helper
  进程,Xcode/ZCode 组只剩 GUI 自身"。
