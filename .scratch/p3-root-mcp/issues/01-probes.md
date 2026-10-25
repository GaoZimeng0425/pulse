# 01: 探针先行——特权安装路径实机选型 / root 独有数据值不值 / MCP stdio 可行性

**What to build:** P3 档(root helper + MCP server + 每 App 网络归因 + Agents 用量卡)
开工前消雷,三路一次性探针,先例 p2-sensors/01。探针失败同样落档:如实记录失败
模式,消费票据此走回退路径,不算探针票失败。

- **① 特权安装路径实机选型**(单向门前置):root helper 怎么装。候选
  (a) SMJobBless——要求 app/tool 双端 designated requirement 匹配,自签身份
  `Pulse Local Code Signing`(登录钥匙串、无 Team ID)能否通过是核心疑问;
  (b) SMAppService daemon(macOS 13+ 官方现代路径,注册时一次 admin 授权弹窗);
  (c) 回退 launchd + osascript admin 弹窗。最小实机试验 + 文献核对,双向签名
  匹配与卸载残留摩擦都记档。
- **② root 独有数据值不值**:sudo powermetrics(`-n 1` 单发,per-app GPU/
  能耗/网络真输出格式落档)——**用户参与点:sudo 密码只由用户输**;对照组
  IOReport 免 root per-task 能耗(探针 04 经验延伸,若够用则 root 值下降)。
  顺带评估每 App 网络归因与 Agents 用量卡的数据源(nettop 已免 root,root
  增量在哪)。产出"值/不值"的数据依据,不做主观判断。
- **③ MCP stdio 可行性**(零权限零单向门):swift-sdk
  (modelcontextprotocol/swift-sdk)现状与 macOS 版本要求;历史库
  `~/Library/Application Support/Pulse/history.sqlite`(**WAL 模式**)跨进程
  只读并发方案验证(WAL 下多读者与 app 写者并存是否安全);首批工具形状草案
  (why_cpu_high 风格:当前读数 + 历史库 + 进程排行交叉作答)。

**Blocked by:** None (can start immediately)

**Status:** needs-triage

- [ ] 特权安装路径有实机结论:自签 + SMJobBless 成/败实证,或 SMAppService
      daemon 注册走通,或如实记录失败模式与推荐回退
- [ ] root 独有数据实测落档:powermetrics per-app GPU/能耗真输出(用户 sudo
      参与)+ 免 root IOReport 对照,"值/不值"有数据支撑
- [ ] MCP 可行性结论:SDK 选型 + WAL 跨进程只读方案验证 + 首批工具清单草案
- [ ] 探针源码+输出按既有编号规则存档 docs/probes/(自 08 起),不留 /tmp

## Comments

**2026-10-26 文献轮完成(实机轮待 triage 后)**:

- **① 特权安装路径——方向已定,主路 SMAppService daemon,SMJobBless 弃**:
  - SMJobBless:长期 deprecated;[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
    明确自签身份不参与 DR 验证(除非系统显式信任),新版 macOS 越收越紧 → 不试。
  - **SMAppService daemon(macOS 13+)配持久自签身份被 Microsoft Procexp for Mac
    实证可行**([Helper README](https://github.com/microsoft/ProcexpForMac/blob/main/Helper/README.md)):
    生产 Developer ID、本地持久自签;**ad-hoc 构建无法注册**(「can run without
    the helper but cannot register it」)。Pulse 的 `Pulse Local Code Signing`
    恰好就是持久自签(build.sh 链路 2026-10-24 建的)——**基础设施白捡**。
  - **Gap:现有自签证书无 OU 字段**(make-signing-cert.sh 只有 CN+O;签名里的
    Team identifier 来自证书 OU)。[skhd.zig 案例](https://github.com/jackielii/skhd.zig/issues/53)
    指向"自分配 Team ID 的自签证书可过"。→ 实机轮验证:重建带 OU 的证书
    (一次性成本 = TCC 重授权一次,AGENTS 已有记档),app+helper 同身份签,
    `SMAppService.daemon(plistName:).register()` 能否走通。
  - **App 不需要 service-management entitlement**(Procexp 实证:加了无配套
    provisioning 反而阻止 app 启动)→ 无需付费开发者账号。
  - 实施参考:Procexp `Scripts/dev_install_helper.sh`(自签本地安装)+ 
    `PeerValidation.swift`(XPC 对端校验:helper 读自身签名 Team ID 要求 app
    匹配)可直接抄路数;NSXPC `.privileged` 传输只走 NSData/NSString/NSNumber/NSError。
- **② root 数据——待实机(用户 sudo 参与点)**:命令已备
  `sudo powermetrics -n 1 -i 1000 --show-process-energy --show-process-gpu
  --show-process-netstats`,输出落档后分析 per-app GPU/能耗/网络真格式;
  IOReport 免 root per-task 对照同轮跑。
- **③ MCP——全线绿灯**:官方 [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)
  活跃(实现 2025-11-25 spec,Swift 6 ready,Swift Package Index Active);
  历史库实况:`journal_mode=wal`(跨进程只读与 app 写者并存安全),弹药充足
  ——`sample_min` 666,005 行(每分钟每进程组 CPU/内存/磁盘)、`groups` 298 组、
  `system_min` 9,527 行、`gauge_min` 窄表 35,836 行(票 09 已在产)。形态建议:
  独立小可执行 stdio server,读库不依赖 app 在跑;首批工具 why_cpu_high
  (内存态缺则回退最近 sample_min)+ current_metrics + history_query。
