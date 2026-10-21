# Pulse — Agent instructions

## 流程约定

- 流程技能唯一出处 `.zcode/skills/`(`.claude/skills` 是指向它的软链)。增删 / 升级技能只动 `.zcode/skills/`,不要在 `.claude/skills` 里另放副本。
- 议题 = `.scratch/<feature-slug>/` 下的本地 markdown(细则见 `docs/agents/issue-tracker.md`);triage 标签固定五个:needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix(`docs/agents/triage-labels.md`);领域文档 = 根目录 `GLOSSARY.md` + `docs/adr/`(`docs/agents/domain.md`)。
- 写 / 改任何 SwiftUI 视图前先读根目录 `DESIGN.md`:数值不在令牌表里 = 先补表再写码;已拍板样式不得静默回退;已知偏差只许在改动对应文件时顺带收编。

## 代码工具选择

- 影响面 / 调用链 / 改名迁移类问题 → ripwire;合并前的 diff 安全检查用 `ripwire-change-check`。
- 结构化查找与机械批量改写 → ast-grep(走技能写 AST 规则;机械重构的子代理必须用它,不准正则替换)。
- 找已知字符串 → grep 即可。
- 给实施子代理的 prompt 带上对应默认:改名 / 改签名 / 迁移类型 → 先 ripwire 查影响面;多点同构修改 → ast-grep。

## 分支

- 一律合回 `develop`;`p1-implementation` 已冻结别再合,`main` 只在用户明确要求时才动。
- 合入前:合进 `develop` 新提交 → `xcodegen generate` → `sh scripts/check.sh` 全绿;推送先问用户。merge 真正落到 `develop` 后,post-merge hook 自动 `sh scripts/build.sh` Release 安装(应急 `PULSE_SKIP_BUILD=1` 跳过,`PULSE_HOOK_DEBUG=1` 干跑)。
- 分支保护由 hook 机械化(pre-merge-commit):`main` / `master` 禁止 merge 提交,`p1-implementation` 已冻结禁合;develop 合并来源白名单待分支命名收敛后再补。

## 构建与测试

- 工程由 `project.yml` 生成:加 / 移文件后先 `xcodegen generate`,绝不手改 `project.pbxproj`。
- 纯逻辑写进 `Packages/PulseCore`(只依赖 Foundation / GRDB,不碰 AppKit / SwiftUI / Darwin 采集调用);Live 适配器、`@Observable` 功能模块与 SwiftUI 留在 app target。测试跟着被测代码走:核心测试放包里(`swift test` 不起宿主),Live / SwiftUI 薄壳测试放 `PulseTests`。
- 全量检查 `sh scripts/check.sh`(lint → 构建 → 测试);只跑测试 `sh scripts/test.sh [--only 套件]`;Release 安装 `sh scripts/build.sh`。
- Swift lint 门禁:`sh scripts/lint.sh [--staged] [--fix]`(SwiftFormat `.swiftformat` 管美化,SwiftLint `.swiftlint.yml` 管 error 级检测);pre-commit 对 staged 自动修,工具缺失即拦截。改 `.githooks/` 下任何 hook 后重跑 `sh .githooks/install.sh`(副本自检会兜底)。
