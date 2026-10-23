# 01: 判断类编码规则的落点——引入 CODING_STANDARDS.md 与否(拍板票)

**What to build:** retro 体系(Matt skills)里判断类编码规则的原教旨去处是 `CODING_STANDARDS.md`——由 `/code-review` 的 Standards 轴在**审查时**执行;本仓库现状是全部 steering 收在 AGENTS.md(实施时注入)。需要拍板仓库的规则落点分工。

已验证的事实(2026-10-23):
- `/code-review` SKILL.md:36:"When CODING_STANDARDS.md or CONTRIBUTING.md exists, it must be on the list"——**自动发现,创建即生效,零接线**;且 repo 标准覆盖其内置 smell 基线。
- `writing-for-agents`(retro 的写作规范)要求 AGENTS.md "used incredibly sparingly"——规则堆积与此原则相悖。
- 仓库无 CODING_STANDARDS.md / CONTRIBUTING.md。

**选项**:
- **A 维持现状**:AGENTS.md 单一出口。优点:实施 agent 写码当下就看到(错在编辑时发生,防患最早);缺点:文件随规则增长变胖,审查时不重读、执行靠自觉。
- **B 引入 CODING_STANDARDS.md**:判断题规则迁入,AGENTS.md 只留流程/工具路由/导航; Standards 轴审查时机械执行。优点:规则在审查点被执行而非被信任、AGENTS.md 保持瘦;缺点:实施当下不可见——错误要到 review 才被抓,晚一拍。

**倾向(供拍板参考)**:B——与本仓库既有分层契合(SwiftLint/SwiftFormat 管机械、测试管行为、CODING_STANDARDS 管判断、AGENTS.md 管导航);但**不是所有 AGENTS.md 现有条目都该迁**:批量替换锚点这类"编辑工具用法"发生在实施时,留在 AGENTS.md 更早拦截;"代码长相"类判断才迁。迁移清单随拍板一并定。

**Blocked by:** 用户拍板(A/B + 迁移清单)

**Status:** needs-triage

- [ ] 拍板记录在案(A 维持 / B 引入 + 迁移清单)
- [ ] 若 B:文件建立 + AGENTS.md 对应瘦身 + 一次 `/code-review` 冒烟验证 Standards 轴读到它
- [ ] check.sh 全绿
