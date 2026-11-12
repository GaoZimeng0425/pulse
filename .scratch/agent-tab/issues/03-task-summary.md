# 03: 会话当前任务摘要 + 会话名展示

**What to build:** 智能体页 Claude Code 会话卡两处小改(2026-11-12 用户点单):
1. 会话行**副文优先显示当前任务摘要** = 该会话 jsonl 末条**有效用户指令**截断
   (120 字符,换行折空格)——「正在干什么」扫一眼可知;无摘要退回现状
   (pid · 时长 · 状态);
2. 会话行**名字优先显示会话自定义名**(注册表 `name` 字段,如
   "octok-client-bf"),缺省维持项目名。

**口径(2026-11-12 实测):**
- jsonl user 行两种形态:`content` 字符串 = 真输入;数组 = 常见 tool_result
  (工具回传,**排除**),取其中 `type=="text"` 块拼接。
- 噪音过滤(注入行不是用户指令):`<` 开头(slash 命令/回显/system-reminder)、
  "This session is being continued"(resume 摘要)、"Caveat:";`isSidechain==true`
  的行排除(子代理链,主会话行要主链任务)。
- **零新增 IO**:数据全部来自已在尾读的 128KB 窗口与注册表 json;纯本地文本
  截断,不调模型(abtop 的 `claude --print` 方案不用)。
- v1 票 Out of scope 的「Claude name 展示」「last-prompt 任务摘要」两项就此清掉。

**Status:** done(2026-11-12,develop@c8e2ffb;装机目验归用户)

- [x] PulseCore:`ClaudeTranscriptTail.parse` 返回组合读数 `ClaudeTranscriptReading`
      (context + lastUserPrompt,一次倒序遍历双目标、各自命中即冻结);userPromptText
      (str / text 块拼接,tool_result-only 排除)+ sanitize(`<` 注入 / resume 摘要 /
      Caveat / 空白全滤,换行折空格、截 120);`ClaudeAgentSessionStatus` 加
      `name`/`taskSummary`(尾参默认 nil,旧调用不破);缓存与编排接线
- [x] UI:ClaudeSessionsCardView 行名 = name ?? 项目名,副文 = 摘要 ?? pid·时长·状态
- [x] 测试:内核 19 例全绿(新增末条有效指令选取 / 无 assistant 单独成立 /
      截断与全噪音);Live smoke 字段路径同步
- [x] check:/tmp 复核 **1284 例全绿**(.worktrees 又双挂,环境级 flake,同码
      /tmp 全绿);合并 develop、hook 装机重启、推 origin

**Out of scope:** ZCode 会话任务摘要(metadata 无对应字段)、摘要调模型精炼
(tokscale Apple FM 方案候选)、Git 状态、杀会话。
