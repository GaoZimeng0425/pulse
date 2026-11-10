# mcp-eyes: 让 AI 看全机——内存/磁盘排行、进程档案、告警史、dev server 盘点

## 拍板(用户,2026-11-10)

方向 B(mcp 四案之一):让 AI 使用 Pulse 更顺——把整机的"眼睛"给 AI,替用户诊断,不必跑终端命令。

## 范围

新增 5 个 MCP 查询工具(全部只读;既有 5 工具零改动):

1. `why_memory_high`——时间窗内内存排行(组口径,均值+峰值)。数据已在 sample_min.mem_max,纯查询层。
2. `top_disk_io`——时间窗内磁盘读写总量排行(组口径)。数据已在 sample_min.disk_r/disk_w,纯查询层。
3. `process_info(query)`——进程档案:lineage 出生登记表按 pid 精确查或按可执行路径/命令行/工作目录子串查;返回父进程/可执行路径/cwd/argv/首见时刻;MCP 侧对每个 pid 做 `kill(pid,0)` 活性探针如实报"已退出"。
4. `recent_alerts(hours)`——告警历史。**需先落盘**:新表 alert_event,AlertCenter 触发时经 actor 单点写入。
5. `list_dev_servers`——dev server 盘点(种类/闲置/端口/内存/最后见到时刻)。**需先落盘**:新表 dev_server_state,HistoryFeature 消费既有 `.devServers` 每轮广播,store 内部分钟节流。

## 架构落点

- 查询/文案/DTO 全在 PulseCore(新 `InsightQuery` 三查 + `McpEyesSupport` 文案单出处 + `AlertEventStore`/`DevServerStateStore` 两个 actor),真 SQLite 夹具单测;pulse-mcp 只接线。
- 落盘走历史模块独占写库的既有纪律:HistoryFeature 暴露两个新 store(同 CleanHistoryStore 样板);dev server 经 FeatureEvent 消费(DevServerFeature 零改动);告警在 AlertCenter.handle(.fired) 单入口 fire-and-forget 记一笔(触发稀疏,乱序无害)。
- 迁移 `mcp-eyes-v1` 建两表;dev server 行分钟粒度 upsert,pid 消失超 10 分钟即删;查询侧如实标数据年龄,不伪造"此刻仍在跑"。

## 明确不做(v1)

- 不加应用内告警历史 UI(落盘先服务 MCP;UI 另立票)。
- 不做按应用网络排行(system_min 只有整机网络,库里没有按组数据——如实不造)。
- 进程档案不做活性落库(kill 探针在 MCP 侧现查,库里不存"活着")。
