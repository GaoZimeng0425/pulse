# Pulse (Vitals clone) — Agent instructions

## Agent skills

流程技能(mattpocock/skills,版本锁在 `skills-lock.json`)的唯一出处是 `.zcode/skills/`;Claude Code 经 `.claude/skills -> ../.zcode/skills` 软链读同一份,两边流程一致。增删 / 升级技能只动 `.zcode/skills/`,不要在 `.claude/skills` 里另放副本。

### Issue tracker

议题以本地 markdown 文件形式跟踪,位于 `.scratch/<feature-slug>/`。见 `docs/agents/issue-tracker.md`。

### Triage labels

使用默认的五个分类角色标签(needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix)。见 `docs/agents/triage-labels.md`。

### Domain docs

单上下文布局:根目录 `GLOSSARY.md` + `docs/adr/`。见 `docs/agents/domain.md`。

### Visual design

UI 的唯一视觉宪法是根目录 `DESIGN.md`(google-labs-code/design.md 格式:YAML 令牌 + 八章)。**写/改任何 SwiftUI 视图前先读它**;数值不在令牌表里 = 先补表再写码;已拍板样式不得静默回退;已知偏差只许在对应文件改动时顺带收编。

## 代码检索与修改工具策略

按问题选工具,不要裸 grep 硬啃影响面问题,也不要小题大做:

- **符号影响面 / 调用链 / 跨文件追踪**("改 X 什么会碎"、"谁调用它"、A→B 路径、传递爆炸半径)→ 用 **ripwire**(`ripwire-navigate`;合并前的 diff 安全检查用 `ripwire-change-check`;按名字定位符号后先跑一个动词就停)。
- **结构化搜索与机械式批量改写**(按代码结构找模式:某 API 的全部调用点、批量替换字面量/迁移 API、找缺失错误处理的调用)→ 用 **ast-grep**(走 ast-grep 技能把需求翻成 AST 规则;机械重构的子代理必须优先用它而不是正则替换)。
- **简单文本查找**(找已知字符串、快速定位)→ grep 即可。

实施子代理的 prompt 应按其任务带上下述默认:涉及重命名/改签名/迁移类型 → ripwire 查影响面;涉及多点同构修改 → ast-grep。

## 分支

- 集成分支是 `develop`(2026-10-20 起):功能分支 / 集成分支 / 子代理 worktree 一律合回 `develop`,不再合进 `p1-implementation`(已冻结,保留作历史)。`main` 只在用户明确要求时才动。
- 合入前先把 `develop` 的新提交合进来、`xcodegen generate`、跑 `sh scripts/check.sh` 全绿;推送与 `sh scripts/build.sh` 安装先问用户。

## 构建与检查

- Xcode 工程由 `project.yml` 生成:加/移文件后先 `xcodegen generate`,绝不手改 `project.pbxproj`。
- 纯逻辑层在本地 Swift 包 `Packages/PulseCore`(只依赖 Foundation / GRDB,不碰 AppKit / SwiftUI / Darwin 采集调用);Live 适配器、`@Observable` 功能模块与 SwiftUI 在 app target。新纯逻辑写进包里,新测试跟着被测代码走:核心测试放 `Packages/PulseCore/Tests/PulseCoreTests`(`swift test` 不起宿主),Live 冒烟 / SwiftUI / 功能模块薄壳测试放 `PulseTests`。
- 提交闸门 `.githooks/pre-commit`(staged 含 .swift 即增量构建,核心包有改动再编一遍包测试,失败拦截;改钩子后重跑 `sh .githooks/install.sh`)。全量检查 `sh scripts/check.sh`;只跑测试 `sh scripts/test.sh [--only 套件]`(核心包与 app 两套;套件在核心包就走 `swift test`);Release 安装到 /Applications 并换新拉起 `sh scripts/build.sh`。
