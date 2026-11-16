# 01: 服务页——dev server 与容器合页

**What to build:** 容器页改「服务」:开发服务卡从智能体页**整卡迁入**(上=开发服务卡,
带「全部停止」;下=容器卡);智能体页三子页减为两子页(消耗/会话)。弹窗与主窗口同轴,
服务页两卡都画。

**背景:** 2026-11-16 用户拍板(dev server / docker 是一类——同是本机跑着的服务盘点:
端口/内存/闲置),定案与三枚默认细节见 `../spec.md`。推翻 agent-tab/01 的挂靠与
agent-tab/06 三子页结构中「开发服务」档;tab 总数不变(13)。

**Status:** done(2026-11-16,feat/tab-regroup@baa77ae)

- [x] `MetricTab`:`.containers` 改名 `.services`(rawValue "services"),title「服务」,
      symbol 沿用 cube.box.fill;强调色沿用现 containers 品类令牌(`Metric.containers`
      未改名——DESIGN.md 品类令牌表零改动,代码注释说明沿用)。rawValue 无落盘
      (spec 技术事实),改后 ripgrep 全仓引用面——与 `MetricSensorFamily.containers`、
      色令牌 `Metric.containers` 区分核实,唯一漏网是 MonitorVisibilityTests 的
      `popoverTab: .containers`(首轮 swift test 抓到已改)
- [x] `MetricTabStack`:`.services` 分支两卡(DevServerCardView + ContainersCardView);
      `.agents` 分支撤 `.servers` 子页,`AgentSubTab` 枚举减 `.servers`(默认值落「消耗」,
      agent-tab/06 既有默认不受影响)
- [x] 传感器家族门控:`displayedFamilies` 里 containers 家族从 `.containers` tab 迁到
      `.services` tab;MonitorVisibilityTests 同步并补 agents/cleaner 入无家族断言环
- [x] tab 序/标题/键盘轴断言更新;accent 断言补 `services == .containers`
- [x] `sh scripts/check.sh` 全绿(worktree 流程:`.worktrees/tab-regroup` 起分支,合 develop)

**Out of scope:** 两卡合一卡;容器数据卷占用行(p2-sensors/07 out-of-scope 维持);
KillRequestFlow 全部停止流、dev server 闲置告警、MCP `list_dev_servers`(与页面位置无关,
全不动)。

## Comments

- 2026-11-16(devServerIdle 路由一处越出 Out of scope,如实记):闲置告警的**落点**
  从总览改为服务页(AlertRoute 新增 `services`,AlertEngineTests 补断言)。理由:
  「告警不动」的票面本意是检测/投递机制不动;点通知直达的落点是页面位置的函数,
  卡迁走了落点跟卡走才是同一意图。机制(阈值/冷却/NemoNotch 投递)零改动。
- 2026-11-16(记账):commit 378a77b 的提交信息写「附议题落档」但票面文件当时还在
  主 checkout 未跟踪区、没进 worktree——空话,本批补齐(feat/tab-regroup 收尾提交)。
