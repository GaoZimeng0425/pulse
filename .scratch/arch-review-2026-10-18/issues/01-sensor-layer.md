# 01: 票 A —— 传感层收敛(P2 前必做)

**What to build:** 架构审查(本目录 REPORT.md)三条「高」+ 两条「中」传感层债一次收口。
审查判定:P2(GPU/ANE/SMC)开工前必做,否则新传感器顺着最省力的路复制债。

**Status:** ready-for-agent

范围(细节与 file:line 证据见 REPORT.md §高1/§高2/§高3/§中5/§中6):

- [ ] **高1 SystemMonitor 收敛**(REPORT §1):拆出 SensorHub(可见性门控 + provider 调度登记)/ ModuleRankingModel(三张 pid 表 + 时间戳)/ 历史喂入编排(pendingDisk 记账账本)为独立可测类型;门控折算下沉纯函数进单测;init 参数减半;「UI 粘合层不写单测」豁免随之收回
- [ ] **高2 rusage 双采集通道合一**(REPORT §2):心跳快照(LiveProcessSource.swift:179,每 pid 已读 V3 含磁盘字节)是唯一采集通道;RawProcess 增补 wakeups(V3 本就含);三个排行差分账本(能耗/磁盘/网络——能耗与磁盘吃 rusage 表)改吃心跳快照表,撤销 ProcessRusageSource 的第二条全进程扫描(proc_listallpids + RUSAGE_INFO_CURRENT,ProcessRusageSource.swift:40-53);可见性门控降级为「推进/暂停差分」;RusageSumDiskThroughputSource 同步改吃共享心跳表
- [ ] **高3 组聚合内核统一**(REPORT §3):提 (identity, 值序列) → 排序 + tie-break + leader 归一 的纯函数内核;三处改调:MetricTabContent.build(MetricTabModel.swift:194/200/227,次键 lhs.id)、ModuleRankingAggregator(次键 lhs.key,且从视图 body 挪出、与 allGroups 两套时钟合一)、MainWindowView.swift:440 内联 cpuLeader;模块排行折叠挪进 SystemMonitor 同轮落地(错位超一轮不出榜)
- [ ] **中5 GatedDifferingSensor 泛型收口**(REPORT §5):门控 + 差分账本 + lastGood 五件套手抄三份 → 值组合泛型折叠(非继承,不违 ADR-0004),契约一次写一次测;P2 的 GPU/ANE 直接复用
- [ ] **中6 nettop 子进程健壮性**(REPORT §6):看门狗超时升级 SIGKILL(现在只 SIGTERM,吞信号 = 串行队列永久冻结);失败沿记状态日志(沿 databaseHealthy 的 transition-not-tick 惯例)

约束与验收:
- 分两段子代理:数据层(高2 + 中5 + 中6)先行,SystemMonitor 拆分 + 组聚合统一(高1 + 高3)随后(依赖前者的快照表形状)
- 可见性门控约定不变:排行只在窗口可见时推进(工单 module-rankings/01 的预算口径)
- `sh scripts/test.sh` 全绿;ripwire 查影响面、ast-grep 做机械改写(AGENTS.md 工具策略);改 SystemMonitor 前先 `git status`(用户可能并行改码)
- 完成判据:全仓库全进程 rusage 循环只剩心跳一处;组聚合排序/tie-break/leader 只有一处实现一份测试;SystemMonitor 不再持有排行 pid 表与磁盘记账账本
