---
version: 1.0
name: Pulse
omitted: []
colors:
  surface-window: "#ffffff / #1a1a1d"
  surface-card: "#f5f5f7 / #1f1f22"
  surface-card-high: "#e8e8ed / #27272b"
  ink-tertiary: "#a1a1a6 / #6e6e73"
  accent-cpu: "#2a78d6 / #3987e5"
  accent-memory: "#4a3aa7 / #9085e9"
  accent-disk: "#eda100 / #c98500"
  accent-network: "#1baf7a / #199e70"
  accent-battery: "#008300 / #2fa83a"
  accent-gpu: "#e87ba4 / #d55181"
  accent-sensors: "#d96a4e / #e07b5f"
  accent-sound: "#c2379b / #d955b3"
  accent-bluetooth: "#0891b2 / #22a8cc"
  accent-containers: "#eb6834 / #d95926"
  state-positive: = {accent-battery}
  state-negative: "#e0352b / #ff453a"
  state-warning: = {accent-disk}
  state-inactive: "secondary @ 40%(系统语义色,随外观)"
  category-app: "#a2845e / #ac8e68"
  category-project: = {accent-cpu}
  category-system: "#8e8e93 / #98989d"
  category-background-service: = {accent-network}
  category-orphan: "#ff9500 / #ff9f0a"
typography:
  font: "SF Pro(系统默认,不引第三方字体)"
  figure-overview: "34pt bold rounded, tabular"
  figure-main: "44pt bold rounded, tabular"
  figure-main-compact: "30pt bold rounded, tabular"
  figure-overview-compact: "22pt bold rounded, tabular"
  figure-ring: "19pt bold rounded, tabular"
  figure-ring-compact: "16pt bold rounded, tabular"
  page-title: "26pt bold"
  section-title: "17pt bold"
  figure-mini: "17pt semibold rounded, tabular"
  card-title: "12.5pt semibold"
  body: "12pt"
  caption: "11pt"
  micro: "10.5pt"
rounded:
  card: 18pt
  card-compact: 12pt
  inner: 10pt
  chip: 8pt
  pill: 9999pt(胶囊)
spacing:
  unit: 4pt
  micro: 2pt
  inline: 6pt
  gap: 8pt
  group-gap: 12pt
  card-padding: 16pt
  card-padding-compact: 12pt
  card-gap: 16pt
  window-padding: 24pt
components:
  metric-card: "总览指标卡,见 §Components"
  metric-main-card: "指标 tab 主卡,见 §Components"
  pill-tab: "药丸 tab,见 §Components"
  menubar-badge: "菜单栏徽标,见 §Components"
---

# Pulse DESIGN.md

