# 04: 每日消耗按项目分解——项目排行 + worktree 归组

**What to build:** 「每日消耗」卡折线下加**项目排行**节(2026-11-12 用户「继续」
推进,02 票埋好的二期):跟随现有 7/30 天切换,每行「项目名 + 该项目 Claude 与
ZCode 合计 token」,按量降序(CardEntityRow 标准件)。

**口径与设计:**
- **worktree 归组主仓**(纯路径推导零 IO,tokscale `--merge-worktrees` 同思路):
  路径含 `/.worktrees/<slug>` 段 → 项目 = `.worktrees` 前一段路径的 basename
  (`/Users/x/pulse/.worktrees/agent-usage` → `pulse`);含 `/.git/worktrees/`
  段同法;其余 = cwd/workspace 的 basename。正对本仓 `.worktrees/<slug>` 约定
  (agent 进程按路径前缀归组到项目名下,Pulse 排行同收益)。
- **数据源**:Claude = jsonl 文件路径 `projects/<slug>/<sessionId>.jsonl` 的 slug
  反解(io 协议 readClaudeTranscripts 的 consume 恢复带相对路径,03 票之前删过
  又加回);ZCode = model_usage LEFT JOIN session 取 directory/path(workspace),
  02 票刻意省的 join 这次带上。
- **落库**:新表 `agent_daily_project_usage` 主键 (day, source, project),五桶+
  total+requests;**合计表 agent_daily_usage 不动**(卡片合计与项目表两套行同
  扫描产出);stats-cache 回填无项目维度,不进项目表。
- 刷新节奏不变(定时今天/手动全量),全量重扫覆盖 upsert。

**Status:** done(2026-11-13,develop@fae7927;装机目验归用户)

- [x] PulseCore:`AgentWorkspaceResolution`(路径/slug 归组,`.worktrees` 与
      `.git/worktrees` 字面段折前一段)、`AgentProjectUsageRow` + 新表迁移
      `agent-tab-04-project-usage`、聚合器双轨(projectBuckets 与合计轨同喂,
      cache 回填只进合计)、store upsertProjects/projectRows、协议 consume 带
      `<slug>/<sessionId>.jsonl`、ZCodeSample 带 workspacePath
- [x] **Claude 归组口径升级:jsonl 行内 `cwd` 优先**(实测 assistant 行 100% 带,
      含 - 的项目名保真,octok-client 不再截成 client);slug 反解只做老格式
      兜底(含 - 项目名取末词,限制已钉测试)
- [x] Live:ZCode modern 查询 LEFT JOIN session 取 directory/path(列名全限定
      前缀防歧义,legacy 不 join);relativePath 取「父目录名+文件名」拼——
      enumerator 返回 symlink 解析后的绝对拼写(实测 /var→/private/var 且
      resolvingSymlinksInPath 还原不出),绝对前缀匹配不可靠
- [x] UI:每日消耗卡摘要行与热力图之间插项目排行(跟 7/30 切换,CardEntityRow
      folder 图标,封顶 8 行 + 「另 N 项」;无项目数据整节不画)
- [x] 测试:归组三形态/双轨聚合(cwd 优先 + slug 兜底 + workspace 缺失只进
      合计)/store 覆盖写/全量产项目行;**账本测试改相对时钟动态夹具**
      (硬编码日期 + 真实 now = 午夜后必挂,2026-11-13 00:05 实案)
- [x] check:/tmp 复核 **1288 例全绿**(.worktrees 双挂,环境级 flake);合并
      develop、hook 装机重启、推 origin

**Comments(实案教训):**
- 测试用真实 `Date()` 当 now 时,夹具日期必须同源动态生成(硬编码日期 +
  真实时钟的组合跨午夜必挂——23:48 单跑绿、00:05 同码挂的实案)。
- FileManager enumerator 的 URL 是 symlink 解析后的拼写,与
  `URL.appendingPathComponent` 的原拼写不一致;`resolvingSymlinksInPath()`
  也还原不出 enumerator 拼写——相对路径用「父目录名 + 文件名」拼,别做绝对
  前缀匹配。

**Out of scope:** 单项目下钻折线、项目维度单独切换器、cache 回填项目化、MCP 暴露。
