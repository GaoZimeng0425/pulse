# 01: 会话卡 Git 状态——分支名 + 未提交标记

**Status:** ready-for-agent

**What to build:** 智能体页「会话」子页的每张会话卡(Claude 卡与 ZCode 卡同款)
显示该会话工作目录的 **git 分支名** chip + **「未提交」小标记**(工作区有
未落盘改动时,含未跟踪文件)。cwd 不在 git 仓库的卡不显示分支。两卡现有
worktree chip 旁落位;「未提交」用琥珀系警示色(DESIGN.md 令牌表为准)。

**背景:** 2026-11-22 用户四摊候选点单后的第二批:智能体页原本拟做
「Git 状态 + 杀会话」两件,grill-with-docs 一轮 + 事实探针后用户拍板
**杀会话撤下**(探针证实 ZCode 会话元数据无 pid,本来就无法可靠杀,
撤即省一半成品),Git 状态按推荐定稿。

**拍板(grilling 共识,2026-11-22):**

1. 显示细度 = 分支名 + 「有未提交改动」标记(不含领先/落后远端,噪音大)。
2. 分支跟着**会话卡**走(会话自己 cwd 的分支)——会话页没有「项目行」
   结构(探员核实,原「项目行显示主目录分支」无处落),主目录分支 v1
   不显示;以后想在消耗页项目卡上补再补。
3. Claude 卡与 ZCode 卡同款;未跟踪文件(`??`)也算未提交。
4. 杀会话整体不做(用户原话「不做杀死会话」);worktree/分支清理提示
   不做(清理域另有删前三重复核规矩,不混票)。
5. cwd 不在 git 仓库 → 不显示分支 chip(不是错误态,安静缺位)。

**成本探针实测(2026-11-22):**

- 分支名 = 纯文件读零开销:主 checkout 读 `<cwd>/.git/HEAD`;worktree
  的 `.git` 是文件(`gitdir: <path>` 重定向)→ 读 `<path>/HEAD`;HEAD
  内容 `ref: refs/heads/<branch>` 取分支名,非 ref 行 = detached 取
  前 7 位。
- 未提交判定 = `/usr/bin/git -C <cwd> status --porcelain` 输出非空:
  **30ms(主仓)/ 23ms(worktree)**,warm 实测;当前 8 项目根全跑
  ≈0.2s——5s 档无压力,且按会话 cwd 去重后实际更少。
- 全库现状:无任何 git 调用、无 libgit2/SwiftGit2 依赖(project.yml 仅
  CocoaLumberjack + PulseCore;PulseCore 仅 GRDB)——本票为首例 shell-out
  git,走 nettop/LiveBrewUninstaller 的子进程先例。

**分层与文件(PulseCore 纯逻辑 / Live / Feature / View 惯例):**

- PulseCore `SessionGitStatusModel.swift`:`SessionGitStatus`(branch:
  String? / dirty: Bool);`GitHeadParser`(纯函数:HEAD 内容 → 分支名,
  ref 行与 detached 两形态)+ `GitDirRedirectParser`(`.git` 文件内容 →
  gitdir 路径)+ porcelain 判定(trimmed 非空 = dirty);cwd 去重 + 上限
  护栏(如最多 16 个不同 cwd,防会话风暴)。缝协议
  `SessionGitStatusReading: Sendable`(批量方向 `status(cwds:) ->
  [String: SessionGitStatus]`,ADR-0004 薄缝惯例)。
- Live `SessionGitStatusReader.swift`:分支走文件读(零子进程);脏标记
  逐 cwd 跑 `/usr/bin/git status --porcelain`(进程退出/非 git 仓库/
  超时 → 静默空结果,不噪);只对去重后 cwd 批量。
- Feature 挂接 `AgentSessionFeature`:5s 档与现有会话文件读同节奏;
  可见性闸照 ports 卡模式(智能体页会话子页可见才采,实施时核对
  visibility API 既有 case);产出 `[cwd: SessionGitStatus]` 查表,
  不改会话识别链。