> 本文件是 Pulse 全部 UI 的**唯一视觉宪法**,格式遵循
> [google-labs-code/design.md](https://github.com/google-labs-code/design.md) v1 规范
> (YAML 令牌 + 叙述层)。任何代理(或人)写/改 SwiftUI 视图前先读这里;
> 与本文件冲突的旧代码按 §已知偏差 清单在重构时收编,不得新增偏差。
> 令牌的**代码出处**永远优先于本文件的数值快照:颜色在 `Pulse/Views/MetricAccent.swift`,
> 数值漂移以代码评审 + 本文件 §已知偏差 追踪。

## Overview

Pulse 是 macOS 26+ 菜单栏系统监控 app(Vitals 克隆),三个展示面:
菜单栏徽标(NSStatusItem 位图)、菜单栏弹窗(360pt 定宽)、主窗口(最小 720×560)。
设计语言 = Vitals:深浅双外观、卡片化、每指标一色、无投影扁平层级。
所有数值单位为 pt(SwiftUI 默认),颜色一律 `浅色 / 深色` 双值。

## Colors

语义键与**代码唯一出处**对照(视图层禁止直写 hex / `Color.orange` 等裸色):

| 令牌 | 代码出处 | 用途 |
|---|---|---|
| `{colors.surface-window}` | `Surface.window` | 窗口 / 弹窗本体底 |
| `{colors.surface-card}` | `Surface.card` | 卡片底 |
| `{colors.surface-card-high}` | `Surface.cardHigh` | 卡内强调底、环形"其他/空闲"段 |
| `{colors.ink-tertiary}` | `Surface.inkTertiary` | 三级墨色(缓存段、最弱文字) |
| `{colors.accent-cpu}` … `{colors.accent-battery}`、`{colors.accent-gpu}`、`{colors.accent-sound}`、`{colors.accent-bluetooth}`、`{colors.accent-containers}` | `Metric.accentColor` | 每指标一色:tab、图表、徽章、大数字(GPU 入表 p2-sensors/02;Neural 与 Memory 同色,03 票再议;Sound/Bluetooth 入表 p2-sensors/05、Containers 取 §1.1 Projects 行(p2-sensors/07),均现成行零发明,外设页 tab 强调取 Bluetooth 青) |
| `{colors.state-positive}` | `Surface.positive` | ✓正常、充电中 |
| `{colors.state-warning}` | `Surface.warning`(= Disk 指标色别名) | 压力偏高、优化充电介入、触发中告警横幅(琥珀语义) |
| `{colors.category-*}` | `GroupCategory.identityColor` | 非 App 组的图标瓦片底色;孤儿另作组行强调色(见下) |
| `{colors.state-negative}` | `Surface.negative` | 高负载、紧张、结束进程等负面偏差 |
| `{colors.state-inactive}` | `Surface.inactive` | 行首状态点的"停 / 未连接"态(容器未运行、蓝牙设备未连接);亮起态取所在页指标色(p2-review/03 入表) |

规则:
- 文字层级用系统语义(`.primary/.secondary/.tertiary`),不自定义灰。
- 指标色只允许从 `Metric` 枚举取——新增指标先入表(浅深互异、指标互异有单测钉死)。
- **类别身份色**(arch-review-2026-10-18/02 立节):App 棕(理论兜底,App 组实际画真实
  图标)/ 项目 = CPU 蓝 / 系统 中性灰 / 后台服务 = Network 绿 / **孤儿 橙**,唯一出处
  `GroupCategory.identityColor`(与 `Metric` 同级,在 MetricAccent.swift)。孤儿橙是
  **身份**不是强调级,有意不与 `{colors.state-warning}` 琥珀合并(GLOSSARY:橙色高亮)。
- 强调级(正常/偏高/紧张)→ 色的映射只允许集中在三处:`StatusBadge.chip`(系统
  负载)、`MetricCardModel` 的 chip 构造(内存压力、电池充电状态;两者都在 MetricCardModel.swift)
  与 `MenuBarBadgeRenderer.color(for:ink:)`;色值一律取语义令牌(菜单栏例外见 §已知偏差)。
  组排行行的高负载警示不走 chip——行尾 CPU 数值圈红表达(见 §Components 排行列表,
  2026-10-26 用户拍板:行内文字 chip 遮挡信息),色取 `{colors.state-negative}`。
- 菜单栏位图颜色只能经 ImageRenderer 预绘(`.renderingMode(.original)`);
  NSStatusItem 会剥掉 SwiftUI 前景色,这是实测结论不是风格偏好。

## Typography

| 角色 | 规格 | 用在哪 |
|---|---|---|
| `{typography.figure-main}` | 44pt bold `.rounded` + `monospacedDigit` | 指标 tab 主卡大数字 |
| `{typography.figure-overview}` | 34pt bold `.rounded` + `monospacedDigit` | 总览卡大数字(单位半号 48%) |
| `{typography.figure-main-compact}` | 30pt(同族) | 弹窗主卡大数字 |
| `{typography.figure-overview-compact}` | 22pt(同族) | 弹窗总览卡大数字 |
| `{typography.figure-ring}` / `-compact` | 19 / 16pt(同族) | 环心数字(全尺寸 / 弹窗) |
| `{typography.page-title}` | 26pt bold | 主窗口页名 |
| `{typography.section-title}` | 17pt bold | 节标题("此刻"/"当前最忙") |
| `{typography.figure-mini}` | 17pt semibold `.rounded` + `monospacedDigit` | 历史页均值/峰值等次级数字 |
| `{typography.card-title}` | 12.5pt semibold,指标色 | 卡片标题行 |
| `{typography.body}` | 12pt | 统计数值(semibold + `monospacedDigit`)、正文 |
| `{typography.caption}` | 11pt | 说明、表头、次级标签 |
| `{typography.micro}` | 10.5pt | 统计列标签、最密排注 |

规则:
- **一切数字**读数(百分比、字节、速率、PID)必须 `monospacedDigit()`;
  大数字另加 `.rounded` 设计族与负字距(`FigureText` 是唯一实现,不要复刻;字号只取
  `FigureSize` 令牌)。统计值(标签 + 数字)不是大数字:`{typography.body}` 12 semibold
  等宽,不走圆体(`StatValue` 是唯一实现)。卡内明细行的数值(名称 + meter + 数值行)
  是 `{typography.body}` 12 **常规** + `monospacedDigit`(`CardRowValue` 是唯一实现,
  p2-review/03)。
- 不用整体等宽字形 `design: .monospaced`(SF Mono)——数字对齐只靠 `monospacedDigit`;
  确需等宽字形的非数字内容(如十六进制键名)须先在此登记例外。目前无例外。
- 菜单栏徽标字号(11.5 / 7pt;网络上下行叠两行版式 9pt)是 NSStatusItem 尺寸约束下的特例,不外溢到窗口 UI。
- 不引第三方字体;中英文混排依赖系统默认,不手动调字距。

## Layout

4pt 网格:`{spacing.unit}`。允许值 = 网格整数倍,命名令牌优先:

| 令牌 | 值 | 用在哪 |
|---|---|---|
| `{spacing.micro}` | 2pt | 统计列"标签-值"行距等最紧排 |
| `{spacing.inline}` | 6pt | 行内图标-文字、卡内小节间距 |
| `{spacing.gap}` | 8pt | 相关元素组内间距 |
| `{spacing.group-gap}` | 12pt | 卡内小节之间 |
| `{spacing.card-padding}` | 16pt | 总览卡( full)内距 |
| `{spacing.card-padding-compact}` | 12pt | 弹窗紧凑卡内距 |
| `{spacing.card-gap}` | 16pt | 卡片网格的卡间 |
| `{spacing.window-padding}` | 24pt | 主窗口内容左右/底部边距 |
| `{layout.row-label-short}` | 36pt | 卡内明细行标签列(三字母域名 SoC / ANE,五路功率卡) |
| `{layout.row-label}` | 64pt | 卡内明细行标签列(四汉字 / 一个英文词,传感器派生卡) |
| `{layout.row-value-percent}` | 36pt | 卡内明细行数值列最小宽:整数百分比 `100%`(音量、设备电量) |
| `{layout.row-value-decimal-percent}` | 48pt | 同上:一位小数百分比 `99.9%`(容器 CPU) |
| `{layout.row-value-temperature}` | 52pt | 同上:温度 `99.9°C`(传感器派生卡) |
| `{layout.row-value-quantity}` | 56pt | 同上:带单位量 `999 MB` / `99.9 W`(容器内存、五路功率) |
| `{layout.row-value-rpm}` | 64pt | 同上:风扇转速 `9999 rpm` |
| `{layout.row-value-rssi}` | 32pt | 同上:信号强度 `-99 dBm` / `—`(蓝牙设备行) |
| `{layout.row-meter-compact}` | 44pt | 行内电量条宽(紧凑档,蓝牙设备行) |
| `{layout.row-meter}` | 64pt | 行内电量条宽(全尺寸档,蓝牙设备行) |
| `{layout.row-host-icon}` | 14pt | 下钻进程行宿主 App 徽标图标边长(project-visibility/02;徽标文字随行 `{typography.caption}` secondary,图标-文字间距 `{spacing.inline}`) |
| `{layout.overview-card-min-width}` | 340pt | 总览卡自适应网格的单卡最小宽(主窗口列数 1–4 由它派生:列数 = 内容宽容纳的最多列,340 + 列距 16,上限 4) |
| `{layout.sheet-width}` | 460pt | 确认清单 sheet 定宽(清理页「清理…」,p4-cleaner/04;原型 B 变体同值) |
| `{layout.sheet-list-max-height}` | 220pt | 确认清单 sheet 内逐行列表的最大高(超出滚动,总量与按钮恒在视口内) |

窗口:主窗口最小 **720×560**(spec 钉死),默认 880×620;弹窗定宽 **360pt**
(`DashboardView.width`)。工具栏内容必须按 720 最小窗宽预算(见 §Do's and Don'ts)。
主窗口总览网格是**响应式**的(用户拍板 2026-10-24):列数随窗宽自适应 1–4
(720 最小宽下 1 列、744 起两列、约 1104 三列、约 1456 四列;`AdaptiveCardGrid`)。

## Elevation & Depth

**无投影、不描边**。层级只有三级,靠底色差一档表达:
`{colors.surface-window}`(窗)> `{colors.surface-card}`(卡)> `{colors.surface-card-high}`(卡内抬升)。
弹出的浮层(菜单栏弹窗、系统工具栏玻璃)交给系统材质,不自绘阴影。

## Shapes

| 令牌 | 值 | 用在哪 |
|---|---|---|
| `{rounded.card}` | 18pt | 全尺寸卡片(总览卡、主卡、走势卡) |
| `{rounded.card-compact}` | 12pt | 弹窗紧凑卡 |
| `{rounded.inner}` | 10pt | 卡内嵌套表区 / 次级容器 |
| `{rounded.chip}` | 8pt | 徽章底、行选中底 |
| `{rounded.pill}` | 胶囊 | 状态 chip、药丸 tab、搜索框、meter 条 |

圆角不随尺寸缩放(小元素不自动变小圆角)——形状由容器语义决定,由本表查得。

## Components

- **卡片家族零件**(arch-review-2026-10-18/02 中4,`Pulse/Views/CardFamily.swift`):卡壳
  `cardShell(compact:)`(底色 + 圆角 + 内距,两档;`padded: false` 只给内距随版式
  变化、自己排内距的卡用——总览卡 16/12、指标主卡 20/12)、主卡头 `CardHeader`(22pt 徽章 +
  card-title 指标色)、副卡头 `CardSubHeader`(10pt 指标色符号 + 11 medium 次级标题 +
  10.5 注记)、统计值 `StatValue`、卡内空态 `CardEmptyState`(12.5 medium secondary 一句 +
  10.5 tertiary 说明,居中;可带一个 11pt `.link` 动作——授权型能力卡的开启 / 授权 /
  去系统设置,与告警横幅降级出口同款,其余空态不配按钮)、卡内明细行数值 `CardRowValue`(12 常规 `monospacedDigit` 右对齐,
  最小宽取 `{layout.row-value-*}` 令牌即 `CardRowWidth`;标签列定宽取 `{layout.row-label*}`)。
  **新卡一律组装这些零件,
  不再手写卡壳 / 卡头 / 空态。**

- **MetricCardView(full)**:徽章 22×22 + 标题 + chevron / 34pt 大数字 + 状态 chip /
  三列统计 / 36pt 高 44 柱 strip 走势——五张卡同形态(用户拍板 2026-10-20:撤 CPU
  面积线特例,不再特殊化)。
- **总览模块卡网格**(用户拍板 2026-10-17;列数 2026-10-24 改自适应):CPU/内存/
  GPU/磁盘/网络/电池六卡(电池卡随有无内建电池),点卡跳对应 tab;主窗口列数
  **自适应 1–4**(单卡最小宽 `{layout.overview-card-min-width}` 340,卡间距 16),
  弹窗 compact 定宽 360 固定 2 列、间距 8。
- **MetricMainCardView**:左列 200pt(标签 / 44pt 数字 / chip / 2×2 统计)+
  右列 56 点面积图,卡高 176pt。compact(弹窗)竖排:数字行 / 64pt 面积图 / 四列统计;
  底部走势组件 full / compact 同一(用户拍板:同一指标两处读数同观感)。
- **排行列表(RankingListCard / RankingListRow,用户拍板 2026-10-20:各 tab 一个样)**:
  组排行「当前最忙」(`RankingCardView`,可展开 / 悬停结束)与模块排行「能耗影响 /
  读写最多 / 每进程流量」(`ModuleRankingCardView`,只读)是同一组件的两种用法,不另写卡
  或行。卡 = 卡内标题 `{typography.card-title}`(12.5 semibold,**所在页指标色**)→ 表头
  「应用 | 指标名」(10.5 medium tertiary,右列对齐数值列)→ 行 → 可选注脚(10.5 tertiary,
  如"5 秒一档")→ 空态在卡内(12.5 medium secondary 一句 + 10.5 tertiary 说明)。
  行 = 图标 22 / 名称 13 medium(可挂徽章)/ 副文 10.5 secondary / meter 110 榜首归一 /
  数值 13 semibold `monospacedDigit` **定宽列**(按最宽现实读数 `999.9 MB/s` 量宽 + 2,
  全部排行共用;不许按内容撑宽——速率文案会逐行撑出不同宽度)/ **行尾恒留 30pt 列**(组排行放结束按钮 +
  展开箭头,模块排行留空)——所有排行的 meter 与数值在同一竖线上。组排行行高负载警示
  (组 CPU > 100%,阈值 `StatusBadgeRules` 同源)= **该行 CPU 数值圈红**:
  `{colors.state-negative}` 数字 + 同色 1pt 胶囊描边、负内距外扩 4pt(随文不占版,
  数值竖线与行高不动);仅 CPU 口径行,内存口径行不标;不再挂行内"高负载"文字 chip
  (2026-10-26 用户拍板:chip 挤占行宽遮挡信息)。此描边是警示标记,不属 §Elevation
  的"不描边"层级规则。紧凑档(弹窗):
  图标 18、名称 / 数值 12.5、meter 52、数值列同法按 12.5pt 量宽、行内距 5;卡 `{rounded.card-compact}` 12
  + `{spacing.card-padding-compact}` 12;全尺寸卡 `{rounded.card}` 18 + `{spacing.card-padding}` 16。
  排行卡不配节标题(主窗口也不配「当前最忙」节标题)。
  **meter 条宽度无过渡动画**(读数到即重画;2026-10-29 用户拍板「体感不到的东西不应该
  存在」——0.6s 缓动让面板开期 CPU 36.5% vs 无动画 8.4%,popover-layout-loop/01)。
  **行容器与弹窗滚动区一律 `LazyVStack`**(2026-10-30 popover-appkit/10 实测:排行常上百行,
  普通 VStack 全建 → 弹窗开期鼠标移动 ~33% / 滚动 ~41%,惰性后 ~7% / ~25%;不得退回 VStack)。
- **清理清单行**(p4-cleaner/04,`CleanerJunkViews.swift`):借排行列表行配方
  (`RankingListMetrics` 全套:图标 22 / 名称 13 medium + 副文 10.5 secondary / meter 110
  榜首归一 / 数值 13 semibold 等宽定宽列 / 行内距 6×7),行首加系统 checkbox;行选中底 =
  `{colors.surface-card-high}` 70% + `{rounded.inner}` 10。**安全档 chip**(`TierChip`)=
  状态 chip 配方(胶囊、tint 15% 底 + 同色文字、`{typography.micro}` 10.5 semibold),
  两态:可安全清理 = `{colors.state-positive}`、先检查 = `{colors.state-warning}`——映射的是
  GLOSSARY「安全档」(删除安全语义),不是负载警示,只在此组件出。勾选动作条 =
  `{colors.surface-card-high}` + `{rounded.card-compact}` 12,内距 8×12,右侧
  「清除勾选」bordered + 「清理…」borderedProminent(所在页指标色);确认清单走
  `{layout.sheet-width}` 460 定宽 sheet(标题 `{typography.section-title}`、逐行同清单行减
  checkbox、页脚总量 `{typography.card-title}` + 口径注记,`{layout.sheet-list-max-height}`
  220 滚动)。清单默认全不勾;右键行 = 排除该目录 / 在 Finder 中显示。
- **AreaTrendChartView**:56 点、线 2px 指标色、线下渐变 32%→0、4 条 8% 网格线、
  2% 左垫底;**StripChartView**:44 柱、36pt 高。二者都是自绘 Canvas,不引 Charts。
- **PillTabBar(通用药丸 tab 条,用户拍板 2026-10-22:tab 是通用组件样式)**:
  唯一视觉配方在 `Pulse/Views/PillTabBar.swift`——选中 = 该项强调色 15% 胶囊底
  + 同色前景,未选中 = secondary 前景无底;内距 9(水平)×5(垂直)、药丸间距 4;
  切换动画 0.2s snappy(选中文字自图标侧展开、胶囊生长、其余药丸滑移让位)。
  两种文字形态:`.selectedOnly`(未选中纯图标 / 选中图标+文字;图标-only 必带
  a11y label + help)与 `.always`(文字恒显)。四处用法同一组件:主窗口工具栏
  tab(`MetricPillTabBar` 薄封装 = `.selectedOnly` + ←/→ 键盘 + 首尾再留 4pt
  与系统玻璃底的间距;选中才展开文字是用户拍板 2026-10-16 的宽度根治法)、
  历史页指标条(同工具栏形态:五项各指标色 + 与主窗口 tab 同符号,系统负载取
  仪表盘符与 CPU 区分)、历史页分项条(p2-review/07,用户拍板 2026-10-24 形态 (a):
  只在有分项的指标——温度、功率——出现,挂在指标条正下方,`.always` 无图标,一次
  看一条线不叠加;各项取分项色——功率单域取五路功率卡域配色 `PowerDomain.tint`,
  一个出处;间距沿用页面竖排间距 8 / 12,不另立数值)、历史页范围条(`.always` 无
  图标,色调随所选指标 / 分项)。
  玻璃外裹(用户拍板 2026-10-22:历史页要同款包裹):工具栏胶囊是 macOS 26
  工具栏给 `.principal` 自动套的系统玻璃;内容页用法传 `isGlassContainer: true`
  自备同款——药丸外 4pt 内距 + 系统 Liquid Glass `glassEffect()` 胶囊(系统
  材质,不自绘底/影);工具栏用法恒 false,避免双重玻璃。
- **工具栏**:药丸 tab 挂 `.principal`,搜索框定宽 **132pt** + 齿轮挂
  `.primaryAction`;标题不进工具栏(`.toolbar(removing: .title)`)。
  任何新增工具栏项必须重新验证 720 最小窗宽不触发 `>>` 溢出菜单。
- **MenuBarLoadLabel / MenuBarBadgeRenderer**:全部内容一次 ImageRenderer 合成
  **单张**位图(多张 Image 只渲染第一张,实测);槽位 1–4 个(四项可同时上屏);
  CPU/RAM/磁盘剩余% 槽按 `100%`、网络按 `↓999.9 KB/s`(9pt)**定宽**(`slotWidth`),
  数字左对齐——状态项宽度恒定,相邻图标不被挤动。网络槽无小标签,↑上行 / ↓下行
  叠两行(用户拍板 2026-10-20,Stats 同款),两行合高不超过「7pt 标签 + 11.5pt 数字」。
- **主窗口 / 弹窗同内容**(用户拍板 2026-10-20,取代早先「排行卡 / dev server /
  历史页弹窗不放」):每个 tab 的卡片组成与顺序只在 `MetricTabStack` 一处定义,两处
  只差排版档——弹窗卡用紧凑档、主窗口并排的两卡改上下排、节标题不画;组排行卡的
  交互深度(主窗口搜索 + 可排序进程表)由宿主给。新增卡片只改 `MetricTabStack`。
  **唯一拍板例外**(p2-review/04 A,2026-10-24;spec Story 17):传感器 tab 弹窗只放
  派生读数卡(Average/Hottest + 最快风扇),风扇卡与温度明细卡只在主窗口——逐核明细
  会把 360pt 弹窗撑得不可用的高。
- **传感器卡文案与风扇条**(p2-review/08):风扇转速 rpm 0 写「停转」(真读数,不写
  「0 rpm」,也不是读失败的「—」);读不到 / 无风扇写「—」。风扇 meter 按该扇上下限归一
  (rpm−min)/(max−min) 钳 0…1,上下限不可用(max ≤ min)给空条;上下限标注
  「下限 N · 上限 M rpm」(`{typography.micro}` 10.5 tertiary):全部风扇相同时卡头注记写一次,
  不同时逐扇行下各写,两处不同时出现。派生卡最快风扇行多扇时数值前带扇名(「名 · 3200 rpm」)。
- **弹窗 DashboardView**:定宽 360pt;底部操作"开窗靠左、设置+退出靠右"
  (退出 = 纯图标,用户拍板)。顶部图标 tab 槽位**单行满宽均分**(P2 扩到
  11 枚后 32pt 定宽槽超出 332pt 内容区、右端裁切;均分只收窄不溢出,与主窗口
  工具栏 720 预算同一哲学)。页头 = 页名 + 本机一行「芯片 · 核数 · 内存」
  (`hostSummary`,与主窗口内容头同源;Vitals 页头同款)+ 右侧运行时长,全 tab 一致。
- **状态 chip**:胶囊、tint 14~16% 底 + 同色文字,两态语言(✓正常 / 高负载),
  阈值在 `StatusBadgeRules`(组 >100%、系统 <30% / >70%)。现役用法 = 指标卡大数字旁
  (系统负载);**排行行不再挂文字 chip**,组高负载改由行尾数值圈红表达(见排行列表条,
  2026-10-26 用户拍板)。

## Do's and Don'ts

**Do**
- 新视图先查本文件;数值不在令牌表里 = 需要新令牌(先改表再写码)。
- 数字一律 `monospacedDigit()`;颜色一律语义键;圆角/内距一律查表。
- 用户可见的新形态:实机截图验收交给用户(代理不循环截图),机械断言进单测。

**Don't**
- 不直写 `Color.orange/.red` 或 hex;不新增投影/描边;不引第三方 UI/图表/字体库。
- 不把窗口 UI 的规格带进菜单栏位图(字号、颜色管线都是特例),反之亦然。
- 已拍板的样式不静默回退:未选中 icon-only 药丸、总览卡底部 44 柱 strip(弹窗与
  主窗口同形态,五张卡不分指标)、退出纯图标……要改先问用户。
- 工具栏不做会触发溢出菜单的加项(720 窗宽预算优先级 > 功能堆叠)。

## 已知偏差(重构时收编,不新增)

2026-10-17 首轮收编已完成(rg 全量盘点 → 逐项落码):圆角 6/7/9pt → `{rounded.chip}`
8pt(进程行选中底/设置图标砖/徽章/弹窗底排按钮);标签-值行距 3pt → `{spacing.micro}`
2pt ×5 处;卡间 18pt → `{spacing.card-gap}` 16;弹窗紧凑卡与进程详情内距 10 →
`{spacing.card-padding-compact}` 12;进程行水平内距 10 → 12(表头同步,列对齐不变);
chip 图标 9.5pt → micro 10.5;排行行 chevron 9pt → 10。

勘误(盘点时误报,实为合法形态,不改):12.5pt = `{typography.card-title}`;
13pt/16pt 出现在 **图标与容器尺寸**(图标 tab、设置图标砖、图标砖边长),不受文字角色约束;
17pt 已立为 `{typography.section-title}` / `{typography.figure-mini}` 两角色。

2026-10-20 第二轮收编已完成(arch-review-2026-10-18/02):11.5pt 文字 13 处 → 说明类
`{typography.caption}` 11、行标签 / 数值 / 按钮 `{typography.body}` 12;卡壳 / 卡头 / 统计值 /
空态收进卡片家族零件(环形卡空态的 28pt 竖向内距随之消失);告警横幅裸橙 + 描边 →
`Surface.warning` 淡底、无描边;类别色 `.brown/.gray/.orange` → 类别身份色;进程表结束
按钮 `.red` → `Surface.negative`;大数字字号 → `FigureSize` 令牌。

登记的有意例外(不是偏差):
- **设置窗侧栏的彩色渐变图标砖**:仿系统设置风格(SettingsView),属系统外观对齐,不走
  指标色 / 类别色。
- **环形图用 Apple Charts(`SectorMark`),走势图自绘 Canvas**:环形的扇区几何与图例
  交给 Charts 最省;走势是高频重绘的 44 柱 / 56 点,自绘可控成本——有意分工,不统一。
- **菜单栏徽标强调色直写 `.orange/.red`**:位图经 ImageRenderer 预绘,本轮没有验证动态色
  在离屏渲染里能否按外观正确解析,暂留系统色、集中在 `MenuBarBadgeRenderer.color` 一处;
  要换成语义令牌须先实机验证深浅两种外观。

仍挂账(动到对应文件时顺带收编):
- 指标主卡全尺寸内距 `.padding(20)`(MetricTabViews)与 2×2 统计 `horizontalSpacing: 18`
  不在令牌表,18 也不在 4pt 网格上;弹窗外框 `.padding(14)`(DashboardView)同。
  三者改动都可见,需与用户确认后再动。

