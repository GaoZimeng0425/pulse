# 09: 会话卡标明所属项目(项目名 + worktree + 路径)

**What to build:** 用户 2026-11-14 实报「会话看不出来是哪个项目,有没有更多信息可以
加」。根因:Claude 会话标题 = 注册表会话名 ?? cwd 末段,ZCode = 工作区 basename——
worktree 里的会话末段是分支 slug(agent-tab-08),自定义会话名也不含项目。

**改动:**
- PulseCore `AgentSessionLocation.resolve(path:home:)`(+6 单测):工作目录 → 项目名
  (worktree 折回主仓,复用账本 `AgentWorkspaceResolution` 规则)+ worktree 名 +
  `~` 缩写路径。纯路径推导零 IO。
- 会话块:标题恒为项目名;worktree 挂「⑂ slug」标签;新增路径行;Claude 自定义
  会话名挪进元信息「会话「名」」(与项目/worktree 同名不写)。

**未做(可选后续):** git 分支名(需读 `.git/HEAD`,新增 Live IO);主 checkout
上的会话现只显项目名 + 路径,看不到在哪个分支。

**验收:** 智能体 → 会话:worktree 里跑的会话标题是主项目名 + ⑂ worktree 标签,
下方有 `~/…` 路径。

## Comments

- 2026-11-14 check:核心包 817 绿;app 宿主测试两次挂起,sample 见测试宿主主线程卡 dyld `open()`(Documents 病症状),按手册退回 /tmp worktree 跑宿主测试。