- View `AgentSessionViews.swift` 两张 tile:worktree chip 旁加分支 chip
  (detached 显示短 SHA);「未提交」小标记。**先读 DESIGN.md,缺令牌
  先补表再写码**(标准件优先)。
- 代码注释引用本票写全名 `agent-git-status/01`。

**测试:** PulseCore 单测(合成字符串,零真 git):HEAD ref/detached、
gitdir 重定向、porcelain 各形态(` M`/`??`/空)判定、cwd 去重与上限;
feature 合并逻辑用假 reader;View 不新开快照测试。真实 git 调用不进
自动化(测试负载最小化规矩);Live reader 冒烟可参照进程内自建仓的
最小形态,若引负载则砍。

**冗余搜查(立票即分诊):** 全库无 git 状态既有实现(探员全库核过
`git` 字样仅三处:CleanActivity 在用保护名单、worktree 路径段解析,
无功能重叠);`.out-of-scope/` 无同域条目;分类=功能增强,非缺陷非债,
无产品拍板残留(杀会话撤下已定),直接 ready-for-agent。

**验收:** 起 app → 智能体页 → 「会话」子页,每张活跃会话卡带分支名
(主 checkout 会话显 develop、worktree 会话显 feat/*),改一行不提交
→ 下一刷新档出现「未提交」标记,提交后消失。

## Comments

- **实施备注(2026-11-22 落地)**:三处与票面预案的偏差,均为实施时核实现源码后收窄——
  ①节流 5s → **双档:cwd 集变化 5s / 稳态 15s**。原案 5s 档按 8 根 ≈0.2s 估,但
  护栏上限 16 仓 × 30ms = 0.48s,5s 档折算单核 ~10% 太重(Pulse 低足迹纪律);
  分支/脏是慢变读数,15s 稳态 + 新会话上榜提前 5s,既答「这个 agent 在哪个分支」
  又不背常态成本。②git 不进 `AgentSessionCatalog`(快照结构不动):旁挂
  `AgentSessionFeature.gitStatuses` 查表——git 子进程批跑在 detached utility
  任务(单飞标志互斥),不上主线程;catalog 的纯值节流/单测结构零翻搅。
  ③可见性闸走 `MonitorVisibility.popoverTab/mainWindowTab == .agents`(ports
  传感器家族闸的同义收窄,不为旁挂读数新立家族)。装配:MonitorAssembly 传
  `LiveSessionGitStatusReader`;InertSources 不传(默认 nil,preview 无 chip)。
  Live 子进程带两级看门狗(TERM 2s → KILL 宽限 0.5s,NettopWatchdog 单进程版),
  半截输出整体作废不判脏(宁缺毋假)。PulseCore 新增 20 例单测(SessionGitStatusTests:
  HEAD ref/detached/畸形、gitdir 重定向、porcelain 各形态、去重上限、非仓库 nil、
  porcelain 失败不误报);Live 真实 git 调用不进自动化(测试负载最小化)。
- **工具链小坑记档**:①测试 fake 缝实现须 struct(Swift 6 下 class + var 存储
  属性不 Sendable);②DispatchSourceTimer 局部变量命名避开 Darwin `kill`(遮蔽
  函数名,编译器可抓)。
- **评审收尾(2026-11-22,独立评审员 approve-with-comments,无 P0/P1)**:P2
  壳层三道闸零测试 → 已补 `PulseTests/AgentSessionFeatureGitTests.swift` 四路径
  钉子(不可见不采 / 稳态 15s 节流 / cwd 集变化 5s 档 / 在飞不双发),4 例绿。
  P3 两条**记档不修**(改到对应文件时顺带收编,AGENTS.md 惯例):
  ①`SessionGitStatusReader.gitHeadFile` 对 submodule 形态的相对 gitdir
  (`gitdir: ../.git/modules/x`)按进程 cwd 解析 → 读不到 → 该会话无 chip——
  符合拍板⑤「安静缺位」,真出现子模块会话再修(相对 cwd 解析再拼 HEAD);
  ②一轮瞬时失败 `gitStatuses` 整表替换会短暂闪空 chip(≤15s 恢复)——
  lastGood 保底与「宁缺毋假」两难,维持现状,后人取舍。
