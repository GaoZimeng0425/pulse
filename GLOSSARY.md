# Pulse

菜单栏"App 视角"系统监视器:回答"到底是什么在占用我的 CPU",而不是给一千行进程列表。

## Language

### 采集

**采样 (Sample)**:
以固定节奏(弹窗关闭 5s / 打开 1s)对全部进程做一次指标采集。
_Avoid_: 轮询、扫描(泛指时)

**快照 (Snapshot)**:
一次采样得到的全部进程原始数据。归组的输入。
_Avoid_: 进程列表(那是原始呈现,不是这个)

### 归组

**组 (Group)**:
归组的输出单位:若干进程聚合成的一个显示实体,有稳定身份、显示名与聚合指标(CPU/内存/进程数)。
_Avoid_: 应用(仅在指 .app bundle 本体时用"App")、类别、聚合

**App 归属 (Bundle attribution)**:
进程(含 Helper/Renderer/XPC 子进程)归属到它所在的 .app bundle。
_Avoid_: 应用归属

**父链上溯 (Parent-chain walk)**:
非 bundle 进程沿父进程链向上走,直到命中有归属的祖先。中间进程先死会断链。
_Avoid_: 递归找父

**出生登记 (Lineage)**:
新进程出生时记录的父链快照,用于活链断裂后回查归属。
_Avoid_: LineageCache(那是实现名)、缓存父链

**项目归因 (Project attribution)**:
dev 类进程(rustc/node/vitest 等通用可执行文件)按其工作目录或 argv 中的路径归属到项目根;命中 worktree 目录时显示为"项目名 @ worktree"。
_Avoid_: 项目归属、仓库匹配

**项目根 (Project root)**:
用户配置的目录,项目归因的匹配锚点(如 `~/Documents/Learn/*`)。
_Avoid_: 工作区、workspace

**孤儿进程 (Orphan)**:
父链断到 launchd 且无 App 归属、无项目归因的进程。UI 中橙色高亮——它往往正是问题所在。

**组 CPU% (Group CPU)**:
组内全部进程 CPU 之和,单核为 100%,可超过 100%(如 445% = 约 4.5 个核满载)。与活动监视器同口径。

**系统 CPU 负载 (System CPU load)**:
全部核的占用率,0–100%,满核 = 100%。菜单栏数字用此口径。
_Avoid_: 总 CPU(和组 CPU% 混淆)
