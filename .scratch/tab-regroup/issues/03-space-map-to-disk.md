# 03: 空间地图迁入磁盘页

**What to build:** 空间地图从清理页子页**整卡迁入**磁盘页,磁盘页变五块:主卡、各卷
明细、快照、读写排行、空间地图;清理页子药丸 5→4(总览/全部清单/应用/清理历史)。

**背景:** 2026-11-16 用户拍板「空间地图应该在磁盘里」——它画的目录占用树本就是磁盘
占用可视化,与各卷明细/快照同页才齐;缩编 p6-cleaner/03 的 Q13 子页序(序不变,
「地图」档让位)。三枚默认细节见 `../spec.md`(就地扫描按钮/弹窗例外/跨页动线)。

**Status:** done(2026-11-16,feat/tab-regroup@95f5881)

- [x] 磁盘页加空间地图块 `DiskSpaceMapSection`(CleanerViews.swift,随 CleanerModel
      既有装配):空态就地「扫描整台 Mac」引导卡(action 即 startScan)/ 扫描进度卡 /
      地图卡+摘要卡——同一 CleanerModel 管线,与清理页头按钮一处开扫两处同步
      (isScanning 挡并发);扫描完成后的「重新扫描」走 SpaceMapSection 既有空树空态按钮
- [x] 跨页访问装配:MetricTabStack 新增 `cleanerModel: CleanerModel?` 参数——
      MainWindowView 传窗口持有的 cleanerModel,DashboardView(弹窗)两处传 nil
      (装配路径选了参数注入,不动 SystemMonitor:CleanerModel 是窗口存活期对象,
      MainWindowView @State 是唯一真身,monitor 不背窗口态)
- [x] 「这块能清」跨页动线:DashboardModel 新增 `pendingCleanerJunkGroup`,磁盘页
      点块 → 记路由态 + onSelectTab(.cleaner);CleanerTabView 新增该 binding,进页
      .task 消费(落全部清单 + 清过滤 + 定位组 + 自清)。下钻态 `spaceMapDrillPath`/
      `spaceMapTreeIndex` 随迁上提 DashboardModel(切 tab 不丢,07 语义保持)
- [x] `CleanerSubTab.map` 撤销(枚举+子药丸条+switch 分支);清理页余子页文案零改动
- [x] 弹窗例外:弹窗磁盘页不画地图(`!isCompact` 门控,native 列表与 List 回退同源
      blocks 自动一致);DESIGN.md 两窗例外清单入表(传感器例外同款)
- [x] 测试:清理页子页断言 5→4(CleanerAppSubTabTests);磁盘页块序列断言
      (主窗口含 disk-spacemap 且殿后、弹窗不含);跨页路由——消费在视图 .task,
      纯逻辑无新分支,登记面由 blocks 测试钉,动线归目验
- [x] `sh scripts/check.sh` 全绿(worktree 流程)

**Out of scope:** 地图卡与各卷明细数据合一(扫描口径 vs 容量口径仍两源);清理页总览
再放迷你地图;弹窗版空间地图。

## Comments

- 2026-11-16(实施取舍记):磁盘页版不套子页 ScrollView(清理页时代的自滚形态随迁页
  作废)——磁盘页卡片流本就在主窗口外层滚动里,嵌套滚动是 space-map-forms/10 前的旧坑;
  图表区高的 containerRelativeFrame 视口量化语义不变(量的就是滚动视口)。DESIGN.md
  空间地图卡条目与「历代已废」清单已同步。
- 2026-11-16(文案微调):空态引导从「点右上『扫描整台 Mac』」改为就地按钮——磁盘页
  页头没有扫描按钮,指路文案会落空。
