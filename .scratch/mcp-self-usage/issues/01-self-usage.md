# 01: MCP 自查账本工具 self_usage

**Status:** ready-for-agent

**What to build:** pulse-mcp 新增第 12 个工具 `self_usage`:AI 会话内一问,
一次答全**当前会话 + 今天 + 近 7 天**的 token 用量——五桶(净输入/输出/缓存读/
缓存写/推理)+ 合计 + 请求数;单位只有 token(美元用户明拍不要)。纯文本返回,
与现有 11 工具同风格。

**背景:** AI 方向最后一块主要余量([[pulse-mcp-ai-direction]] 余量 A)。
2026-11-23 grilling 定稿(两轮:Q3「区分 harness」被用户纠正后作废——
MCP 是通用协议,工具就一个)。

**拍板(grilling,2026-11-23 用户「同意」):**

1. Q1 一次答全:当前会话 + 今天 + 近 7 天,各带五桶明细与请求数(AI 一问全拿到)。
2. Q2 只报 token,五桶 + 合计 + 请求数;不做美元换算。
3. Q3(修正后):**一个工具,按工作区自动识别当前会话**——探针实证 ZCode 给每个
   会话各起一个 pulse-mcp 进程、cwd = 会话工作区(8 进程 8 目录实测);工具看
   自己进程 cwd → 账本里找该工作区最近活跃的会话。识别不出/同工作区多会话:
   报最近一个并如实列出其余(不猜);完全识别不出 → 只答窗口汇总并说明。

**事实核查档(Explore + 运行时探针,2026-11-23,免重查):**

- pulse-mcp 直读 app 历史库(HistoryDatabase.openReader,PRAGMA query_only,
  ~/Library/Application Support/Pulse/history.sqlite)——**账本三表
  (agent_daily_usage/agent_daily_project_usage/agent_daily_model_usage)
  就在同一个库**,窗口汇总是现成 SQL(SUM 五桶 GROUP BY source WHERE day ≥)。
- ZCode 会话级:~/.zcode/cli/db/db.sqlite `model_usage` 有 `session_id`,
  JOIN session 取 directory/path 即工作区(LiveAgentUsageReader 同款 join,
  加 `WHERE session_id` / `WHERE workspace =` 即可);MCP 侧另有
  mcp-clean 的回环 IPC 可参考但本工具不需要(纯读库)。
- Claude 会话级:~/.claude/projects/<slug>/<sessionId>.jsonl,slug = cwd
  "/"→"-";解析器 ClaudeTranscriptUsageParser 在 PulseCore(按 message.id 去重)。
- ★五桶口径(易错,注释实证):ZCode 源列 input_tokens **已含** cache 两桶、
  output_tokens **已含** reasoning——账本存的是**归一化后的互斥五桶**
  (netInput = input−cacheR−cacheW 饱和减,netOutput = output−reasoning;
  total = 五桶相加);Claude 源天然互斥(reasoning 恒 0)。工具一律报
  **账本口径**(与 app 界面同口径),绝不直接加总源列(加总虚高,tokscale
  五桶非互斥教训)。
- MCP server env 无会话号(配置 env 空),识别只能靠 cwd;
  ZCode 侧已实证,Claude 侧 cwd 行为未实证——按同法实现,识别不出走降级。

**分层与文件:**

- PulseCore 新 `AgentUsageSelfQuery.swift`(纯逻辑,可测):
  ①窗口聚合:账本行(day/source/五桶/request_count)→ 今天 / 7 天两窗
  (合计 + 按来源拆);②会话择取:候选会话(workspace 匹配 + 最近活跃序)
  → 主报 + 其余如实列表;③ZCode 源列→互斥五桶归一化复用既有 parser
  (可见性不够就提升 public,不改逻辑)。单测进 PulseCoreTests(合成行/夹具,
  零真库)。
- PulseMCP `main.swift`(沿用单文件自含风格):注册 `self_usage`(无参数——
  范围固定,不设 knobs);handler = cwd 定位 → ZCode 库查该工作区会话 +
  Claude slug 目录扫活跃文件 → 喂 SelfQuery → 文本拼装(AgentTokenFormat
  复用,进位 556k/6.9M/1.9B 同界面)。
- 工具描述写清口径一句:「当前会话按工作区识别;五桶互斥口径,合计=五桶和」。
- GLOSSARY 补词条「账本 (Ledger)」(域模型:账本/用量词首次成文)。

**测试:** PulseCore SelfQuery 单测(窗口聚合含跨 source/空窗、会话择取
含多会话降级与全不匹配、归一化边界:computed_total 有无两形);PulseMCP
保持无测试 target(纯接线,IO 路径与其他 11 工具同惯例);装机后真调用一次
人工验(新工具重开会话才可见,已知约束)。

**冗余搜查(立票即分诊):** 现有 11 工具零 agent usage 覆盖(grep 实证);
不与 app 界面重复(同一账本两个消费面);`.out-of-scope/` 无同域条目;
无产品拍板残留;分类=新能力(MCP 域);ready-for-agent。

**验收:** 重开 ZCode 会话 → 问 AI「我这个会话花了多少 token」→ AI 调
self_usage 报出:当前会话(sess 短号 + 五桶 + 请求数)、今天、近 7 天,
数字与 app 智能体页消耗子页对得上(同账本同口径)。
