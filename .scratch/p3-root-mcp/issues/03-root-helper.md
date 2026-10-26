# 03: root helper——SMAppService daemon 落进真工程 + Energy Impact 采集(拍板门:做不做)

**What to build:** 探针①主路的工程化(docs/probes/09 全部实证可直接抄):
helper 可执行 + plist(`BundleProgram` 相对路径)嵌 Pulse.app 的
Contents/Library/LaunchDaemons/,build.sh 双端签名(helper 先、app 后,
`--options runtime --timestamp=none`,现有自签身份——升级不丢授权已证);
设置页安装开关 → `SMAppService.daemon.register()` → 指引用户系统设置批准
(首次一次性)→ status 轮询点亮;XPC 对端校验(无 Team ID:以证书 SHA-256
anchor 的 designated requirement 表达,Procexp PeerValidation 路数;
NSXPC `.privileged` 传输只走 NSData/NSString/NSNumber/NSError);
helper 周期跑 `powermetrics -n 1 --show-process-energy` 解析 Energy Impact
回传 app(落 gauge_min 新 key,复用票 09 窄表加量零迁移管线)。

**⚠️ 拍板门(探针②口径,grill 时先拍这个再做)**:root 硬增量已收敛为
Energy Impact 一项(per-app GPU 本机存疑、网络/全机功率免 root 已覆盖)。
"只为能耗归因装一个 root daemon"值不值,由用户拍:做 / 缓做(先 MCP) /
不做(04 换数据源或砍)。探针只给数据不替拍。

**Blocked by:** None(拍板通过后可做;与 02 并行)

**Status:** needs-triage

- [ ] build.sh 产物含 helper 且双端签名验证通过(探针 09 组合复刻)
- [ ] 安装→批准→root 跑全流程在真 Pulse 上走通(unregister 一步干净复原)
- [ ] XPC 对端校验生效:伪造/未签名客户端被拒(单测或探针证)
- [ ] Energy Impact 数据进历史库(gauge_min 新 key 零迁移自动出现)
- [ ] helper 常驻成本实测记档(powermetrics 单发节奏 × 常驻开销,对齐节奏矩阵)

**待拍板点(grill):** 做不做(拍板门)、powermetrics 采集节奏(60s 档?)、
设置页入口形态、helper 与 app 的数据通道(XPC 推 vs helper 直接落库)。
