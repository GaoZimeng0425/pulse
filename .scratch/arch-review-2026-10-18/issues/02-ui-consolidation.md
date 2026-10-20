# 02: 票 B —— UI 组件收口 + 第二轮规范收编

**What to build:** 架构审查(本目录 REPORT.md)中4 + 中8,顺带并入低优先级的 UI 杂项(monospacedDigit / a11y / 预览缺口)。时机敏感:主/弹窗同构刚拍板(module-rankings 轮),是抽共用装配的唯一好时机。

**Status:** done

**Blocked by:** 01(票 A 改 SystemMonitor/聚合内核,B 的装配抽取要建立在拆分后的形状上)

范围(证据与计数见 REPORT.md §中4/§中8/§低):

- [x] **中4 卡片家族收口**(2026-10-20 落地:`CardFamily.swift` 卡壳 / 卡头 / 副卡头 / 统计值 / 空态;`MetricTabStack` 共用每 tab 内容栈;排行列表收成 `RankingListCard`)(REPORT §4):CardShell(style:) modifier 统一 12 处卡壳的 3 种 compact 判定;CardHeader / 副卡头 / StatValue / EmptyState 小组件(现各 4/4/4/5 份手抄);统计值字号 4 变体归一;ModuleCardGrid + MetricTabStack 抽取(总览五卡网格主/弹窗两份逐字重复)
- [x] **中8 设计系统第二轮收编**(2026-10-20 落地:类别身份色 `GroupCategory.identityColor` + DESIGN.md 立节;告警横幅 `Surface.warning` 淡底去描边;`FigureSize` 令牌;设置渐变砖 / Charts 环形登记例外;模块排行表外值随 RankingList 重写清空)(REPORT §8):类别身份色表(含孤儿橙)入 MetricAccent 同级唯一出处并在 DESIGN.md 立节;告警横幅裸 Color.orange + 描边(AlertViews.swift:33-37)改语义令牌 + 去描边;设置渐变砖仿系统风格在 DESIGN.md 登记例外;ModuleRankingCard 表外值收编(6×7 行距、spacing 1/5/10、padding 14、FigureText 22/30/19/16、Color.primary.opacity 三档);FigureText compact 档立令牌
- [x] 并入低优先级 UI 杂项(2026-10-20 落地):monospacedDigit 三处缺口(HistoryView 均值峰值 / 弹窗 uptime / 告警阈值);a11y 两处(主窗齿轮 + 清空钮缺 label);预览缺口 4 文件(RingCardView / SettingsView / GeneralSettings / MenuBarBadgeSettings);RingCardView「Apple Charts 画环形 vs 走势自绘」双轨在 DESIGN.md 登记为有意分工

约束与验收:
- **改任何 SwiftUI 视图前先读 DESIGN.md**(AGENTS.md 强制条款);数值不在令牌表 = 先补表再写码;已拍板样式不得静默回退(icon-only 药丸、popover strip、CPU 总览 area line 等见 Don'ts)
- ~~11.5pt 字号专项不在本票~~——2026-10-20 用户问起后并入(只剩 13 处且大多在本票要改的文件里),已收
- `sh scripts/test.sh` 全绿;视觉验收归用户(自查一次截图即可,勿循环截屏)

## Comments

- 2026-10-20 本票期间用户追加拍板:弹窗与主窗口每个 tab 同内容(撤「排行卡 / dev server / 历史页弹窗不放」);排行列表一个样(卡内指标色标题、表头、行尾恒留列、数值列定宽);总览卡走势撤 CPU 面积线特例,五卡一律 44 柱 strip。
- 统计值归一到 `{typography.body}` 12 semibold:主窗口主卡 2×2 统计由 15pt 圆体变小到 12pt,待用户实机确认观感。
- 遗留:菜单栏徽标强调色仍直写系统色(动态色离屏渲染未验证,DESIGN.md 已登记)。
