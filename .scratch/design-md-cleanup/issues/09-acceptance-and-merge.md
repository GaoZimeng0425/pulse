# 09: 总验收与合入

**What to build:** 汇总核对、分开提交、全量检查、合入 develop 并装机,交用户目验,
九张票收档。

**Blocked by:** 08。

**Status:** ready-for-agent

## Agent Brief

**Category:** enhancement

**Summary:** 核对去向、理清提交、全量检查、合入装机、收档。

**Current behavior:**

票 01–08 完成后,改动分布在十几个视图文件、lint 配置、DESIGN.md、AGENTS.md 与
决策记录里。

**Desired behavior:**

- 三张去向表(票 04–06)逐张核过:没有去向不明的规矩;标「归组件规范」的规矩
  在 DESIGN.md 里都有落点。
- 提交历史能分清:代码行为改动(票 01–03)、注释与文档(票 04–08)各自成提交。
- 全量检查(lint → 构建 → 测试)全绿;高负载导致的已知自扰单跑绿可记档。
- 合入 develop、装机、推送;九张票 Status 收档。

**Acceptance criteria:**

- [ ] 三张去向表逐张核过,无「去向不明」
- [ ] 提交历史分得清行为改动与注释 / 文档改动
- [ ] 全量检查全绿(自扰例单跑绿并记档)
- [ ] 已合入 develop、装机、推送;九张票 Status 收档
- [ ] 用户目验通过:进程下钻与清理设置页文字、菜单栏告警色、图标大小、设置窗
      图标外观、清完的 DESIGN.md

**Out of scope:**

- 新发现的界面问题(列给用户,不在本批顺手改)

## Comments

- 2026-11-23 立票即分诊:冗余搜查无同题票;`.out-of-scope/` 知识库为空;分类
  enhancement;Agent Brief 已附。
