# 01: 父卡勾选框独立点击区(点框不再触收展)

**What to build:** 用户实报(2026-11-09 截图 + 三条 bug 之一):「可清理」页项目产物/卸载残留大卡的父级勾选框,点击后触发的是**展开/收起**,不是勾选。

1. 根因:`projectCard` 头排整行挂 `.onTapGesture(onToggleCollapse)`(`CleanerJunkViews.swift` ~477),勾选框 Button(~440)在同一行内被整行手势劫持——容器手势先于 plain Button 吃掉了点击。
2. 修复:头排拆两个响应区——勾选框(含既有 Button 动作与置灰逻辑)独立一块;标题/元信息/箭头整块 = 收展点击区。勾选动作语义**不变**(仍是只勾「可安全清理」且非在用子项,2026-11-06 两层口径拍板;用户 2026-11-09 确认 bug 2 不改)。
3. 验证:夹具不可行(手势优先级是 AppKit 运行时行为),走目验——点框 = 勾选(安全档子项亮、父框如实全选/半选);点标题/箭头 = 收展。

**Status:** done(2026-11-09,分支 fix/cleaner-junk-card-fixes)

## Comments

**2026-11-09 实施记录:**

- 头排结构:勾选框 Button 保持原位原语义;标题+元信息+箭头包进内层 HStack,`contentShape(.rect)` + `onTapGesture(perform: onToggleCollapse)` 只挂内层,收展 help 提示随迁。外层不再有整行手势。
- 不依赖手势优先级规则(内层手势 vs 祖先手势谁赢的口径随 OS 版本漂过),直接物理分离两块命中区,是最稳的修法。
- bug 2(父级点击应全勾所有子项含「先检查」)用户拍板**不改**:两层口径维持 11-06 定案,组头「全选安全项」文字按钮口径也不动。
- 全量 check 首跑(2026-11-09):lint/构建绿,Pulse 宿主测试挂「runner hung before establishing connection」——11-08 已记录的 Documents 下 worktree 间歇挂死,非本次改动所致;按既定退路提交后转 /tmp detach worktree 重跑。
- /tmp 重跑全量绿:1156/1156(核心 689 + app 467)。目验清单在合并报告里交用户。
