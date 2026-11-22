# 01: 全局端口视图——服务页「监听端口」卡

**What to build:** 服务页(dev server 卡与容器卡之间)新增「监听端口」卡:
全机正在监听的 TCP 端口列表。行 = 端口号(`:5173` 等宽数字)+ 占用者副文
(名字 · pid 1234,多进程如实「等 N 个进程」)+ dev server 标注
(`vite · 闲置 10 分钟` 琥珀,与 dev server 卡同口径;非 dev server 不标)
+ 行级「结束」按钮。**结束 = 该端口全部占用进程**:单进程即单个;多进程
一张确认单点名全部(dev server 卡「全部停止」已验证形态)。确认流复用
KillRequestFlow 现有「结束进程」关口与文案,零新增。号序(端口号升序)+
前 20 行 + 展开收起(排行卡配方);空态安静两行;卡脚 tertiary 小字
「系统进程的端口可能不在此列」。

**背景:** 用户 2026-11-22 四摊候选点单(音量后排/智能体页余量/MCP 余量/
iSurge 差距)拍板先做全局端口视图——一次覆盖三处挂账:iSurge 差距③(全局
端口视图+一键释放)、agent-tab/06 wireframe 的「孤儿端口」候选(其「开发
服务」子页已被 tab-regroup/01 并入服务页,语义落点=服务页)、abtop 对照
同款。matt 流程 grill-with-docs 两轮拍板,共识如下。

**拍板(grilling 两轮共识,2026-11-22):**

1. 仅 TCP 监听口(UDP 噪音大且无监听语义,后排)。
2. 挂服务页,dev server 卡与容器卡之间(页义同族+票面血缘;dev server 卡
   曾住总览后被用户拍板挪走,先例反指总览)。
3. 行级「结束」复用「结束进程」确认流——**不做「释放端口」新词**(同一
   动作两个词违反词汇一致性)。
4. 号序 + 前 20 + 展开收起;上限进 DESIGN.md 令牌表。
5. 卡脚一行小字如实注 root 盲区。
6. 结束 = 该端口全部占用进程(多进程一张单点名全部)。
7. 刷新 10s 档 + 可见性闸(服务页可见才扫;ADR-0006)。
8. 不落库(端口=状态量,GLOSSARY 状态量不进历史);MCP `list_ports` 后排。
9. **不造「孤儿端口」词**——GLOSSARY「孤儿进程」已占用「孤儿」;dev server
   闲置标注即覆盖主场景(dev server 死不了但闲置着占口)。
10. GLOSSARY 新词条「监听端口 (Listening port)」随本票落(采集盘点口径)。

**成本探针实测(2026-11-22,/tmp/port-scan-probe,swiftc -O,三轮):**

- 全机 909 进程逐 pid fd 扫描:**2.9ms 均值 / 3.0ms 最差**(load 3.7–5.0
  下测得);10s 档折算单核 ≈0.03%——成本可忽略,10s 档无压力。
- 监听口量级:17 进程占 26 口(「前 20 + 展开」正好匹配)。
- 盲区实测:909 进程中 307 个 fd 读不到(root/已退)——第 5 条小字有据。
- ★两个事实修正记档:①darwin 27.2 上 `proc_listallpids` 只回 232 pid
  (`LiveProcessSource.swift` 注释「与 KERN_PROC_ALL 逐 pid 相等」已不成立)
  ——全机枚举必须走 KERN_PROC_ALL;Pulse 采集本就走此路,本功能从快照拿
  pid 列表天然不受影响,但别信那条旧注释。②`proc_listallpids` 返回值单位:
  尺寸探测 = 字节数(带 +1 尾巴),实取 = pid 个数,两种单位不同。

**分层与文件(PulseCore 纯逻辑 / Live / Feature / View 惯例):**

