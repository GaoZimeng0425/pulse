# 01: 智能体 tab——AI 助手会话监视 + dev server 迁入

**What to build:** 新增「智能体」tab(容器与电池之间,弹窗与主窗口同轴),参考
abtop(github.com/graykode/abtop,MIT)监视线程编码 AI 助手:范围拍板
**Claude Code + ZCode**(2026-11-12;opencode/codex/gemini 本机零/纯历史数据,不做)。
卡序:Claude 用量限额(5 小时窗/本周,meter 读数行)→ Claude Code 会话(实体行:
项目/pid·时长·状态/上下文占用%/子代理数)→ ZCode 会话(实体行:工作区/更新时间/
活跃子代理占比/token 合计)→ 开发服务(dev server 卡**从总览整卡迁入**,总览回归
纯系统指标;停止流 KillRequestFlow 不动)。

**背景:** 用户看到 abtop 后要这个能力。本机摸底(2026-11-12):Claude 注册表
`~/.claude/sessions/<pid>.json`(自带 status:busy/idle/waiting/shell 与 name)、
上下文 = 会话 jsonl 末条 assistant 的 `input+cache_read`(首建缓存期
`input+cache_creation`,abtop #54 同口径)、窗口二档 200k/1M(`[1m]` 或当前
>200k 判 1M)、限额 `~/.claude/usage-snapshot.json`;ZCode 每子代理
`~/.zcode/cli/agents/sess_*/agent_*/metadata.json` 自带 status/totalTokens,
**不碰 2.9GB db.sqlite**。全本地文件读,零 TCC 权限。tab 强调色复用蓝牙青
(DESIGN.md junk-ai 先例,AI 身份色);阈值变色不开第四处(强调级映射集中三处
的既有规矩),meter/数值一律页色。

**Status:** in-progress(2026-11-12)

- [ ] PulseCore `AgentSessionModel`:模型/解析器(注册表、jsonl 尾读容错半行、
      用量快照、ZCode metadata 未知状态透传)/上下文二档/编排器(≥5s IO 节流 +
      每轮 pid 存活过滤零 IO;ZCode 近 24h 窗 + 12 会话×30 agent 封顶)
- [ ] Live `AgentSessionReader`(slug 公式 + 失配回退扫描;jsonl 尾 128KB;
      ZCode 按文件 mtime 近窗)+ `AgentSessionFeature`(心跳薄壳)+ 装配三步
- [ ] `MetricTab.agents`(智能体/person.2.fill/.bluetooth)+ 三卡组装 CardFamily
      标准件 + MetricTabStack 迁卡
- [x] 测试:PulseCore 合成夹具 16 例;Live smoke 临时目录 5 例;装配防漂移同步
- [ ] `sh scripts/check.sh` 全绿;合并 develop;装机目验(8 个 claude 实例对得上)

**Out of scope(后续候选):** MCP `list_agent_sessions` 工具、上下文高位告警、
会话历史落库、ZCode token 用量细读(db.sqlite 只读)、会话成本(costUSD)、
Claude `name` 展示、当前任务摘要(last-prompt)。

## Comments
