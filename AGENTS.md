# Pulse (Vitals clone) — Agent instructions

## Agent skills

### Issue tracker

议题以本地 markdown 文件形式跟踪,位于 `.scratch/<feature-slug>/`。见 `docs/agents/issue-tracker.md`。

### Triage labels

使用默认的五个分类角色标签(needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix)。见 `docs/agents/triage-labels.md`。

### Domain docs

单上下文布局:根目录 `GLOSSARY.md` + `docs/adr/`。见 `docs/agents/domain.md`。

## 代码检索与修改工具策略

按问题选工具,不要裸 grep 硬啃影响面问题,也不要小题大做:

- **符号影响面 / 调用链 / 跨文件追踪**("改 X 什么会碎"、"谁调用它"、A→B 路径、传递爆炸半径)→ 用 **ripwire**(`ripwire-navigate`;合并前的 diff 安全检查用 `ripwire-change-check`;按名字定位符号后先跑一个动词就停)。
- **结构化搜索与机械式批量改写**(按代码结构找模式:某 API 的全部调用点、批量替换字面量/迁移 API、找缺失错误处理的调用)→ 用 **ast-grep**(走 ast-grep 技能把需求翻成 AST 规则;机械重构的子代理必须优先用它而不是正则替换)。
- **简单文本查找**(找已知字符串、快速定位)→ grep 即可。

实施子代理的 prompt 应按其任务带上下述默认:涉及重命名/改签名/迁移类型 → ripwire 查影响面;涉及多点同构修改 → ast-grep。