- PulseCore `PortInventoryModel.swift`:`PortHolder`(pid / name=
  `RawProcess.killTarget` 同口径:可执行 basename→argv[0]→"pid N" /
  devServerKind? / idleSeconds? 仅 dev server)、`PortEntry`(port +
  holders,同口多进程如实并列)、`PortInventory`(entries 号序 + 截断
  标记);缝协议 `GlobalPortScanning: Sendable`(批量方向
  `listeningPorts(pids:) -> [pid_t: [UInt16]]`,ADR-0004 薄缝,与单 pid 的
  DevServerPortScanning 相对);`PortInventoryFinder` 纯逻辑(快照 + 扫描
  结果 + devServers 盘点 → 归并/标注/排序/截断)。
- Live `LiveGlobalPortScanner.swift`:核心三步整体拷自
  `LiveDevServerPortScanner`(尺寸探测→列 fd→SOCKINFO_TCP+AF_INET/6+
  tcpsi_state==LISTEN,`insi_lport` 网络序),改批量循环;进程退出/受限
  静默空数组。
- Feature `PortsFeature.swift`(ContainerFeature 模板):onRound 存快照
  pid→RawProcess 投影(零新采集)、onEvent 收 `.devServers` 广播存最新盘点
  (不直读别的模块)、sensorDrivers 10s 档 + `visibility.shows(.services)`
  可见性闸、LastGood 语义。
- 装配三步(MonitorAssembly 注释规矩):①`MonitorFeatures` 具名字段
  `ports` ②registry 登记(devServers 之后)③`SystemMonitor` 透出
  `var ports`;`MonitorAssemblyTests` 自动钉住(漏登记=静默失联旧案)。
- View `PortsCardView.swift`:CardHeader/CardEntityRow/CardEmptyState/
  cardShell 标准件,不手写卡壳;isCompact 双档弹窗同画;截断行
  RankingOverflowRow 配方;**先补 DESIGN.md(令牌 + 服务页节)再写码**。
- 释放链:行「结束」→ holders 全折 `KillTarget` →
  `DashboardModel.requestEndProcess`(多目标确认单)→ KillRequestFlow →
  `SystemMonitor.terminate`(SIGTERM,EPERM/ESRCH 文案白拿)。

**测试:** PulseCore `PortInventoryFinderTests`(合成快照+假扫描+盘点:归并/
同口多进程/排序/截断/标注/名字口径;假扫描器照 DevServerFinderTests 的
RecordingScanner 模式);PulseTests Live 冒烟(测试进程内真
socket/bind/listen,断言自家端口出现在批量结果——扩
testLivePortScannerReadsRealListeningSocket 模式);MonitorAssemblyTests 钉
登记。探针不进自动化(测试负载最小化规矩)。

**Out of scope:** UDP、绑定地址列、SO_REUSEPORT 多持有者行内展开、MCP
`list_ports`(v2 候选)、「释放端口」口径确认文案、落库/历史、弹窗 360
专项打磨(行窄档降级按标准件自适应先例)。

**Comments(2026-11-22 收档):**

- 装配三处构造点逐一被编译器点名才补齐:live 工厂 / `InertSources.preview` /
  `MonitorAssemblyTests`(防漂移测试自己也构造全表)——新模块加构造参数,
  三处都要动;MonitorAssemblyTests 的 Mirror 断言随后自动钉住 ports 登记。
- check.sh 接 `| tail` 吞了真退出码(首查误判全绿,AGENTS 警告过仍踩)——
  长命令一律「重定向落盘 + echo 退出码入文件」。
- `lint.sh --fix` 的 noForceUnwrapInTests 自动修把测试里防御性 if-let 改成
  `if try scan[1] == nil || XCTUnwrap(...)`(合法场景会炸),已手改回
  「写入即非空」契约断言——自动修复后必读 diff。
- `let idle = switch ...`(conditionalAssignment 规则)与 import 排序均由
  --fix 收编,语义零变。

**Status:** done(2026-11-22 同日闭环:dd14fa0 实现 → 70bd69f 合 develop,Release 已装机重启;check 全绿——app 侧 529 例 + 核心包全量 0 败,新增 9 例。装机后收尾三教训记 Comments)
