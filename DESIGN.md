---
version: 1.2
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
  accent-clean: "#0d9488 / #35c4b5"
  accent-agents: "#5a921a / #a6d94a"
  projects-accent: = {accent-containers}
  state-positive: = {accent-battery}
  state-negative: "#e0352b / #ff453a"
  state-warning: = {accent-disk}
  state-caution: "#d95926 / #eb6834"
  state-inactive: "secondary @ 40%(系统语义色,随外观)"
  category-app: "#a2845e / #ac8e68"
  category-project: = {accent-cpu}
  category-system: "#8e8e93 / #98989d"
  category-background-service: = {accent-network}
  category-orphan: "#ff9500 / #ff9f0a"
  junk-dev: = {accent-cpu}
  junk-browser: = {accent-gpu}
  junk-app: = {category-app}
  junk-project: = {accent-memory}
  junk-ai: = {accent-bluetooth}
  junk-leftover: = {accent-sensors}
  junk-trash: = {accent-disk}
  agent-source-claude: "#c9622f / #e8946a"
  agent-source-zcode: "#6a4fe0 / #8f7cf5"
  agent-model-first: "#1a78bd / #58a8e8"
  agent-model-second: "#bd3a7c / #e070a8"
  agent-model-third: "#93730f / #cfab4a"
  settings-icon-general-from: "#9e9ea8"
  settings-icon-general-to: "#6b6b78"
  settings-icon-alerts-from: "#f29e33"
  settings-icon-alerts-to: "#d9591a"
  settings-icon-project-roots-from: "#4d8cf2"
  settings-icon-project-roots-to: "#2659bf"
  settings-icon-menu-bar-from: "#9466eb"
  settings-icon-menu-bar-to: "#6b38c7"
  settings-icon-cleaner-from: "#fab326"
  settings-icon-cleaner-to: "#d98500"
typography:
  font: "SF Pro(系统默认,不引第三方字体)"
  figure-overview: "34pt bold rounded, tabular"
  figure-main: "44pt bold rounded, tabular"
  figure-main-compact: "30pt bold rounded, tabular"
  figure-stat: "28pt bold rounded, tabular"
  figure-card: "24pt bold rounded, tabular"
  figure-overview-compact: "22pt bold rounded, tabular"
  figure-ring: "19pt bold rounded, tabular"
  figure-ring-compact: "16pt bold rounded, tabular"
  page-title: "26pt bold"
  section-title: "17pt bold"
  figure-mini: "17pt semibold rounded, tabular"
  card-title: "12pt semibold"
  body: "12pt"
  caption: "11pt"
  micro: "10.5pt"
  row-name: "14.5pt medium(舒适)/ 12pt(紧凑)"
  row-value: "14.5pt semibold(舒适)/ 12pt(紧凑), tabular"
  row-sub: "12pt(舒适)/ 10.5pt(紧凑)"
icons:
  chevron: "9pt"
  inline: "11pt"
  leading-compact: "13pt"
  leading-comfortable: "16pt"
  empty-state: "26pt"
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
  card-family: "卡壳、卡头、统计值、空态、卡内行,见 §Components"
  row-metrics: "列表行两档制,见 §Components"
  chip: "状态芯片,见 §Components"
  metric-card: "指标卡两形态,见 §Components"
  card-grid: "自适应卡片网格,见 §Components"
  ranking-list: "排行列表,见 §Components"
  pill-tab-bar: "药丸页签条,见 §Components"
  page-header: "页头,见 §Components"
  menubar-badge: "菜单栏徽标,见 §Components"
  trend-chart: "走势图与条形图,见 §Components"
  breadcrumb: "面包屑,见 §Components"
  search-field: "搜索框,见 §Components"
  check-box: "勾选框,见 §Components"
  chart-hover: "图表悬停读数与浮层,见 §Components"
  header-text-button: "卡头文字按钮,见 §Components"
  settings-icon-tile: "设置侧栏图标砖,见 §Components"
---

# Pulse DESIGN.md

