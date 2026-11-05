# 01: 按应用内存合计的口径说明(Memory by App 注脚 + MCP 标签)

**What to build:** 2026-11-05 NemoNotch 8.8GB 追查(见 Comments)暴露两处口径迷雾:①Memory by App 环心「全部应用 N GB」合计可超物理内存(footprint 含压缩按原大小 + 共享重复计),卡上无说明,外部 agent 据此误判「40GB > 32GB 物理上不可能是当前占用」;②MCP `current_metrics` 标签「内存(全组峰值合计)」被误读成「历史峰值累计、进程退出不往下减」(实为最新一分钟内各组峰值的合计,逐分钟随活进程波动)。用户拍板「好, 补一下」:**两处补口径说明,不改数值口径**。

**Status:** done(立票即分诊:用户直报 + 拍板已定;纯文案/展示层,无行为变化)

- [x] `RingCardView` 加可选 `footnote`(`{typography.micro}` 10.5 tertiary,统计卡注脚同款角色;nil = 不画);`memoryByApp` 工厂传「含压缩(按原大小)与共享重复计,合计可超物理内存」,`memoryByType` 不受影响
- [x] pulse-mcp `current_metrics` 标签:「内存(全组峰值合计)」→「内存(全部应用·当分钟峰值合计,含压缩可超物理内存)」
- [x] `sh scripts/check.sh`(`.worktrees/memory-caption` 内直跑,无挂死):lint 过、PulseMCP/PulseHelper 构建过、**1072 例 0 失败**(核心 634 + app 438)
- [ ] 用户目验:弹窗/主窗口内存 tab「按应用」卡图例下有一行灰色小字;MCP `current_metrics` 内存行新标签

## Comments

- **背案(2026-11-05)**:NemoNotch 组 8.80GB = 其包内 `mediaremote-mini.pl` 守护真实泄漏(`ri_phys_footprint` 8.69GB 而 RSS 10MB,库内三日两周期锯齿 0.2→14.29GB;主进程 0.17GB 健康)。Pulse 数字与内核/`top` 完全一致,「按应用内存 = 每轮活进程 footprint 求和」(`GroupingEngine.swift` 归组求和)无罪——但对账成本高,本票只降误解面,不动口径。
- MCP 数值本身仍是「最新一分钟各组 `mem_max` 求和」(`InsightQueries.latestSnapshot`),标签改写不触碰查询。
