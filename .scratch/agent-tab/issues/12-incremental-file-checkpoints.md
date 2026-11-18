# agent-tab/12 Claude jsonl 增量检查点扫描

Status: ready-for-agent
Type: task

## 背景

账本三源里 Claude jsonl 是唯一"每次全量重读重解析"的源:

- 定时档(5 分钟)只喂**今天改动过的文件**——但活跃会话文件恰恰是最大的
  (数百 MB),每轮全部重读重解析;
- 全量档「重新扫描」重读全部 2.9GB / 711 个文件。

2026-11-18 实案:负载 60-77 下用户点「重新扫描」30+ 分钟未完(采样定位
readClaudeTranscripts + NSJSONSerialization 满负荷;当日热修的 `"assistant"`
字面量预筛只把解析量砍到 1/3~1/5,IO 与活跃大文件重读没动)。

tokscale(源码 `sessions/claudecode.rs:650` 起)的对应物:**每文件检查点**——
已消费字节偏移 + 前缀 SHA-256 + 解析状态;续扫先哈希校验旧前缀(零解析),
再从偏移只解析新增字节;前缀哈希失配(原地改写/compact)→ 该文件全量重解析。
本票把同款机制搬进 Pulse。

## 目标

1. **增量读取**:文件未变(mtime 与检查点一致且 size==offset)→ 零打开零解析,
   检查点缓存贡献直接进合计;追加了内容 → 只解析新增字节(前缀哈希校验);
   改写/变小 → 全量重解析该文件。
2. **等价性**:多轮演化(追加/原地改写/删除/复制 resume)后,账本 == 全量重解析
   的结果(合成夹具断言)。
3. **去重保持**:跨文件 message-id 去重(resume 复制历史进新文件不双计)必须
   在增量模式下保持——靠全局 seen 表,不是每轮全量重看。
4. **性能验收**:稳态刷新(全部文件有检查点、仅 1-2 个文件各追加 ≤1MB)端到端
   < 2s(本机,含 stat 全部文件)。

## 设计要点(已拍板方向)

- 新表 `agent_file_checkpoints(file_key PK, consumed_offset, prefix_sha256,
  buckets_json)`:`buckets_json` = day × project(可空)× model(可空) →
  五桶 + 请求数的嵌套聚合,即该文件当前内容对账本的**完整贡献**。
  - 偏移只推进到**完整行边界**(含换行);无换行尾巴留在未消费区,下轮重读。
- 新表 `agent_seen_messages(message_id PK, file_key, day)`:全局去重状态
  (实测全史 ~15 万行,sqlite 量级轻松)。扫描时整表载入内存 Set。
  - 文件全量重解析前,先按 file_key 清掉它的 seen 行(否则 compact 后幸存轮次
    会被自己旧 id 误判重复 → 漏计);
  - 文件删除 → 检查点 + seen 行按 file_key 级联清;**账本旧行保留**
    (账本不受源存亡影响是 agent-tab/02 的立身之本)。
- **账本行 = Σ 全部检查点 buckets**(每轮完整重算,便宜——711 个 JSON 求和)。
  由此:
  - compact 改写 → 该文件贡献替换 → Σ 自动反映缩水,账本自愈,无需人工重扫;
  - 只 upsert Σ 中**有数据的天**;某天最后一个文件被删 → 该天账本行保留旧值
    (不归零)。
  - **取代 agent-tab/02 热修的「定时档只写今天」护栏**:那是"今天子集覆盖完整
    历史"问题的补丁;检查点 Σ 是完整口径,写全部有数据的天反而自愈缩水。
    行为变更,实施时把该回归测试改写成"闭环会话不缩水"的新语义(见下)。
- 升级路径:无检查点首轮 → 一次全量(预筛后分钟级),之后永久增量。
- stats-cache 回填逻辑不动(只填无细粒度数据且非今天的天)。
- ZCode 侧不动(查询本就按 started_at 增量,33MB 用量表非瓶颈)。

### IO 协议变化(AgentUsageReading)

```swift
func claudeFileInventory() -> [ClaudeFileRef]          // key/mtime/size
func readClaudeFileIncremental(
    _ file: ClaudeFileRef,
    checkpoint: (offset: UInt64, prefixSha256: Data)?,  // nil = 全量
    consume: (_ line: String) -> Void
) -> ClaudeFileReadOutcome
// .unchanged / .advanced(offset, sha256) / .rewritten(→ 调用方清 seen 后全量重读)
```

旧 `readClaudeTranscripts(modifiedSince:)` 删除(唯一调用方就是本路径)。
Live 实现:mtime+offset 快路径不打开文件;校验前缀时流式 SHA-256 只读不解析;
`FileHandle.seek(toFileOffset:)` 起读。

## 验收

- [x] 合成夹具多轮等价测试(追加/改写/删除/resume 复制,增量结果 == 全量重扫)
- [x] 改写检出:前缀哈希失配 → seen 清理 + 全量重解析,该日贡献替换不残留
- [x] 闭环会话不缩水回归(替代 agent-tab/02 热修的旧断言):round1 全量 →
      round2 仅另一文件追加 → 昨日合计 = 缓存贡献 + 新增量,非子集
- [x] 去重:resume 复制文件出现,历史 id 不双计
- [x] 性能探针:稳态刷新 < 2s —— **实测 1.82s**;冷启动(2.9GB 首轮全量,
      负载 60+)实测 **160.3s**(旧全量重读路径 30+ 分钟未完)
- [x] 迁移:HistoryDatabase 新增两表;老库升级不动既有账本行

## 票外(显式不做)

- ZCode SQL 聚合下推(非瓶颈);
- 检查点文件级 mtime 骗过(时钟回拨)的极端防御——哈希是权威,mtime 只是快路径。

## Comments

- 2026-11-18 立票。背景与机制查证、tokscale 源码对读、预筛热修见本会话;
  用户拍板「做」(增量检查点)并要求开票走流程。
- 2026-11-19 落地合并(单 commit,14 文件 +1676/-506;核心 836 + app 514
  = 1350 例全绿;PulseCoreTests/AgentIncrementalModelTests 假 reader 多轮
  演化 + PulseTests/AgentIncrementalLiveTests 真实文件等价性两条)。
- 实施偏差记录:①改写重读路径把「purge 后重读」改为「重读成功才 purge」
  (防竞态丢检查点),且贡献**替换**不与旧贡献 merge(防幸存轮次双计);
  ②引擎同时取代了 agent-tab/02 热修的「只写今天」护栏(Σ 完整口径,
  upsert Σ 中有数据的全部天,文件独占天在删除后冻结保留)。
- 环境备注:Documents 下 hosted 测试再次环境级挂起(runner 未建连,两次),
  按退路纪律在 /tmp/pulse-agent-usage-checkpoints 完成门禁;性能探针 =
  env 门控临时测试(TEST_RUNNER_PULSE_PERF_PROBE=1 + executionTimeAllowance
  放宽),未入仓。
- 新增已知 cosmetic warning 两处(AgentUsageReader 的 verifyHasher var→let、
  try? on 非抛 seek),非 error 级,后续顺手清。
