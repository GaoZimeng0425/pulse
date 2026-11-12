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

**Status:** done(2026-11-12,develop@6853d4d;装机目验归用户)

- [x] PulseCore `AgentSessionModel`:模型/解析器(注册表、jsonl 尾读容错半行、
      用量快照、ZCode metadata 未知状态透传)/上下文二档/编排器(≥5s IO 节流 +
      每轮 pid 存活过滤零 IO;ZCode 近 24h 窗 + 12 会话×30 agent 封顶)
- [x] Live `AgentSessionReader`(slug 公式 + 失配回退扫描;jsonl 尾 128KB;
      ZCode 按文件 mtime 近窗)+ `AgentSessionFeature`(心跳薄壳)+ 装配三步
- [x] `MetricTab.agents`(智能体/person.2.fill/.bluetooth)+ 三卡组装 CardFamily
      标准件 + MetricTabStack 迁卡
- [x] 测试:PulseCore 合成夹具 17 例;Live smoke 临时目录 5 例;tab 序/标题/键盘轴
      断言更新;装配防漂移同步
- [x] `sh scripts/check.sh`:核心包 754 全绿;app 侧唯一挂
      `LiveCoreTickSourceSmokeTests`(真机 tick 冒烟,与本改零关联——该测试只直构
      tick/process 源,不经过 SystemMonitor;单跑绿两连,记档合并,高负载自扰老模式)
      ;合并 develop;post-merge hook 已 Release 装机重启

**Out of scope(后续候选):** MCP `list_agent_sessions` 工具、上下文高位告警、
会话历史落库、ZCode token 用量细读(db.sqlite 只读)、会话成本(costUSD)、
Claude `name` 展示、当前任务摘要(last-prompt)。

## Comments

- **口径备忘(2026-11-12)**:上下文 = 末条 assistant 的 `input+cache_read`(首建
  缓存期 `input+cache_creation`,abtop #54 同口径);窗口上限二档——模型带 `[1m]`
  或当前读数 >200k 判 1M,否则 200k(abtop `context_window_for_model` 同款)。
  注册表 status 实测四态 busy/idle/waiting/shell,未知值原样透传。ZCode 活跃 =
  状态非终态(completed/failed/cancelled/error),未知状态按活跃计(近窗内仍在
  更新的更可能是在跑)。
