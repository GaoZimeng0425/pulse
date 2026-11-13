# 06: 智能体页三子 tab + 消耗子页重排(定稿骨架)

**What to build:** 智能体页分三个子 tab「消耗 | 会话 | 开发服务」(清理页五子药丸同款
模式,PillTabBar 标准件),每日消耗拆壳平级成卡;消耗子页按定稿骨架
`.scratch/agent-tab/wireframe-agents-page.html` 重排;项目卡对齐 tokscale 参数。
**骨架即视觉真相(纯线稿约定,样式实施时走 DESIGN.md 令牌)。**

**用户拍板决策(2026-11-13,骨架四轮迭代定稿,不得偏离):**

1. **三子 tab**:「消耗 | 会话 | 开发服务」,默认落「消耗」;子页切换不丢状态。
2. **消耗子页顺序**:数字卡排(四张一排:今日 / N 天合计 / 日均 / **Claude 用量**
   ——用量并入做第 4 张同规格小卡,副行放窗口重置)→ **日历图 + 走势一排两列**
   (媒体查询:容器不够宽上下排一列)→ 项目宽卡(媒体查询列数)。
   「重新扫描」在日历图卡头(与「年」占位药丸并排)。
3. **Claude 用量卡撤**:独立用量卡消失(并入数字卡排);会话子页只两张会话卡;
   开发服务子页只 dev server 卡(节标题撤——子药丸已是身份)。
4. **项目卡加宽 + 对齐 tokscale 参数**:四桶行(Input / Output / Cache R / Cache W /
   Cache× 缓存倍率——账本五桶现成,倍率=缓存读÷净输入输出派生)+ 活跃行加
   **会话数**;Cost 美元、精确 Last Active **不做**(用户点名排除)。
5. **总览网格上限 4 列 → 3 列**(用户点名;DESIGN.md 同步改)。
6. 顺带收模块间 UI 不一致:子页内各卡统一 CardHeader(青色卡头)+ cardShell 内距。

**数据侧:**
- 会话数(不落库,全量档/引导时现数):Claude = projects/<slug>/ 下 jsonl 文件数
  (slug→项目,只列文件名零读内容;30 天滚动删,口径=**现存**会话);ZCode =
  db 一条 `COUNT(DISTINCT session_id) GROUP BY workspace`(全历史,被 purge 的
  数不到)。AgentUsageReading 协议加 `sessionCounts()`,feature 持有发布。
- 四桶 / 倍率:AgentUsageWindow.projects 扩展输出(AgentProjectUsageRow 五桶
  现成,聚合时未用——补窗口聚合)。
- 用量小卡数据:monitor.agentSessions.snapshot.usage(ClaudeUsageSnapshot,
  组装时传入消耗子页;5 小时窗优先,缺失退本周;快照缺失如实「—」)。

**Status:** done(2026-11-13;装机目验归用户)

**Checklist:**

- [x] 立票 + worktree(feat/agent-tab-06)
- [x] PulseCore:AgentUsageWindow 扩展(四桶窗口聚合 + cacheMultiplier 分母 0 → nil)+
      会话数合成(slug 尾段唯一归并已知项目,防两套归组口径 miss)+ 协议默认空实现
- [x] Live:会话数采集(Claude 数文件 / ZCode COUNT DISTINCT join workspace;NULL
      workspace 如实不计)
- [x] UI:DashboardModel.agentSubTab;MetricTabStack .agents 三分支 + 子药丸块;
      AgentUsagePaneView(数字卡排 4 张含用量卡「本周 N% · 重置 X 后」+
      ViewThatFits 双列 + 项目宽卡 min 360 上限 2 列);项目卡四桶行 + 会话数;
      ClaudeUsageCardView 撤除、开发服务节标题撤
- [x] 总览 maximumColumns 4 → 3(MetricTabStack metrics + DESIGN.md 三处文字 +
      PillTabBar comfortable 第二使用者入册)
- [ ] DESIGN.md:智能体页子 tab 节 + 组件更新 + 总览 1-3 列
- [x] check.sh **1305 例一次全绿**(核心 796 + app 509;Set.filter 返 Set 非
      Array 的坑已修)
- [x] 合并 develop、hook 装机、推 origin、票记档

**Out of scope:** Cost 美元、精确 Last Active 时刻、cleanupPeriodDays 调整(仍挂)、
杀会话 / Git 状态 / 孤儿端口(余量候选)、热力墙档位切换。
