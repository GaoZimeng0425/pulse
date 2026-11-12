# 02: 每日 token 图表——三源账本 + 定时今天 + 手动全量扫描

**What to build:** 智能体页新增「每日消耗」能力:Claude Code + ZCode 两家按天 token
聚合,折线图(7/30 天)+ GitHub 贡献图式热力图;数据落 Pulse 自己的 GRDB 库,
**双档刷新**(2026-11-12 用户拍板):定时档只重算「今天」(分钟级节流,跨午夜偏差
用户明示接受,只算一天不做今天+昨天双覆盖);全量档 = 图表卡「重新扫描」入口手动
触发,后台线程补齐漏掉的天(未启动 Pulse 的日子、首次上线库空自动跑一次)。

**背景与口径(全部实测 2026-11-12):**
- ZCode 权威源 = `~/.zcode/cli/db/db.sqlite` `model_usage` 表(4.6 万行/33MB,
  全表按天聚合 48ms;大文件 2.8GB 是 part/message 对话正文,不碰)。
  **口径陷阱(tokscale zcode.rs 实证):`input_tokens` 已含 cache_read+cache_creation、
  `output_tokens` 已含 reasoning,五桶非互斥;用 `computed_total_tokens` 探形状
  (total==input+output 则含重叠,减之)。schema 防御:列缺失按 legacy 处理
  (无条件减重叠),表不在安静返回空。**时间锚 `started_at`(非 completed_at,
  tokscale #890 教训)。历史起点 2026-10-12。
- Claude 细粒度源 = `~/.claude/projects/**/*.jsonl` 每 assistant 行 usage 五桶
  (Claude 侧五桶天然互斥直接加总);按 message.id 去重防 stream 多行重复计。
  **30 天滚动删除进行中(cleanupPeriodDays 未设)——窗口外不可重建。**
- Claude 粗粒度兜底 = `~/.claude/stats-cache.json` dailyModelTokens(2026-08-01 起,
  只有按天按模型 total;新鲜度不受控,只做 jsonl 缺失天的回填,origin 标记区分)。
- 落库表 `(day, source)` 主键覆盖式 upsert,重扫永不重复计数;origin 列
  (db/jsonl/cache)留排查线索。
- ZCode 归一化 + 形状检测为纯函数进 PulseCore(GRDB 依赖已在包允许清单)。

**范围裁剪(用户拍板):** 只算一天、跨午夜偏差接受;不做今天+昨天幂等双算。

**Status:** done(2026-11-12,develop@873f6e9;装机目验归用户)

- [x] PulseCore `AgentUsageModel`:ZCode 行归一化/形状检测(computed_total 探针,
      legacy 无条件减 / modern NULL 透传)、时间锚 started_at(completed-duration
      回推)、Claude 行解析(assistant + usage 五桶,thinking 不另加)、
      **message.id 全局去重**(resume 复制进新文件不双计;无 id 如实计)、
      stats-cache 解析、按天聚合器、合并策略(cache 只填非今天缺天)、
      `AgentUsageStore`(主键 (day,source) 覆盖 upsert / insertIfAbsent)、
      编排器(定时档 300s 节流只算今天 / 全量档三源+回填)
- [x] 落库:`HistoryDatabase` 迁移 `agent-tab-02-usage` 加表 `agent_daily_usage`
      (+tableNames);store 经 HistoryFeature 暴露(同库同队列,引擎缺席安静禁用)
- [x] Live `LiveAgentUsageReader`(home 注入):GRDB `PRAGMA query_only` +
      busyMode .timeout(3) 只读连 db.sqlite,列探测降级(表不在/legacy 列缺
      安静空);jsonl 64KB 分块流式逐行(mtime 文件级过滤;`~/.claude/transcripts`
      wrapper 无 usage 不扫)+ `AgentUsageFeature`(首轮库空自动全量;IO 全后台
      utility 档)+ 装配三步 + Inert 桩
- [x] UI `AgentUsageViews`:「每日消耗」卡插 Claude Code 会话卡之下——
      PillTabBar 7/30 切换 + 折线(Canvas,缺天画 0)+ 近 13 周四档色阶热力图 +
      卡头「重新扫描」(扫描中转圈禁用);标准件全组装,agentsAccent/tokenText
      与 AgentViews 共享提取;零新令牌
- [x] 测试:PulseCore 15 例全绿(归一化三态/时间锚/行解析/去重/分天/合并/落库
      覆盖写/节流与今天限定/回填缺天);Live smoke 6 例(现代/legacy schema/
      库缺席/流式与 mtime 过滤/stats-cache)
- [x] `sh scripts/check.sh`:**1274 例全绿**(核心包 + app;/tmp 复核——
      .worktrees 下 test runner 三连挂起,环境级 flake 非 用例问题,同码 /tmp
      全绿;smoke 首轮两真失败已修:GRDB 建库需先建父目录、mtime 边界用
      一分钟前模拟「今天」);合并 develop@873f6e9;hook 已 Release 装机重启;
      已推 origin

**Out of scope:** 按项目/工作区维度的每日分解(worktree 归组,候选二期)、成本
美元列(LiteLLM)、按小时粒度、ZCode 会话级明细、MCP 工具暴露。
