# 02: MCP server——独立 stdio 可执行,官方 swift-sdk,读 WAL 历史库作答

**What to build:** `pulse-mcp` 独立 stdio 可执行(官方 modelcontextprotocol/swift-sdk,
零权限零单向门,探针③绿灯的直接消费)。读 `~/Library/Application Support/Pulse/
history.sqlite`(WAL 只读连接,app 写者并存安全——探针实测)回答 AI 客户端提问;
app 不在跑也能答(回退最近落库样本)。首批工具三个:

- `why_cpu_high`:现在谁在吃 CPU——最近 sample_min top 进程组 + groups 名称 +
  system_min 系统趋势,交叉成一段结构化答案(弹药:sample_min 666k 行/298 组);
- `current_metrics`:当前读数(CPU/RAM/磁盘/网络/温度/GPU/功率,取各 metric
  最近值,gauge_min 窄表 + system_min);
- `history_query`:按 metric + 时间窗查历史(gauge_min/gauge_hour 按过滤)。

工程形状:新可执行 target(纯 Foundation + GRDB + swift-sdk,不碰 AppKit,
查询逻辑进 PulseCore 复用既有 Queries 层);产物嵌 Pulse.app bundle,
README 给 AI 客户端配置指引(claude desktop / ZCode 等)。

**Blocked by:** None(零依赖,可与 03 并行)

**Status:** needs-triage

- [ ] stdio JSON-RPC 握手通过(真 MCP client 或 inspector 连上并列出工具)
- [ ] why_cpu_high 真机答出 top 进程组,与 Pulse UI 排行互证一致
- [ ] app 在跑 / 不在跑两态都能答(不跑时如实标注"最近落库于 X 分钟前")
- [ ] 查询层单测进 PulseCore(合成库);check.sh 全绿
- [ ] 分发与配置指引落 README(嵌 bundle 路径 + 各客户端配置样例)

**待拍板点(grill):** 分发形态(嵌 bundle vs 独立产物)、工具参数化程度
(top-N/时间窗是否做成参数)、可执行命名。
