# 08: 规矩与回指收口

**What to build:** AGENTS.md 的界面规矩改成新写法;DESIGN.md「该做不该做」同步;
代码注释里指向旧 DESIGN.md 条目的回指全部改到新条目或去掉;决策记录定稿。

**Blocked by:** 07(回指要指向新条目的名字)。

**Status:** ready-for-agent

## Agent Brief

**Category:** enhancement

**Summary:** 流程规矩、设计文档与代码注释三者对齐到新分工。

**Current behavior:**

AGENTS.md 写的是「已拍板样式不得静默回退;已知偏差只许在改动对应文件时顺带
收编」。约 20 个代码文件的注释里提到 DESIGN.md,其中一部分指着将被搬走或改名的
条目(如「见 §Components 传感器卡」)。决策记录 ADR-0011 已有草稿。

**Desired behavior:**

- AGENTS.md 的界面规矩改为:写或改任何 SwiftUI 视图前先读根目录 DESIGN.md
  (原则与组件规范)和所在页主视图文件开头的页面规格;数值不在令牌表里先补表再
  写码;DESIGN.md 只收原则和组件规范,某一页怎么实现写在该页代码旁的注释里,不进
  DESIGN.md;规范与页面规格里已定的样式不得静默改,要改先问用户。
- DESIGN.md「该做不该做」同步(票 07 已改的核对一致)。
- 全仓代码注释里的 DESIGN.md 回指逐条处理:指向通用件或令牌的,改到新条目的
  名字;指向页面规格的,改为指向所在文件的页面说明或去掉。
- 决策记录 ADR-0011 定稿:文字与最终实现一致。

**Key interfaces:**

- CODING_STANDARDS.md 里对 DESIGN.md 的提法(「UI 视觉宪法在 DESIGN.md」)仍成立,
  必要时微调措辞。

**Acceptance criteria:**

- [ ] AGENTS.md 那句与规格一致
- [ ] 全仓代码注释里不再有指向不存在条目的 DESIGN.md 回指(逐条核过)
- [ ] ADR-0011 文字与最终实现一致
- [ ] 全量检查通过

**Out of scope:**

- 其它流程规矩
- 页面注释的内容(票 04–06 已定)

## Comments

- 2026-11-23 立票即分诊:冗余搜查无同题票;`.out-of-scope/` 知识库为空;分类
  enhancement;Agent Brief 已附。
