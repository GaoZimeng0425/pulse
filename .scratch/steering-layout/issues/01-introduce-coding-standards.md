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

**Status:** done

- [x] 拍板:**B**(用户 2026-10-23 "那应该创建这个文件啊")
- [x] 文件建立:CODING_STANDARDS.md v1(防御数据/并发/测试/注释四节,判断类;机械项不重复)
- [x] AGENTS.md 接入:代码工具选择节加指针一行;**完整迁移挂起**——现有 AGENTS.md
      条目多为实施时路由(分层/工具),留在原处更早拦截,等规则集长大再谈瘦身(避免 churn)
- [x] Standards 轴收录:发现机制是 code-review SKILL.md 硬编码("exists must be on
      the list"),文件存在即必然进清单;行为验证随下次自然 review 骑行确认

## Comments

**执行记录(2026-10-23)**:拍板后同日落地。v1 内容来源 = 2026-10 审计批次沉淀的
判断题(差分三防御/NSLock 拆同步/多档串行/假流 finish/登记面结构断言/直调源不背书
装配),此前散在代码注释、票面与 agent 私有记忆,现在有了仓库内单一出处。
