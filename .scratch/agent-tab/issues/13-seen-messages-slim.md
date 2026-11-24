# agent-tab/13 消息去重表瘦身

Status: done
Type: task

## 背景

2026-11-24 用户问「Pulse 的应用数据从哪来」。`~/Library/Application Support/Pulse/history.sqlite`
25.7MB,其中 **19MB 是 `agent_seen_messages`**(agent-tab/12 引入的全局 message-id 去重表),
监控采样本身只占约 1.5MB。

实测构成(6.5 万行,2026-08-01 起,388 个会话文件):

| 部分 | 大小 |
|---|---|
| 表本体 | 9.1MB |
| `file_key` 索引 | 7.4MB |
| `message_id` 主键自动索引 | 2.6MB |

浪费来自两处:

- 每行都完整重复一遍会话文件路径 `file_key`(平均约 90 字符),索引里再存一遍;
- `day` 列只写不读(`loadSeenMessageIDs` / `seenMessageIDs` 都只取 `message_id`)。

表没有任何清理机制,随用户用 Claude Code 线性增长。

## tokscale 怎么做的(对读 `crates/tokscale-core/src/lib.rs` ~3560 起、`message_cache.rs`)

- **没有全局 seen 表**。每个源文件一份缓存分片(bincode 二进制),存该文件解析出的
  **全部消息**,每条带 `dedup_key = messageId:requestId`;
- 跨文件去重在**每轮汇总时**于内存里重建 `HashMap<dedup_key, index>`,重复项按字段取大合并
  (`merge_claude_cross_file_duplicate`);
- 源文件消失后缓存条目**保留**(retained history),用户手动清缓存才删。

Pulse 不照搬:Pulse 检查点只存每文件的**聚合桶**(day × project × model),不存逐条消息,
跨文件去重必须在解析时完成,所以需要全局 seen 状态。tokscale 的形状(逐条消息缓存)
比我们现有的更重。借鉴点只有一条:去重键只存一份,不在每条记录里冗余携带文件身份。

## 方案

规范化 + 删无用列,语义不变:

- 新表 `agent_seen_files(id INTEGER PRIMARY KEY, file_key TEXT NOT NULL UNIQUE)`;
- `agent_seen_messages` 改为 `(message_id TEXT PRIMARY KEY, file_id INTEGER NOT NULL) WITHOUT ROWID`
  + `file_id` 索引;去掉 `day`;
- 迁移 `agent-tab-13-seen-slim`:建新表 → 按 file_key 搬数据 → 删旧表 → 改名 → 建索引;
- 迁移首次生效后跑一次 `VACUUM`(否则删掉的页不还给磁盘,文件不变小);
- `AgentCheckpointStore` 对外接口保持字符串 message id / file_key,换内部存法;
  `purgeFile` 同时删文件行。

在用户库副本上实测:seen 部分 19MB → 4.6MB,整库 25.7MB → 7.5MB。

## 显式不做

- **按时间淘汰旧 id**:resume 可以把任意久远的历史复制进新文件,淘汰会导致重复计数。
  正确性优先;瘦身后每行约 70B,增长可接受。
- **message id 哈希成 Int64**:还能再省约一半,但引入碰撞概念,收益不抵复杂度。
- 构建缓存 `~/Library/Caches/pulse-swiftpm`(399MB,开发机才有,与 app 数据无关)。

## 验收

- [x] 迁移测试:旧结构库带数据 → 迁移后 id 集、按文件取 id 结果与迁移前一致;`day` 列消失
- [x] 既有 AgentIncrementalModelTests 全绿(追加 / 改写 / 删除 / resume 去重等价性)
- [x] purgeFile 后该文件的 seen 行与文件行都清掉,不留孤儿
- [x] 迁移后库文件变小(VACUUM 生效)
- [x] 装机后智能体页用量数字与改前一致

## Comments

- 2026-11-24 立票。用户问应用数据来源 → 定位到本表;用户拍板「开票做 B」(给本表瘦身),
  并要求参考 tokscale 做法(见上)。
- 2026-11-24 落地:新增 AgentSeenSlimMigrationTests 5 例(含文件库 VACUUM 收缩;去掉 VACUUM
  反证测试会红),全量 1445 例全绿。VACUUM 失败不挡启动(pulse-mcp 读连接可能 busy)。
- 2026-11-24 装机核验(308ebf1):库 25.7MB → 9.0MB;迁移后 seen 6.5 万行 / 388 文件无损;
  账本 claude 请求数 65159 → 65175(装机间隔内本机新增会话的正常增量,无重复计数),zcode 不变。
