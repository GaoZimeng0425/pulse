# Pulse — Agent instructions

## 流程约定

- 流程技能唯一出处 `.zcode/skills/`(`.claude/skills` 是指向它的软链)。增删 / 升级技能只动 `.zcode/skills/`,不要在 `.claude/skills` 里另放副本。
- 议题 = `.scratch/<feature-slug>/` 下的本地 markdown(细则见 `docs/agents/issue-tracker.md`);triage 标签固定五个:needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix(`docs/agents/triage-labels.md`);领域文档 = 根目录 `GLOSSARY.md` + `docs/adr/`(`docs/agents/domain.md`)。
- 写 / 改任何 SwiftUI 视图前先读根目录 `DESIGN.md`:数值不在令牌表里 = 先补表再写码;已拍板样式不得静默回退;已知偏差只许在改动对应文件时顺带收编。

## 对用户的汇报与交互(NemoNotch 同款,2026-10-25 用户立规)

- **摊选项先给背景**:给用户摆选择题时,第一段写背景——改之前用户看到 __ / 改之后用户看到 __;摊方案时再补——做错了用户会看到 __ / 我拿不准的是 __。**每个选项都要给优缺点**,不是只给推荐项的理由。背景先于任何设计、字段、实现细节。
- **主语是"用户身上发生什么"**,不用模块名 / 类名 / 文件名当主语;**一次只问一个要拍板的问题**。
- **提问分类器**:要问用户前先自问——答案是否"跑一下就能观察到"(行为 / 耗时 / 布局 / 输出)?能 → 做探针让结果说话,不问;只有真正的产品 / 偏好 / 单向门取舍留给人。
- **落地验证指引**:完工给一句「起 app 点哪里能看到它」;纯后台改动写怎么触发、在哪看出来。

## 代码工具选择

- 判断类代码标准(防御纪律/并发/权限 TCC/测试/注释)见根目录 `CODING_STANDARDS.md`——`/code-review` Standards 轴强制执行;机械项归 lint/测试,不两处重复。
- 影响面 / 调用链 / 改名迁移类问题 → ripwire;合并前的 diff 安全检查用 `ripwire-change-check`。
- 结构化查找与机械批量改写 → ast-grep(走技能写 AST 规则;机械重构的子代理必须用它,不准正则替换)。
- 找已知字符串 → grep 即可。
- 脚本/python 批量改文件:每处替换先 assert 锚点再替换——pattern 与格式化后的实际代码失配会**静默跳过**(2026-10 真案:registry 漏登让容器功能上线即死一天,测试/编译/lint 全绿);零散几处改用 Edit 工具,失配会大声失败。
- 给实施子代理的 prompt 带上对应默认:改名 / 改签名 / 迁移类型 → 先 ripwire 查影响面;多点同构修改 → ast-grep。

## 分支

- 一律合回 `develop`;`p1-implementation` 已冻结别再合,`main` 只在用户明确要求时才动。
- 并行会话共享本 checkout:实施走独立 worktree(`git worktree add /tmp/<slug> -b feat/<slug> develop`),合并在 worktree 里做,绝不动共享 HEAD;只读看别的分支开 `--detach` worktree。
- 合入前:合进 `develop` 新提交 → `xcodegen generate` → `sh scripts/check.sh` 全绿;推送直接推 origin 不再询问(2026-10-22 用户撤销"推送先问";main 仍只在明确要求时动)。merge 真正落到 `develop` 后,post-merge hook 自动 `sh scripts/build.sh` Release 安装(应急 `PULSE_SKIP_BUILD=1` 跳过,`PULSE_HOOK_DEBUG=1` 干跑)。
- 分支保护由 hook 机械化(pre-merge-commit):`main` / `master` 禁止 merge 提交,`p1-implementation` 已冻结禁合;develop 合并来源白名单待分支命名收敛后再补。

## 构建与测试

- 工程由 `project.yml` 生成:加 / 移文件后先 `xcodegen generate`,绝不手改 `project.pbxproj`。
- 纯逻辑写进 `Packages/PulseCore`(只依赖 Foundation / GRDB,不碰 AppKit / SwiftUI / Darwin 采集调用);Live 适配器、`@Observable` 功能模块与 SwiftUI 留在 app target。测试跟着被测代码走:核心测试放包里(`swift test` 不起宿主),Live / SwiftUI 薄壳测试放 `PulseTests`。
- 全量检查 `sh scripts/check.sh`(lint → 构建 → 测试);只跑测试 `sh scripts/test.sh [--only 套件]`;Release 安装 `sh scripts/build.sh`。
- Swift lint 门禁:`sh scripts/lint.sh [--staged] [--fix]`(SwiftFormat `.swiftformat` 管美化,SwiftLint `.swiftlint.yml` 管 error 级检测);pre-commit 对 staged 自动修,工具缺失即拦截。改 `.githooks/` 下任何 hook 后重跑 `sh .githooks/install.sh`(副本自检会兜底)。
- **本地部署自签(fail-closed)**:`build.sh` 用自签身份 `Pulse Local Code Signing`(`scripts/make-signing-cert.sh` 创建,登录钥匙串)——ad-hoc 每次重建换 cdhash,TCC/Keychain 授权全丢 = 每次重装被当陌生 app 重弹权限框(2026-10-24 蓝牙票实案;权限原则见 `CODING_STANDARDS.md`)。pre-flight 用 **codesign 签探针文件**验证身份,缺失响亮失败、**绝不静默回落 ad-hoc**;逃生 `PULSE_SIGNING_IDENTITY=-`。**存在性检查不要用 `security find-identity -p codesigning`**——该过滤器隐藏无信任设置的自签证书(实测致重复导入 + codesign 二义)。Debug / 测试构建保持 ad-hoc(本地部署才需要稳定身份)。身份名改动静要脚本、本手册、证书三处一起换。
