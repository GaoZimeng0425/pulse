# 01: 主窗口排行与弹窗同规则截前 20(末行原地展开)+ 弹窗「查看全部」落地即展开

**What to build:** 用户 2026-11-02 追问「弹窗列表只有 20 个,主窗口却那么多,不该统一吗 / 弹窗有性能问题主窗口就没有吗」。如实回答:行是同一个 SwiftUI 组件,滚动逐行渲染,主窗口(LazyVStack 无行复用)按机制只会更贵,只是从没进过采样——不对称是「痛在哪修哪」留下的,不是原则。用户拍板:**不量,直接经验复用,主窗口和弹窗一致**。

**Status:** ready-for-agent(立票即分诊:用户直报 + 拍板已定;11-01 popover-top20 无票,本票一并记档;`.out-of-scope/` 无冲突)

**拍板(2026-11-02)**:
- 两处排行(组排行 + 能耗 / 读写 / 流量模块排行)同规则:只列前 `{layout.ranking-limit}` 20 名(令牌自 `popover-ranking-limit` 改名)。
- 末行按宿主:弹窗「查看全部(另 N 项)›」照旧跳主窗口,**并带上卡 id 让主窗口落地即展开该卡**(否则跳过去还是 20 行、要再点一次);主窗口「显示全部(另 N 项)⌄」原地展开,展开后「收起,只看前 20 名⌃」。展开态按卡 id 存 `DashboardModel.expandedRankingIDs`,切 tab 回前 20。
- 主窗口搜索命中不截(过滤本身已收窄)。
- 顺带收编旧伤:弹窗带 tab 跳主窗口**冷开窗落默认页**(原注释自认的限制)——落点改经路由 `AlertNotificationRouter.stash(tab:rankingID:)` 由菜单栏控制器在窗口不可见时记入,主窗口出现再消费;窗口存活时按广播直接落地并 `clearPending()`(告警通知点开也受益:此前存活窗口落地后 pendingTab 不清,下次冷开窗会重放)。

- [x] `RankingOverflow`(新文件):`limit` / `Action`(jump / expand)/ `split` / `rowModel`;`RankingOverflowPolicy`(宿主一次定:`.expandInPlace` / `.jumpToMainWindow`)按卡 id 派生动作;`RankingOverflowRow` 取代 `RankingShowAllRow`(三态文案 / chevron / help)
- [x] `RankingListCard` 加 `overflow` 统一画末行(LazyVStack 与 List 切片两形态);`RankingCardView` / `ModuleRankingCardView` 加 `overflow` 自截
- [x] `MetricTabStack` 加 `overflowPolicy`,模块排行卡按 `block.id` 派生;`MetricTabBlockBuilder.groupRankingID(for:)` 单一 id 规则
- [x] `DashboardModel.expandedRankingIDs` + `toggleRankingExpansion` / `expandRanking`
- [x] 路由:`rankingUserInfoKey` / `pendingRankingID` / `stash` / `clearPending`;`MenuBarController` 注入路由并在窗口不可见时记落点;`MainWindowView` onReceive 落地 + 清 pending、onAppear 消费 tab + 排行卡;`PulseApp` 接线
- [x] `DashboardView`:删 `rankingLimit`,原生列表三处改读 `RankingOverflow`,末行换 `RankingOverflowRow`,`openMainWindow(tab:rankingID:)`;List 回退路径组排行卡改由卡自截
- [x] `MainWindowView`:`overflowPolicy: .expandInPlace`,组排行卡 `overflow`(搜索生效 nil)
- [x] 测试 `PulseTests/RankingOverflowTests`(切分 3 / 末行 4 / 展开态 2 / 路由 2)
- [x] DESIGN.md:令牌改名 + 排行列表条目重写
- [x] `xcodegen generate` → `sh scripts/check.sh`:lint 过、构建过;宿主测试在 `.worktrees/` 下跑手挂死(「test runner hung before establishing connection」,记忆里的旧病复发),按退路到 `/tmp/pulse-ranking-limit` detached worktree 重跑 → **核心 558 + app 413 = 971 例 0 失败** → 合 develop(hook 装机)
- [ ] 用户目验:主窗口 CPU tab 组排行只 20 行 + 末行「显示全部(另 N 项)」,点开全量、末行变「收起」;电池页能耗排行同;弹窗 CPU tab 点「查看全部」→ 主窗口冷开窗直接落 CPU tab 且组排行已展开;主窗口搜索框输入时榜单不截

## Comments

- **为什么不先量主窗口**:用户拍板「不用跑,直接经验复用」。记档:主窗口翻长榜的真实数字仍未测,若日后要撤截断,先量。
