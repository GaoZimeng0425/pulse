# 08: 会话子页重设计 + 子 tab 玻璃外裹 + 清理搜索框对齐 + 五格两端对齐 + token B 档

**What to build:** 用户 2026-11-14 实报五条:①智能体子 tab 与清理页子 tab 不一样;
②清理「应用」子页搜索框高度与右侧「占用|名称」不齐;③项目卡「Cache×」不靠右;
④会话子页不好看,「23%」「6/10 6.9M」看不懂;⑤token ≥1000M 用 B。

**根因 / 改动:**

1. `AgentSubTabBar` 漏传 `isGlassContainer: true`(清理页子页条有玻璃外裹)→ 补上。
2. 系统 roundedBorder 输入框 NSHostingView 离屏实测画 26pt(边框画框外)vs 分段
   控件 24pt;内嵌放大镜被原生框底盖住不可见 → 新 `CleanerSearchField`(主窗口
   工具栏搜索框同配方,定高 24、圆角 7)。
3. 五格改两端对齐等间距(首贴左、末贴右,Spacer 均分)。
4. 会话卡拆出 `AgentSessionViews.swift`,每会话一块 lift 小块 + 右侧带标签读数块:
   「上下文 23%」+ meter +「230k / 1M」;「子代理在跑 6 / 10」+ meter +「累计 6.9M
   tokens」;状态 chip(忙/空闲、在跑/空闲)、卡头计数带单位。
5. token 格式收进 PulseCore `AgentTokenFormat`(+6 单测),≥1000M 进 B,
   999.96M 四舍五入不出「1000.0M」直接升 B。

**偏离既往拍板(汇报已说明):** 清理搜索框 11-08「换系统原生输入框、不再手绘
灰底盒」→ 回到自绘(原生框高度对不齐且放大镜被盖住);配方取既有工具栏搜索框。

**验收:** 智能体页看子 tab 有玻璃底、与清理页同形;清理 → 应用 搜索框与「占用|
名称」上下齐平、放大镜可见;消耗 → 项目卡五格首尾贴边;会话子页新版式;
数字卡 / 热力墙页脚等 ≥10 亿处显示 B。

## Comments

- 2026-11-14 NSHostingView 离屏渲染(能画 AppKit 控件,ImageRenderer 不行)自查
  搜索框齐平与会话卡版式;玻璃外裹离屏不渲染,待实机。
- 2026-11-14 check 首轮 SpaceScanEngineTests.testParallelScanProducesIdenticalTreeAndStatsAsSerial 挂一次(并行/串行账目不一致,load ~14);diff 不碰扫描引擎,单跑 5 连绿、全量重跑 1320 绿,判偶发竞态放行,另开票跟。
