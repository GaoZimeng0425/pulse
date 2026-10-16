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
新进程出生时记录的父链快照,用于活链断裂后回查归属。两个登记来源:独立出生扫描(每 ~2s 扫新 pid)与采样轮兜底。
_Avoid_: LineageCache(那是实现名)、缓存父链

**项目归因 (Project attribution)**:
到达归因层(未被 App 归属先行认领)的进程按其工作目录或 argv 中的路径归属到项目根——不限可执行文件名;命中 worktree 目录时显示为"项目名 @ worktree"。
_Avoid_: 项目归属、仓库匹配

**项目根 (Project root)**:
用户配置的目录,项目归因的匹配锚点(如 `~/Documents/Learn/*`)。
_Avoid_: 工作区、workspace

**后台服务 (Background service)**:
挂在 launchd 之下、可执行位于 launchd 域的兜底归属。域 = /Library/LaunchAgents|LaunchDaemons、/System/Library、/Library/SystemExtensions、/Library/PrivilegedHelperTools、/Library/Developer、/usr/sbin、/usr/libexec、~/Library/LaunchAgents(2026-10-16 扩充:/usr/{sbin,libexec} 的 ~200 个 Apple 系统守护此前被误成孤儿);/usr/bin、/usr/local、/opt/homebrew 刻意不在域内。

**孤儿进程 (Orphan)**:
父链断到 launchd 且无 App 归属、无项目归因的进程;可执行不在 launchd 域者(即便父是 launchd)也归此类。UI 中橙色高亮——它往往正是问题所在。

**组 CPU% (Group CPU)**:
组内全部进程 CPU 之和,单核为 100%,可超过 100%(如 445% = 约 4.5 个核满载)。与活动监视器同口径。

**系统 CPU 负载 (System CPU load)**:
全部核的占用率,0–100%,满核 = 100%。来源 = 每核 tick 统计(host_processor_info)差分——内核与 root 时间计入,与活动监视器同源;不从进程 CPU% 累加推导(那会少计)。菜单栏数字用此口径。
_Avoid_: 总 CPU(和组 CPU% 混淆)

### 历史与告警

**告警规则 (Alert rule)**:
「指标 × 阈值 × 持续时长 × 冷却期」构成的通知触发条件。进入需连续多次采样超阈,恢复需连续多次低于阈值减去滞后量——防止读数在阈值附近抖动造成通知风暴(该防抖即迟滞)。
_Avoid_: 告警(单指通知动作本身时)

**dev server**:
开发期本地常驻的服务进程(vite / next dev / vitest watch 等),按命令行模式识别;盘点其监听端口、内存与闲置时长。
_Avoid_: 开发服务器、本地服务(泛指时)

**闲置 (Idle)**:
dev server 近期 CPU 持续几乎为零的状态;闲置超过告警阈值(默认 24 小时)即提醒,处置永远由人确认。
_Avoid_: 空闲(混指系统整体负载低)

### 传感器口径

**容器级容量 (Container capacity)**:
APFS 以容器为单位共享空间,单卷 statfs 的空闲数不可信;容量口径 = 容器总量对账各卷已用(对不上的差额记"其他卷"),与 Finder 一致。
_Avoid_: 卷容量(仅指单卷时)

**可清除空间 (Purgeable)**:
系统判定需要时可自动回收的缓存类空间,取两种"可用容量"官方口径之差得到;与"实际可用"是两个数,文案要区分。
_Avoid_: 可用空间(混指)

**本地快照 (Local snapshot)**:
Time Machine 等留在本地卷的时间点快照;既计入已用空间,又常被同时算进可清除空间。
_Avoid_: 备份(泛指时)
