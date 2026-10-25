# 01 — 宿主 App(Zap / ZCode)吞掉项目进程,排行看不出哪个项目占用多

**Status:** needs-triage

## 背景(用户 2026-10-23 目验反馈原话)

"我觉得根项目应该优先, 现在老是看不出来是哪个项目占用多, 都在 zap 应用进程里"

## 诊断(2026-10-23 实测,证据都在本机)

引擎判定顺序(`GroupingEngine.swift:159-176`)**已经是项目优先**:
1 App 归属(.app 容器,含容器助手)→ 2 项目归因(cwd 优先、argv 路径次之,
前缀匹配配置根,`:484`)→ 3 父链上溯 → 4 兜底三分类。验收锚点本来就是
"rustc ← cargo ← node ← Zcode 归项目 @ worktree,不归 Zcode"。

所以不是优先级反了,是**项目归因 miss 后顺父链缩进宿主组**。实测样本:

| 进程 | cwd | 归组结果 |
|---|---|---|
| zcode-node-repl-mcp(29029) | /…/Learn/macos/NemoNotch(命中根)| 项目组 ✓ |
| zcode-cli(33305/33482) | ~/.zcode/workspace/draft-…(根外)| ZCode 组 ✗ |
| zcode-cli(49316) | /…/Learn/macos(**七个根的父目录**)| ZCode 组 ✗ |
| zcode-host-local-1(49034) | / | ZCode 组 ✗ |
| zap-oss 子进程(14652) | /Users/aa00930 | Zap 组 ✗ |

当前配置根 7 个:octok-platform、voiceos、pulse、DynamicIsland、NemoLoop、
NemoNoise、NemoNotch。miss 的三类 cwd:agent 会话 draft 目录(~/.zcode/workspace)、
项目父目录(Learn/macos)、home / 根目录。argv 实测只含 argv[0],无项目路径,
argv 次级匹配对 zap/zcode CLI 无效。/tmp worktree(并行会话惯例)是另一类 miss。

## 候选方向(待 grill)

- **A. 配置面**:把 ~/.zcode/workspace、Learn/macos 加进根——父目录当根会把
  pulse/voiceos/Nemo* 全并成一团(project 名 = 根末段,粗根吞子项目),劣化,基本可排。
- **B. 宿主下钻标注**:归因不动,展开宿主 App 组时给每个子进程标 cwd 命中的
  项目名(有根命中就标)。"谁占的多"答案在下钻里,排行仍是宿主视角。
- **C. 会话元数据映射**:读 Zap/ZCode 会话文件(draft 目录里有项目指针)把
  draft 目录映射回真项目,归因即可命中——宿主特定、格式无契约,脆。
- **D. 手动钉规则**:按 executable/argv 模式把某类进程钉到项目,持久化;
  通用但要 UI + 规则存储,成本最高。
- **E. 父目录自动提议**:Pulse 检测到"某根的父目录频繁出现在 miss 的 cwd 里"
  时提醒用户加根/提示粗根后果——不动引擎,只治"不知道要配"。

## 拍板点

1. 用户要的「哪个项目占用多」= 项目组排行(改归因)还是宿主下钻标注(不改归因)?
2. draft/workspace 目录映射走哪条(C 会话文件 / D 手动钉 / B 绕开映射)?
3. /tmp worktree 要不要可见(现惯例根外)?

## 验收锚点(方向定后细化)

- 同时开两个项目的 agent 会话,排行/下钻能分清两个项目各自的占用;
- 无 agent 在跑时,ZCode / Zap 组回归只含宿主自身进程;
- 命中根的进程行为不回退(repl-mcp 样本仍归项目组)。

## Comments

### 勘误(2026-10-25,主会话;02 号票据此拆出)

诊断一节"引擎判定顺序**已经是项目优先**"系误读,当日代码与今逐位一致
(2026-10-22 后 GroupingEngine.swift 零提交)。项目归因层只先于**父链上溯**,
不先于**自身 App 归属**——`layerSelf` 实序:① bundle 谓词命中即返回,② 才轮到
cwd/argv 项目匹配。本票实测样本恰好没踩中受害区(采的都是非 bundle 进程或
cwd miss 进程):**可执行在 `.app` 容器内 ∧ cwd 命中项目根**的进程(如 ZCode
Helper、Xcode 工具链 swift-frontend/clang)现行一律归 App,项目组看不到。
2026-10-25 用户以同一痛点再次立题,该半边已拆为 **02 号票**(判定顺序对调),
本票剩余范围 = cwd 没命中根的三类 miss(draft 目录 / 项目父目录 / `/` 与 home,
及 /tmp worktree)与其 A–E 候选。triage 请两票同看:02 若落地,本票候选 B
(宿主下钻标注)的动机面会缩小,候选 C/D 的对象也只剩 miss 类进程。