> 本文件是 Pulse 界面的**原则与通用组件规范**的唯一出处,格式遵循
> [Google Labs DESIGN.md 开放规范](https://github.com/google-labs-code/design.md)
> (YAML 令牌 + 叙述层)。任何代理或人写、改 SwiftUI 视图前先读这里。某一页怎么实现
> 不在这里——写在该页主视图文件开头的页面规格和对应代码旁的注释里;一条规矩属于
> 哪边,见 §Components 开头的判定法。
> 令牌的**代码出处**永远优先于本文件的数值快照:颜色在 `Pulse/Views/MetricAccent.swift`,
> 行尺寸在 `RowMetrics`,图标尺寸在 `IconSize`,大数字字号在 `FigureSize`。

## Overview

Pulse 是 macOS 26+ 菜单栏系统监控 app,三个展示面:
菜单栏徽标、菜单栏弹窗(360pt 定宽)、主窗口(最小 720×560)。
设计语言:深浅双外观、卡片化、每指标一色、层级靠底色差表达。
数值单位一律 pt;颜色一律「浅色 / 深色」双值,只有明确标为固定色的除外。

## Colors

| 令牌 | 代码出处 | 用途 |
|---|---|---|
| `{colors.surface-window}` | `Surface.window` | 窗口与弹窗的底 |
| `{colors.surface-card}` | `Surface.card` | 卡片底 |
| `{colors.surface-card-high}` | `Surface.cardHigh` | 卡内抬升的底;环形图的「其他 / 空闲」段 |
| `{colors.ink-tertiary}` | `Surface.inkTertiary` | 三级墨色:最弱的文字与图形 |
| `{colors.accent-cpu}` … `{colors.accent-containers}` | `Metric.accentColor` | 每指标一色:tab、图表、徽章、大数字的身份色 |
| `{colors.accent-clean}` | `Surface.cleanAccent` | 清理页专属强调色:主按钮、选中态、子页药丸 |
| `{colors.accent-agents}` | `Surface.agentsAccent` | 智能体页专属强调色:tab 图标、选中态、今日数字、日历色阶 |
| `{colors.projects-accent}` | `Surface.projectsAccent` | 内存构成环里「项目」一段的身份色 |
| `{colors.state-positive}` | `Surface.positive` | 正常、充电中 |
| `{colors.state-warning}` | `Surface.warning` | 偏高、优化充电介入、告警提示 |
| `{colors.state-caution}` | `Surface.caution` | 清理的「先检查」档 |
| `{colors.state-negative}` | `Surface.negative` | 高负载、紧张、结束进程、危险 |
| `{colors.state-inactive}` | `Surface.inactive` | 「停 / 未连接」的状态点 |
| `{colors.category-*}` | `GroupCategory.identityColor` | 非 App 分组的图标瓦底色 |
| `{colors.junk-*}` | `JunkGroup.identityColor` | 清理品类的身份色 |
| `{colors.agent-source-claude}` / `-zcode` | `AgentPartitionTint.sourceToken(_:)` | 智能体页两家来源的身份色:走势分层、来源构成条与图例 |
| `{colors.agent-model-first}` / `-second` / `-third` | `AgentPartitionTint.modelTokens` | 智能体页模型分布的分区色(三档,越界收第三档) |
| `{colors.settings-icon-*-from}` / `-to` | `SettingsIconTint` | 设置侧栏图标砖的渐变起止色(固定色) |

规则:

- 文字层级用系统语义色(`.primary` / `.secondary` / `.tertiary`),不自定义灰。
- 指标色只从 `Metric` 取。新增指标先入表:浅深互异、指标之间互异,有单测钉死。
- 指标色是**身份**,不是强调级。分组、品类借用指标色只是为了区分「是谁」;页面
  自己的强调色另定(清理页用 `{colors.accent-clean}`,智能体页用 `{colors.accent-agents}`)。
  页面强调色与全部指标色在浅、深两套内互不相等。tab 条的着色只经一个取色口
  (`MetricTab.tintColor`):有页面强调色的 tab 取页强调色,其余取指标色;有页面
  强调色的 tab 不属于指标族。
- 强调级(正常 / 偏高 / 危险)到颜色的映射只许出现在三处:`StatusBadge.chip`、
  `MetricCardModel` 里的状态芯片构造、菜单栏徽标渲染器。取值一律是语义令牌。
- 菜单栏位图里的颜色只能靠预绘位图带出去(系统会剥掉 SwiftUI 前景色)。位图里的
  深浅值按当次传入的外观解析,不靠绘制时的环境外观。

## Typography

| 角色 | 规格 | 用在哪 |
|---|---|---|
| `{typography.figure-main}` | 44pt bold 圆体,等宽数字 | 指标页主卡的大数字 |
| `{typography.figure-overview}` | 34pt bold 圆体,等宽数字 | 总览卡的大数字(单位约半号) |
| `{typography.figure-main-compact}` | 30pt bold 圆体,等宽数字 | 弹窗主卡的大数字 |
| `{typography.figure-stat}` | 28pt bold 圆体,等宽数字 | 智能体页数字卡的大数字 |
| `{typography.figure-card}` | 24pt bold 圆体,等宽数字 | 清理总览模块大卡的大数字 |
| `{typography.figure-overview-compact}` | 22pt bold 圆体,等宽数字 | 弹窗总览卡的大数字 |
| `{typography.figure-ring}` / `-compact` | 19 / 16pt bold 圆体,等宽数字 | 环形图中心的数字(主窗口 / 弹窗) |
| `{typography.page-title}` | 26pt bold | 页头标题(主窗口) |
| `{typography.section-title}` | 17pt bold | 节标题、下钻后的品类标题 |
| `{typography.figure-mini}` | 17pt semibold 圆体,等宽数字 | 次一级的数字(历史页均值与峰值) |
| `{typography.card-title}` | 12pt semibold | 卡头标题 |
| `{typography.body}` | 12pt | 正文、按钮、统计值(配 semibold 与等宽数字) |
| `{typography.caption}` | 11pt | 说明、表头、次级标签 |
| `{typography.micro}` | 10.5pt | 最密的注记、图例、图表轴字 |
| `{typography.row-name}` | 14.5pt medium(舒适)/ 12pt(紧凑) | 列表行的名称 |
| `{typography.row-value}` | 14.5pt semibold(舒适)/ 12pt(紧凑),等宽数字 | 列表行的数值(定宽列) |
| `{typography.row-sub}` | 12pt(舒适)/ 10.5pt(紧凑) | 列表行的副文、路径 |

规则:

- **窗口 UI 文字只有五档**:10.5 / 11 / 12 / 14.5 / 17,另加一组大数字(figure-*)。
  新文字不在五档内 = 先改本表再写码。
- **不用系统自带的语义字体**(`.caption`、`.footnote`、`.title3` 这类):它们不在
  五档内,还会随系统版本漂移。文字与图标都写显式字号;这条由 lint 把关。
- **系统控件自带的文字随控件走**:设置页的表单行、分段选择器的标签、带底色的系统
  按钮、系统弹窗的正文,字号由控件决定,不在五档之列,也不另写。
- **一切数字读数**用 `monospacedDigit()`。大数字另加圆体设计族与负字距,只有
  `FigureText` 一个实现,字号只取 figure-* 令牌。统计值(标签 + 数字)不是大数字:
  `{typography.body}` 12 semibold 加等宽数字,只有 `StatValue` 一个实现。
- **整体等宽字形**只用于两类内容:需要逐字辨别的路径(清理页的文件路径行),和按列
  对齐的百分比小标(空间地图块内)。其余对齐只靠 `monospacedDigit()`。
- **菜单栏徽标的字号自成一组**(标签 7pt、数值 11.5pt、上下行叠放 9pt),只用于菜单栏
  位图,不外溢到窗口。
- **符号图标的尺寸走图标档位**,不受文字五档约束:

  | 令牌 | 值 | 用在哪 |
  |---|---|---|
  | `{icons.chevron}` | 9pt | 排序、展开收起的上下小箭头 |
  | `{icons.inline}` | 11pt | 行内符号:行尾右箭头、卡头符号、小按钮里的符号、状态符号、勾选框对勾、页签条图标 |
  | `{icons.leading-compact}` / `{icons.leading-comfortable}` | 13 / 16pt | 行首的类型符号,随列表行的紧凑 / 舒适档 |
  | `{icons.empty-state}` | 26pt | 空态里的大符号 |

  随容器走的图标不归这五档,由所在组件给出:状态芯片里的符号随芯片档位;类别图标瓦
  里的符号按瓦片边长折算;设置图标砖与弹窗图标页签条里的符号是各自规格里的定值。
- 不引第三方字体;中英文混排依赖系统默认,不手动调字距。

## Layout

4pt 网格:`{spacing.unit}`。允许值 = 网格整数倍,命名令牌优先。

| 令牌 | 值 | 用在哪 |
|---|---|---|
| `{spacing.micro}` | 2pt | 最紧的「标签—数值」行距 |
| `{spacing.inline}` | 6pt | 行内图标与文字、卡内小节 |
| `{spacing.gap}` | 8pt | 相关元素之间 |
| `{spacing.group-gap}` | 12pt | 卡内小节之间 |
| `{spacing.card-padding}` | 16pt | 全尺寸卡片内距 |
| `{spacing.card-padding-compact}` | 12pt | 紧凑卡片内距 |
| `{spacing.card-gap}` | 16pt | 卡片网格的卡间距 |
| `{spacing.window-padding}` | 24pt | 主窗口内容区的左右与底部边距 |
| `{layout.row-label-short}` | 36pt | 项目大卡「模型 / 来源」行的标签列 |
| `{layout.row-value-percent}` | 36pt | 卡内读数行数值列的最小宽:整数百分比 |
| `{layout.row-value-decimal-percent}` | 48pt | 同上:一位小数的百分比 |
| `{layout.row-value-temperature}` | 52pt | 同上:带摄氏度 |
| `{layout.row-value-quantity}` | 56pt | 同上:带单位的量 |
| `{layout.row-value-rpm}` | 64pt | 同上:风扇转速 |
| `{layout.row-host-icon}` | 14pt | 下钻进程行里宿主 App 徽标的边长 |
| `{layout.overview-card-min-width}` | 340pt | 自适应卡片网格的单卡最小宽(主窗口列数 1–3 由它派生) |
| `{layout.module-card-min-width}` | 340pt | 清理总览模块大卡的单卡最小宽(列数上限 2) |
| `{layout.card-pair-two-column-min-width}` | 696pt | 两卡并排的断点:内容宽达到就并排等高,否则上下排 |
| `{layout.agent-project-limit}` | 10 个 | 智能体页项目大卡的默认展示上限 |
| `{layout.port-row-limit}` | 20 行 | 监听端口卡的默认展示行上限 |
| `{layout.agent-chart-two-column-min-width}` | 1872pt | 智能体页日历图与走势图并排的断点 |
| `{layout.ranking-limit}` | 20 行 | 各排行默认展示的上限 |
| `{layout.sheet-width}` | 460pt | 确认清单弹层的宽度 |
| `{layout.sheet-list-max-height}` | 220pt | 确认清单弹层内列表的最大高 |
| `{layout.spacemap-chart-min-height}` | 220pt | 空间地图方块形态的图表区高度下限 |
| `{layout.spacemap-sunburst-min-side}` | 360pt | 空间地图旭日的直径与图表区高度下限 |
| `{layout.spacemap-sunburst-viewport-share}` | 0.8 | 空间地图图表区高占滚动视口高的份额 |
| `{layout.spacemap-sunburst-max-side}` | 520pt | 空间地图旭日的直径与图表区高度上限 |
| `{layout.popover-size}` | 360×648pt | 菜单栏弹窗面板的定尺寸 |

窗口:主窗口最小 **720×560**,默认 880×620;弹窗面板 **360×648 定尺寸**
(`{layout.popover-size}`,内容撑满、不随内容伸缩)。工具栏内容必须按 720 最小窗宽
预算(见 §Do's and Don'ts)。

## Elevation & Depth

层级只靠底色差表达,共三级:
`{colors.surface-window}`(窗)> `{colors.surface-card}`(卡)> `{colors.surface-card-high}`(卡内抬升)。
卡片、容器、弹层不加投影、不加描边;弹出的浮层交给系统材质。
不在此列的三类:图表的线条与网格、控件自身的轮廓(勾选框)、装饰性的设置侧栏
图标砖(带柔影与高光描边,见 §Components)。

## Shapes

| 令牌 | 值 | 用在哪 |
|---|---|---|
| `{rounded.card}` | 18pt | 全尺寸卡片 |
| `{rounded.card-compact}` | 12pt | 紧凑卡片、卡内的小卡 |
| `{rounded.inner}` | 10pt | 卡内嵌套的表区、次级容器 |
| `{rounded.chip}` | 8pt | 徽章底、行选中底、搜索框 |
| `{rounded.pill}` | 胶囊 | 状态芯片、药丸页签、meter 条 |

圆角不随尺寸缩放(小元素不自动变小圆角):形状由容器语义决定,由本表查得。

## Components

本节只收**通用界面件**。每条四段:用途 → 形态与数值 → 状态与变体 → 什么时候用。

**判定法**:把一条规矩里的页面名遮掉,它还成立吗?

- **原则**:全 app 成立、不提任何页面的规矩(颜色、字号、间距、层级、该做不该做)。
- **组件规范**:一个通用界面件长什么样、有哪些状态、什么时候用;不提它被哪一页使用。
- **实现细节**:只对某一屏成立的摆法、交互、文案。不进本文件,写在该页代码旁。

只在一处使用的件再分两种:通用界面件(换一页也可能用)在这里立规范;业务专用的图和卡
(换一页就没意义)按实现细节处理。本文件里没有「例外」和「偏差」:写着例外,说明规范
没写完整,应改写成规则;代码没跟上,应改代码。

**总规矩**:新 UI 一律优先组装本节的标准件;标准件覆盖不了的形态,先在本节立规范再造,
不私开同义新件。

**跨组件的约定**

- **图表分工**:环形图与带轴的折线图交给系统图表库(静态或低频重画);高频重画的迷你
  走势与历史曲线自绘 Canvas,可控成本。带轴的折线图,日期轴不带单位、域取首末日的
  零点,否则点会偏离刻度半天。
- **动效纪律**:读数类的图形(meter 条、走势图、空间地图)不做过渡动画,读数到即重画;
  体感不到的动画不该存在。全 app 的切换动效只有页签一种。
- **主窗口与弹窗同一套卡片**:每个 tab 的卡片组成与顺序只在一处定义,两个窗口只差
  排版档(弹窗走紧凑档)。弹窗里恒上下排、间距 `{spacing.gap}` 8;主窗口按断点并排
  等高(见第 5 条)。两类内容只在主窗口:需要逐核明细的传感器卡,和空间地图。
- **未知与未查分开**:读不到、没查、查了没有是三种不同的状态,界面必须分开呈现;
  没查到的数字不上屏,读不到时不写 0。
- **纯图标按钮**必带悬停提示与无障碍标签。

### 1. 卡片家族零件

**用途**:卡壳、卡头、统计值、空态、卡内行的唯一实现;所有卡片由这些零件组装。

**形态与数值**

- 卡壳 `cardShell(compact:)`:`{colors.surface-card}` 底;全尺寸 `{rounded.card}` 18 +
  `{spacing.card-padding}` 16,紧凑档 `{rounded.card-compact}` 12 + `{spacing.card-padding-compact}` 12。
  版式确需自定内距的卡传 `padded: false` 自己排。
- 主卡头 `CardHeader`:徽章(22×22、`{rounded.chip}` 8、强调色 16% 底,内含
  `{icons.inline}` semibold 的符号)+ `{typography.card-title}` 12 semibold 强调色标题,
  右侧是配件槽。
- 副卡头 `CardSubHeader`:`{icons.inline}` semibold 符号 + 12 semibold 标题(同强调色)
  + `{typography.micro}` 10.5 tertiary 注记(等宽数字)。
- 统计值 `StatValue`:标签 `{typography.micro}` 10.5 secondary(可带 6×6 色点),
  数值 `{typography.body}` 12 semibold、等宽数字、单行。
- 空态 `CardEmptyState`:12 medium secondary 一句 + 10.5 tertiary 说明,居中。
- **实体行** `CardEntityRow`(行描述一台设备、一个对象):行首类型图标(外框取
  `{icons.leading-*}` 一档,符号 `{icons.leading-compact}` / `{icons.leading-comfortable}`)
  + 名称 + 副文(等宽数字、secondary)+ 尾部自定义列;名称与副文各单行。
- **读数行** `CardReadingRow`(行描述一个测量):标签(单行、中段省略、弹性宽)+ meter
  (定宽)+ 数值 `CardRowValue`(默认 12 常规 secondary、等宽数字、右对齐;最小宽取
  `{layout.row-value-*}`)。
- 行内一切尺寸取自第 2 条;meter 条见第 6 条。

**状态与变体**

- 卡壳两档:全尺寸 / 紧凑(弹窗)。
- 空态可带一个 `{typography.caption}` 11 的文字动作:前置条件要在本 app 之外完成的空态
  (开启、授权、去系统设置)必须给出路,不留死空态;其余空态不配按钮。
- 未知值安静:逐行状态类的未知(设备电量读不到)整块留空,不写「未知」「—」占位;
  数值列里的未知读数仍写「—」,那是表格的诚实单元格。
- 实体行的图标色由调用方给:活跃取所在页的强调色,非活跃取 `{colors.state-inactive}`。

**什么时候用**:新卡片一律组装这些零件,不手写卡壳、卡头、空态。实体的信息用实体行,
测量的信息用读数行。

### 2. 列表行两档制

**用途**:全 app 列表行共享尺寸的唯一出处(`RowMetrics`),保证功能相似的行长一个样。

**形态与数值**(舒适 / 紧凑)

| 项 | 舒适(主窗口一切列表行) | 紧凑(弹窗) |
|---|---|---|
| 名称字号 | 14.5 medium | 12 medium |
| 数值字号 | 14.5 semibold,等宽数字,定宽列 | 12 semibold,同上 |
| 副文字号 | 12 | 10.5 |
| 行首图标外框 | 24 | 18 |
| meter 条宽 | 120 | 52 |
| 行内元素间距 | 10 | 8 |
| 行水平内距 | 14 | 6 |
| 行上下内距 | 10 | 5 |
| 卡内行之间的间距 | 20 | 10 |

- 名称与数值**同号**,层级靠字重。
- 卡内行(卡片里的实体行、读数行)没有悬停底、不带行内距,靠行间距复刻列表行的节奏。
- 数值列定宽:按该列最宽的现实读数,以实际绘制字体量宽;同列各行等宽,不按内容撑宽。
- 大卡里只缩进、不套小卡的子行(卡内裸行)统一缩进 28、上下内距 10。

**状态与变体**

- 两档:**舒适**给主窗口的一切列表行(排行、清单、确认单),**紧凑**给弹窗;同一份数据
  在两个窗口只差档位。
- 页面专属参数(行尾列、缩进、勾选框、数值列口径)留在各页自己的尺寸常量里,共享值
  一律委托 `RowMetrics`;委托关系有防漂移单测。

**什么时候用**:任何列表行、表头、清单。meter 条宽不随窗宽拉伸,弹窗与主窗口同一节奏。

### 3. 状态芯片

**用途**:行内或大数字旁的一枚状态标签,全 app 唯一实现(`ChipView`)。

**形态与数值**:胶囊;强调色 15% 底 + 同色 semibold 文字;内容之间间距 3;可选的符号与
文字同号同字重;文字单行。

**状态与变体**

- 两形态:`.regular`(11pt,内距 10×3,行内独立元素)与 `.inline`(10.5pt,内距 5×1,
  定宽不换形,挤在名称后面)。
- 语义色由调用方给:正常 `{colors.state-positive}`、危险 `{colors.state-negative}`、
  「先检查」`{colors.state-caution}`、值得留意 `{colors.state-warning}`、页强调色。
- **客观状态用灰**:在用保护、已退出、无权限、安装来源徽标、放电中,这些不是警示,
  一律 `{colors.ink-tertiary}`。
- 安全档是芯片的一种固定用法:可安全清理 = 正面色,先检查 = `{colors.state-caution}`;
  它映射的是删除的安全语义,不是负载警示。
- 高负载的警示(组 CPU 超过一个核)不在行里挂文字芯片:该行数值染负面色 + 名称后一枚
  `.inline` 芯片,写组内 CPU 最高进程的名字(超长中间省略)。
- 芯片本身不接点击;给了提示文案才挂悬停说明。

**什么时候用**:任何「状态 / 类别 / 标签」语义的小标签。芯片里的符号字号随芯片档位,
不取图标五档。

### 4. 指标卡两形态

**用途**:指标概览卡的两个固定版式——放在网格里的小卡,和放在页头的大卡。

**形态与数值**

- **小卡**(放在网格里):主卡头(徽章 + 标题 + 行尾右箭头)→ `{typography.caption}` 11 的一句
  说明 → `{typography.figure-overview}` 34 的大数字 + 状态芯片 → 最多三列统计值 →
  36pt 高的条形走势;段间 12,内距 16。紧凑档换副卡头,大数字 22,说明退到大数字右侧,
  内距 12。各指标同形态,不为某个指标特殊化。
- **大卡**(放在页头):左列 200pt(11pt 说明、`{typography.figure-main}` 44 的大数字、状态
  芯片、2×2 的统计值)+ 右侧撑满的面积走势;卡高 176,内距 16。紧凑档竖排:说明与
  大数字一行、64pt 高的走势、统计值一行;内距 12。
- 大数字只有 `FigureText` 一个实现:圆体加粗、等宽数字、负字距;单位约半号、次级色。

**状态与变体**:全尺寸 / 紧凑两档;同一指标在主窗口与弹窗的读数同一观感。小卡整卡
可点(进入对应页);大卡不可点。图表对无障碍隐藏,数值由统计文字承载。

**什么时候用**:一个指标的「当前值 + 状态 + 构成」概览。更细的构成与排行另起卡片。

### 5. 自适应卡片网格

**用途**:并排卡片的通用排法(`AdaptiveCardGrid` / `AdaptiveCardPair`),容器变窄时自动降列。

**形态与数值**:列数 = 容器实宽容纳得下的最多列;单卡最小宽、列距、列数上限都是参数,
单卡最小宽的默认值是 `{layout.overview-card-min-width}` 340。列数上限设成内容的张数,
卡少的网格不随超宽屏拉成三四列。两卡一组的并排断点是
`{layout.card-pair-two-column-min-width}` 696,不足就上下排、间距 16。

**状态与变体**:并排时**同行等高、顶对齐**,末行不满自动满宽;容器再窄,单列也是 100% 宽。
逐行用横向堆叠实现,不用 `GridItem` 的最小宽(它的下限是硬的,窄容器会被撑出右缘),
也不用惰性网格(行内不拉齐高度)。列数的几何监听挂在网格外层的普通容器上。

**什么时候用**:任何卡片并排;同一行里的卡片一律等高。

### 6. 排行列表

**用途**:「谁最占」的榜单:组排行、模块排行、各页的排行榜同一套卡和行。

**形态与数值**

- 卡:卡内标题(`{typography.card-title}` 12 semibold,页强调色)→ 表头(应用 | 指标名,
  `{typography.micro}` 10.5 medium tertiary,右列对齐数值列)→ 行 → 可选注脚(10.5 tertiary)。
  排行卡不配节标题。
- 行:行首图标、名称(可挂 `.inline` 芯片)、副文、meter 条、数值、行尾列。尺寸全取自
  第 2 条;行尾恒留一列(舒适 30 / 紧凑 24),放结束按钮与展开箭头,所以所有排行的
  meter 与数值在同一条竖线上。
- meter 条:高 6、胶囊;轨道 = 强调色 14%,填充 = 强调色;对无障碍隐藏。
- 截断末行:`{typography.caption}` 11 medium secondary,居中,带上下小箭头;悬停有底。

**状态与变体**

- 两种用法:**组排行**(行可展开,悬停显出结束按钮)与**只读的模块排行**。
- 默认只列前 `{layout.ranking-limit}` 20 名,末行是「显示全部(另 N 项)」;主窗口原地
  展开、可收起,弹窗点了跳主窗口并展开该卡;展开状态按卡记住;搜索命中时不截。
- 空态在卡内。同一前置条件挡住多张排行卡时,收成一条紧凑的引导行(一行高:页强调色
  符号 + 一句说明 + 文字动作),数据到来才展开——展开与否由数据决定,不猜。
- 高负载只标 CPU 口径的行:数值染负面色 + 名称后最忙进程芯片。
- 行容器与主窗口的滚动区一律惰性堆叠(排行常上百行)。

**什么时候用**:按某个口径给对象排序并展示前若干名。表头、数值列、截断末行都复用,
不各写一套。

### 7. 药丸页签条

**用途**:页内切换(`PillTabBar`),tab 是通用组件样式。

**形态与数值**:选中 = 该项强调色 15% 胶囊底 + 同色前景;未选中 = secondary 前景、无底;
药丸间距 4;图标与文字间距 5,图标 `{icons.inline}`。常规档文字 `{typography.body}`
12 medium、内距 9×5;舒适档 14.5 medium、内距 14×8。

**状态与变体**

- 两档尺寸:`.regular`(工具栏、页内小切换)与 `.comfortable`(大一号的子页条)。
- 两种文字形态:`.always`(文字恒显)与 `.selectedOnly`(未选中纯图标,选中才图标 + 文字;
  这时每项必须有图标,并带无障碍标签与提示)。
- 玻璃外裹:放在系统工具栏里由系统自动套玻璃;放在内容页里传 `isGlassContainer`
  自备同款(条外 4pt 内距 + 系统 Liquid Glass 胶囊),不自绘底与影。
- 切换动效 0.2 秒 snappy:选中文字自图标侧展开、胶囊生长、其余药丸滑移让位。

**什么时候用**:指标页签、子页条、范围与粒度这类二选一或几选一的切换。工具栏里的页签
必须按 720 最小窗宽预算,不能触发溢出菜单。

### 8. 页头

**用途**:每个 tab 顶部的标题行(`PageHeader`),主窗口与弹窗同一出处。

**形态与数值**:标题一行 + 可选副标题一行(行距 `{spacing.micro}` 2)+ 右侧配件槽。
全尺寸档标题 `{typography.page-title}` 26 bold、副标题 `{typography.body}` 12 secondary;
紧凑档两行皆 11 secondary。

**状态与变体**

- 每个 tab 恰一个标题:页内的卡片、子页不得再画与页名同级的大标题。
- 配件槽里放动作按钮、扫描状态、运行时长。主窗口的配件槽里有**告警小条**:单行
  「铃铛 + 首条标题(多条时『… 等 N 项』)」,12 semibold、警示色 12% 底、`{rounded.inner}`
  10 圆角;明细与归因进悬停;告警的出现与消失不推动下方内容。弹窗的告警走底部横幅。
- 页头的高度优先级高于内容区:窗口再矮,先挤内容,不截标题。

**什么时候用**:任何 tab、任何子页的顶部。标题只在页头出现一次;副标题按页给,
只有总览页带「本机一行」。

### 9. 菜单栏徽标

**用途**:菜单栏上的读数位图,一个状态项里并排 1–4 枚。

**形态与数值**:一次离屏渲染合成**单张**位图(多张图系统只画第一张),原样交给状态项
——系统会剥掉 SwiftUI 前景色,只有位图保得住颜色。每枚 = 小标签(7pt semibold,
55% 墨色)+ 数值(11.5pt medium,等宽数字);上下行叠放版式不带标签,两行 9pt medium;
枚与枚之间间距 5。数值槽按各指标最宽的现实读数定宽、数字左对齐,状态项宽度不随读数
抖动。

**状态与变体**

- 墨色随外观(深色白、浅色黑)。强调级三级:正常 = 墨色;偏高 = `{colors.state-warning}`;
  危险 = `{colors.state-negative}`。位图里的深浅值按当次传入的外观解析。
- 读数有 2 个百分点的死区:死区内不换数字,越红线立即换——防抖而不迟钝。
- 缓存键 = 外观 + 全部内容(文案、强调级、版式、定宽槽、顺序),任何一项变化都重渲染;
  缓存有界。
- 字号与配色自成一组,只用于菜单栏位图,不外溢到窗口;窗口的五档与图标档位也不带进来。

**什么时候用**:只有菜单栏状态项。徽标的字号与版式是 `NSStatusItem` 尺寸约束下的独立档。

### 10. 迷你走势图

**用途**:卡内「最近一段时间的形状」,两件都是自绘的 Canvas,无轴无标签。

**形态与数值**

- **面积走势图**(`AreaTrendChartView`):56 个点、线宽 2pt 强调色、线下渐变 32%→0、
  4 条 8% 的网格线、左端 2% 垫底。
- **条形走势图**(`StripChartView`):44 根柱、柱距 2、上缘圆角 2,轨道 = 强调色 9%。

**状态与变体**:面积走势图带悬停读数(见第 14 条):竖线贴吸附点 + 浮层;时刻轴与数值
同环同长时才启用,左端垫底的假点槽不出读数,轴缺失或长度不齐就安静收起。
条形走势图是氛围件,不查数,不做悬停。

**什么时候用**:卡内的概览走势。高度由所在卡给;两件都对无障碍隐藏,数值由卡上的文字承载。

### 11. 面包屑

**用途**:表示「现在在哪一层」并逐级返回的路径栏。

**形态与数值**:层级文字 `{typography.caption}` 11,层级之间用 `›`(tertiary)分隔。
非末级的层级是可点的文字按钮(secondary),点了跳到那一层;末级加粗,不可点。
路径栏末尾不挂任何按钮——前面带分隔符的按钮会被读成下一层。

**状态与变体**:层级链由数据模型按路径给出,路径不在树里时不猜、不画。下钻位置由
页面的状态持有,切 tab、切展示形态都不丢。

**什么时候用**:任何有层级的下钻导航。返回上一层点上一级,回顶层点第一级。

### 12. 搜索框

**用途**:列表与工具栏里的过滤输入。放大镜 + 无边框输入框 + 清空按钮,按宿主分两种版式。

**形态与数值**:放大镜(`{icons.inline}`,secondary)+ 无边框输入框(`{typography.body}`
12)+ 有内容时出现的清空按钮(`{icons.inline}`,secondary,带悬停提示与无障碍标签);
底 = `primary` 6%、左右内距 8。

**状态与变体**

- **页面内版**:定高 24(与同排的分段控件等高),`{rounded.chip}` 8 圆角,宽度随容器。
- **工具栏版**:占宽 132 = 左侧留白 `{spacing.inline}` 6 + 胶囊 126(系统工具栏玻璃组底不给自定义项左内距,自留);
  空间不够时输入框先收窄,文字单行尾截「…」;⌘F 聚焦。
- 按 Esc 清空;工具栏版内容为空时再按 Esc 失焦,清空后焦点留在框里。

**什么时候用**:过滤一组列表。不用系统带边框的搜索样式:它的高度与分段控件对不齐。

### 13. 勾选框

**用途**:自绘的勾选框,替代系统控件,全 app 一套。

**形态与数值**:20×20、圆角 5、描边 1.5。关 = `{colors.ink-tertiary}` 描边空心;
开 = 强调色填充 + 白色对勾;半选 = 强调色填充 + 白色横线;对勾与横线 `{icons.inline}` bold。

**状态与变体**

- 三态:关 / 开 / 半选。半选只用在「一行管一组」的卡头。禁用时 40% 透明。
  着色由调用方给,默认 `{colors.accent-clean}`;破坏性场景取 `{colors.state-negative}`。
- 纯显示件:点击语义在宿主行——整行可点即勾选;勾选框本身对无障碍隐藏,由宿主行
  宣布「已勾选 / 部分勾选 / 未勾选」,避免重复朗读。
- 卡头的三态勾选框:半选 = 组里只勾了一部分;点它只全选或全清组里**可安全清理且不在用**
  的项;组里没有可勾的项时置灰,不给假按钮。
- 多级清单里,只全选安全档的那一级用文字按钮(「全选安全项」,见第 15 条),不设勾选框;
  勾选框只用在条目行和「一行管一组」的卡头。

**什么时候用**:清单里的逐行勾选,以及「一行管一组」的卡头。状态如实反映所有子项,
动作只作用于安全档。

### 14. 图表悬停读数与浮层

**用途**:图表上悬停时的读数:一条贴在数据点上的竖线,加一个小浮层。

**形态与数值**:悬停位置一律用坐标反算,不依赖形状的点击测试。竖线贴**吸附到的数据点**
而不是光标:空桶吸最近的有效点,等距取更早的;竖线 1pt、图表色 70%。
浮层(`AgentChartTooltip`):第一行微字号的时刻或名称(secondary,等宽数字),第二行
8×8 圆角 2 的色块 + `{typography.body}` 12 semibold 的读数(等宽数字);系统材质底、
`{rounded.chip}` 8 圆角、内距 6×8;不接鼠标。

**状态与变体**

- 定位:锚在被命中数据点的正上方居中、间距 6;上方放不下翻到下方;上下都没空间时
  侧放(整列命中的周视图)。水平方向钳在图内;首帧还没量到浮层尺寸时不显示。
- 浮层可在读数下追加一块 2×2 的四格明细(有分项数据时才有):标签 10.5 tertiary、
  值 11 semibold、等宽数字。
- 读数自带口径与单位,不出裸数字。时刻取吸附点自己的时刻,不取鼠标的瞬时位置。
- 切换粒度或数据范围时清掉悬停态。

**什么时候用**:历史页的曲线、智能体页的热力墙与走势图、指标页主卡的面积走势图。
空间地图的悬停读数是同一思路的就地版本:读数画在旭日的中心圈里,不另起浮层。

### 15. 卡头文字按钮

**用途**:卡头右侧的次要动作,低存在感的文字按钮。

**形态与数值**:无边框(`borderless`)、`{typography.body}` 12 semibold、secondary 前景;
可带一个前置的系统符号。不用带边框的系统小按钮。

**状态与变体**

- 进行中换成小号转圈 + 状态文案并禁用;不可用时隐藏或置灰。
- 返回上一级的文字(如「‹ 总览」)用页强调色,不用 secondary。

**什么时候用**:卡头或组头上的「重新扫描」「在 Finder 中显示」「全选安全项」这类次要
动作。页里的主行动作用带底色的强调按钮;浮在图表上的胶囊按钮、行尾的图标按钮各是
别的件,不用它。

### 16. 设置侧栏图标砖

**用途**:设置窗侧栏每个设置页前面的彩色图标。

**形态与数值**:26×26、`{rounded.chip}` 8 圆角;底 = 从左上到右下的线性渐变,起止色取
`{colors.settings-icon-*-from}` / `-to`(固定色,不随明暗切换,每页一对);上面是白色
系统符号 13pt semibold,符号带一层很淡的柔影;砖的外缘有 0.5pt 的白色高光描边,
底下一点柔影。仿系统设置的侧栏图标。

**状态与变体**:没有选中态与交互——它是装饰件,对无障碍隐藏,可访问性标签由旁边的
页名文字承担。

**什么时候用**:只有设置窗的侧栏。它是全 app 唯一带投影与高光描边的界面件(见
§Elevation & Depth),不加进其它页面;新增设置页时在页清单里登记一对渐变色。

## Do's and Don'ts

**Do**

- 新视图先查本文件和所在页的页面规格;数值不在令牌表里 = 先补表再写码。
- 数字一律 `monospacedDigit()`;颜色一律语义键;圆角与内距一律查表;文字只取五档,
  图标只取五档。
- 新的通用界面件先在 §Components 立规范,再实现。某一页的实现细节写在该页代码旁,
  不进本文件。
- 用户可见的新形态:实机验收交给用户(代理不循环截图),机械断言进单测或 lint。

**Don't**

- 不直写 `Color.orange` / `.red` 或十六进制色;不给卡片、容器加投影或描边;不引
  第三方 UI、图表、字体库。
- 不把窗口 UI 的规格带进菜单栏位图,反之亦然。
- 不用系统自带的语义字体(`.caption` 等)。
- 规范与页面规格里已定的样式不静默改,要改先问用户。
- 工具栏不做会触发溢出菜单的加项(720 窗宽预算的优先级高于功能堆叠)。
- 不在本文件记日期、工单号和改版经过,也不在代码注释里写历史:来历在提交记录
  和票里。
