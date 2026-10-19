# 01: 票 A —— 传感层收敛(P2 前必做)

**What to build:** 架构审查(本目录 REPORT.md)三条「高」+ 两条「中」传感层债一次收口。
审查判定:P2(GPU/ANE/SMC)开工前必做,否则新传感器顺着最省力的路复制债。

**Status:** ready-for-agent

范围(细节与 file:line 证据见 REPORT.md §高1/§高2/§高3/§中5/§中6):

- [ ] **高1 SystemMonitor 收敛**(REPORT §1):拆出 SensorHub(可见性门控 + provider 调度登记)/ ModuleRankingModel(三张 pid 表 + 时间戳)/ 历史喂入编排(pendingDisk 记账账本)为独立可测类型;门控折算下沉纯函数进单测;init 参数减半;「UI 粘合层不写单测」豁免随之收回
- [x] **高2 rusage 双采集通道合一**(REPORT §2;2026-10-19 落地):能耗/磁盘两本账本改值类型 `ProcessRankingLedgers` 住 Sampler 心跳循环,共用一份「满窗推进」规则(`RusageWindow`:未满窗不推进基线,1s 心跳下仍是 5s/30s 窗);门控 = `Sampler.setRankingsActive`;`HeartbeatRusageRelay` 供求和回退源取心跳表;撤 `LiveProcessRusageTableSource` 与两个排行 provider。`proc_pid_rusage` 全仓库只剩 LiveProcessSource 一处。code-reviewer 三条 MEDIUM 同轮修掉:①心跳断档(睡眠后首轮先于唤醒清账)→ `RusageWindow` 间隔超 3 倍窗长重立基线;②中继记发布时刻(单调时钟),求和回退源计数时刻不再取读的时刻;③`RawProcess.countersAvailable`,计数读失败的 pid 不以 0 入表。遗留(LOW,未做):L1 能耗唤醒/秒按标称 5s 折算、实际窗 5–9s(需 Round 带实际窗长)→ 并入高1;L3 门控 Task 乱序理论风险(与 setPopoverVisible 同款,可加代号丢弃过期消息)→ 并入高1;L6 `energyImpactsUpdatedAt`/`diskProcessRatesUpdatedAt` 无读方 → 高1 拆 ModuleRankingModel 时定去留;L7 卡底「5 秒一档 / 30 秒一档」字面量未从 `ProcessRankingLedgers` 派生 → 票 B;另:`CPUDiffer` 同有「单 pid 计数瞬时读失败 → 恢复轮 CPU% 尖刺」的既有隐患,可直接用 `countersAvailable` 跳过 → 并入票 C 快修包。原文:心跳快照(LiveProcessSource.swift:179,每 pid 已读 V3 含磁盘字节)是唯一采集通道;RawProcess 增补 wakeups(V3 本就含);三个排行差分账本(能耗/磁盘/网络——能耗与磁盘吃 rusage 表)改吃心跳快照表,撤销 ProcessRusageSource 的第二条全进程扫描(proc_listallpids + RUSAGE_INFO_CURRENT,ProcessRusageSource.swift:40-53);可见性门控降级为「推进/暂停差分」;RusageSumDiskThroughputSource 同步改吃共享心跳表
- [x] **高3 组聚合内核统一**(2026-10-19 落地:`Leaderboard` 内核,四处站点改调,单测 `LeaderboardTests`)(REPORT §3):提 (identity, 值序列) → 排序 + tie-break + leader 归一 的纯函数内核;三处改调:MetricTabContent.build(MetricTabModel.swift:194/200/227,次键 lhs.id)、ModuleRankingAggregator(次键 lhs.key,且从视图 body 挪出、与 allGroups 两套时钟合一)、MainWindowView.swift:440 内联 cpuLeader;模块排行折叠挪进 SystemMonitor 同轮落地(错位超一轮不出榜)
- [x] ~~**中5 GatedDifferingSensor 泛型收口**~~(REPORT §5)——**撤销(用户拍板 2026-10-19)**,高2 落地后前提消失:能耗/磁盘两本已不是 SensorProvider,门控+差分+窗口规则收敛为一份 `RusageWindow`;仍挂「门控 + lastGood」的只剩 nettop 一个,泛型无第二个实例可抽。P2 的 GPU/ANE 若是心跳内读数则走 `ProcessRankingLedgers` 同款,真出现第二个外部门控源再抽。原文:门控 + 差分账本 + lastGood 五件套手抄三份 → 值组合泛型折叠(非继承,不违 ADR-0004),契约一次写一次测;P2 的 GPU/ANE 直接复用
- [x] **中6 nettop 子进程健壮性**(REPORT §6;2026-10-19 落地):`NettopWatchdog` 超时 SIGTERM → 宽限 1s 仍在跑 SIGKILL,并记下升级级别;`NettopHealthLog` 纯值状态沿(收尾方式变化才记,持续同态静默);命令/时限可注入,`/bin/sh` 扮 nettop 真实子进程验证升级链(吞 SIGTERM → SIGKILL 收尾)。code-reviewer 同轮修掉:M1 非零退出 / 被信号终止记 `.exitedAbnormally`(-k 列名被系统改掉时 nettop 以 64 退出、排行永久空白而无日志);M2 测试时限逐例放宽;M3 钉死「看门狗不可在 EOF 后取消」(waitUntilExit 无超时)并补测;L1 整个进程组 SIGKILL;L2 SIGKILL 后 2s 仍未收尾在全局队列另记一条;L6 dispatchPrecondition;L8 readToEnd 不再抛 ObjC 异常。遗留:L5 耗时贴 5s 边界时失败/恢复日志来回翻(状态沿不去抖,按需再加迟滞)。原文:看门狗超时升级 SIGKILL(现在只 SIGTERM,吞信号 = 串行队列永久冻结);失败沿记状态日志(沿 databaseHealthy 的 transition-not-tick 惯例)

