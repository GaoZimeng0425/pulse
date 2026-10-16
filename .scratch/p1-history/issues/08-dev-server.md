# 08: dev server finder

**What to build:** 主窗口总览页出现 dev server 卡:列出在跑的开发服务进程(闲置时长/内存/监听端口),argv 模式识别(vite/next dev/webpack/vitest watch/jest watch/runserver 等);只有候选进程才做端口扫描;「闲置」标签 = 最近 10 分钟 CPU≈0(注入时钟判定);「全部停止」走现有确认流,永不自动杀;闲置 >24h 告警规则接入工单 07 的引擎并真实可触发。popover 不放此卡。

**Blocked by:** 07(告警引擎)

**Status:** done (2026-10-16;真机走查随工单 12 验收)

- [x] argv 分类器单测:已知模式清单(10 种 19 例)+ 误报例(vitepress 路径 / vite-scan 可执行名 / webpack.config.js / vite·next build / next start / vitest run / tsc 无 watch / jest --watchman=false / manage.py migrate / cargo build 等 16 例)
- [x] 端口扫描仅对候选进程;成本约束有测试体现(10 进程 1 候选 → RecordingScanner 恰被调 1 次;路径含 vite 的误报进程同样不被扫)
- [x] 闲置判定注入时钟单测(观察时刻入参注入:满窗 600s 起记闲置 / 1% 活动线 / 活动重置 / 首见兜底 / 消失 prune 防 pid 复用继承);卡片数据(闲置/内存/端口)与真实进程吻合属真机走查(工单 12)
- [x] 「全部停止」经确认流(KillRequestFlow.stopAll 复用 KillConfirmationDialog 同一 NSAlert 关口,列全部目标逐个点名);单进程 kill 复用 KillAction.terminate + LiveKillService,不重造
- [x] 闲置 24h 规则用合成快照注入引擎验证真实触发(连续 3 轮超阈 fired / 消失立即 resolved / 重生重新走进入路径 / 活动 6 轮安全侧解除)

## 实现记录(2026-10-16)

- **argv 分类器(Pulse/DevServerFinder.swift,纯函数)**:候选 token = 可执行 basename + 解释器(node/bun/python)的脚本 token;十种模式(vite / next dev / webpack-dev-server / tsc --watch / vitest watch / jest watch / pytest --watch / manage.py runserver / bun run dev / cargo watch)各配参数规则——防误报靠精确 basename(vitepress、webpack.config.js 不命中)+ 一次性子命令排除(vite·next build、next start、vitest run、manage.py migrate、cargo build)+ watch 系要求显式 watch 参数(jest `--watchman=false` 前缀撞车不算)。`npm run dev` 不入列:npm 是过渡父进程,真正的 vite/next 子进程被命中,同一条 server 不出两行。
- **闲置环(DevServerIdleTracker)**:按 pid 记首见与最近活动两时刻(观察值 ≥1% 算活动);"闲置" = 距最近活动 ≥10 分钟(窗口票面值),闲置秒 = 现在 − 最近活动,从未活动则从首见起算(只承认看得到的历史,不编造)。nil 差分(新出生)只立基线不判活动。消失 prune 清状态,同 pid 重生不继承闲置史。全部时刻由调用方注入,合成时间轴单测。
- **端口扫描(LiveDevServerPortScanner)**:libproc 直调——PROC_PIDLISTFDS 列 fd(尺寸探测两段式)→ 仅 PROX_FDTYPE_SOCKET 逐个 PROC_PIDFDSOCKETINFO → 取 `soi_kind == SOCKINFO_TCP` + AF_INET/AF_INET6 + `tcpsi_state == TSI_S_LISTEN(1)`(宏不进 Swift,值钉死有注释)→ 本地端口 `tcpsi_ini.insi_lport`(int 网络序)转主机序去重升序。只读系统账不发包;进程退出/受限静默降级空。编排层保证只对 argv 命中的候选调用(成本约束单测钉死)。
- **卡片(Pulse/DevServerViews.swift)**:主窗口总览页"开发服务"分区(当前最忙之后);行 = 名(pid)/ 闲置时长(闲置琥珀、未闲置灰)/ 内存(物理足迹)/ 监听端口(无则如实"无监听端口");空态两行安静文案;"全部停止"按钮 + "停止需逐个确认,绝不自动杀"常注。popover 不放(工单拍板)。
- **告警接线(工单 07 留位补数据源)**:AlertFeed 新增 `.devServers([AlertDevServerSnapshot])`,引擎新增 dev server 主体的消失解除/逐进程评估(subjectKey = `devserver|pid`,route 总览不变);AlertCenter.ingestDevServers;SystemMonitor 每轮采样盘点后喂入(未闲置 nil 不喂——不伪造读数);`isDataSourceWired` 放开,设置页第五条规则入列(阈值以小时编辑),通知正文带真实闲置时长。SystemMonitor.init 增 `devServerPortScanner` 缝(默认 Live 实现)。