约束与验收:
- 分两段子代理:数据层(高2 + 中5 + 中6)先行,SystemMonitor 拆分 + 组聚合统一(高1 + 高3)随后(依赖前者的快照表形状)
  - 2026-10-19 调整(架构讨论,用户拍板采纳):高2 先单独落地,中5 撤销(见上);同时去掉 SystemMonitor 的 Live 默认参数(`HistoryEngine.openDefault()` 默认值会让测试/预览误连生产库,见 0c892c1)。~~高1 做成顶层 reducer 形态~~——**已被下一条取代**
  - 2026-10-19 方向改定(用户拍板,取代上条 reducer 形态;「中心大 reducer」与「改进版 RoundReducer」两版均否决):stats 式纵向功能模块 + Pulse 自有的共享归组主干,兑现 ADR-0003。主干 `RoundSpine`(`Pulse/MonitorSpine.swift`)每轮「出生登记 → 归组 → 下钻」产出一份 `RoundContext`;每个功能 = `@Observable` 薄壳 + 纯值内核(`AlertCenter` + `AlertEngine` 为样板),经 `MonitorFeature` 扩展点收 `onRound` 与自己的传感器读数、自持状态、自执行副作用,视图直读模块;对主干/心跳的影响只经 start 时拿到的 `MonitorHost`;装配在工厂(`Pulse/MonitorAssembly.swift`),`SystemMonitor.init` 只收 采集源 / 告警 / 功能模块注册列表。测试只写在接缝上:RoundSpine、Leaderboard、各模块纯内核(壳层只留 `HistoryFeatureTests` 串行顺序一例)
  - 进度(integration/ticket-a):主干 + 扩展点、Leaderboard 内核(高3 完成)、排行模块(`RankingsFeature` + `RankingBoard`,L1 实际窗长 / L3 门控代号 / 门关不重算一并修掉;L6 两个无读方时间戳随迁移撤除)、历史模块(`HistoryFeature` + `HistoryFeed`,串行写入、磁盘记账恰好一次)已落;出生登记同 pid 冲突改为「回灌与活记录按身份判别,pid 复用活记录胜」(规则钉在 `RoundSpineTests`)。**待迁**:告警喂食、dev server、网络、磁盘(含 fresh/stale 恰好一次标记)、电池——迁完 SystemMonitor 只剩主干与派发,高1 才算完
- 可见性门控约定不变:排行只在窗口可见时推进(工单 module-rankings/01 的预算口径)
- `sh scripts/test.sh` 全绿;ripwire 查影响面、ast-grep 做机械改写(AGENTS.md 工具策略);改 SystemMonitor 前先 `git status`(用户可能并行改码)
- 完成判据:全仓库全进程 rusage 循环只剩心跳一处;组聚合排序/tie-break/leader 只有一处实现一份测试;SystemMonitor 不再持有排行 pid 表与磁盘记账账本
