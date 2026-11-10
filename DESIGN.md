---
version: 1.1
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
typography:
  font: "SF Pro(系统默认,不引第三方字体)"
  figure-overview: "34pt bold rounded, tabular"
  figure-main: "44pt bold rounded, tabular"
  figure-main-compact: "30pt bold rounded, tabular"
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
  row-name: "14.5pt medium(舒适)/ 12pt(紧凑)——行名称与数值同号,层级靠字重"
  row-value: "14.5pt semibold(舒适)/ 12pt semibold(紧凑)+ monospacedDigit"
  row-sub: "12pt(舒适)/ 10.5pt(紧凑)"
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
  page-header: "页头(主窗口 / 弹窗 / 清理页统一组件),见 §Components"
  row-metrics: "列表行两档制单一出处(紧凑=弹窗 / 舒适=主窗口一切列表行),见 §Components"
  chip: "统一状态 chip(ChipView,两形态),见 §Components"
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
| `{colors.state-caution}` | `Surface.caution` | 清理档位「先检查」chip(p4-uninstaller/08 立项:清理页 accent 即磁盘金,warning 别名与它全页撞色,故独立琥珀橙;不用于负载/告警) |
| `{colors.accent-clean}` | `Surface.cleanAccent` | 清理页专属强调(2026-11-06 用户拍板 Teal;此前借磁盘金被评丑、指标色是 tab 身份色不跨页借):清理页主按钮 / 排序选中段 / 勾选框选中 / 选中条目卡底 / 子页药丸统一取此 |
| `{colors.category-*}` | `GroupCategory.identityColor` | 非 App 组的图标瓦片底色;孤儿另作组行强调色(见下) |
| `{colors.junk-*}` | `JunkGroup.identityColor`(MetricAccent.swift) | 清理品类身份色(p6-cleaner/03,丙案 v2 原型拍板映射):dev=CPU 蓝 / browser=GPU 粉 / app=App 棕 / project=内存紫 / ai=蓝牙青 / leftover=传感器橙红 / trash=磁盘金——清理总览模块大卡图标瓦与图例的类别底色。同空间地图按序循环 `accent-*` 的先例:指标色在此作**类别身份**借用,不作页面强调(清理页强调仍只有 accent-clean) |
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
  组排行行的高负载警示 = 行尾 CPU 数值红字 + 名称后最忙进程名 chip(见 §Components
  排行列表,2026-10-30 用户拍板),色取 `{colors.state-negative}`。
- 菜单栏位图颜色只能经 ImageRenderer 预绘(`.renderingMode(.original)`);
  NSStatusItem 会剥掉 SwiftUI 前景色,这是实测结论不是风格偏好。

## Typography

| 角色 | 规格 | 用在哪 |
|---|---|---|
| `{typography.figure-main}` | 44pt bold `.rounded` + `monospacedDigit` | 指标 tab 主卡大数字 |
| `{typography.figure-overview}` | 34pt bold `.rounded` + `monospacedDigit` | 总览卡大数字(单位半号 48%) |
| `{typography.figure-main-compact}` | 30pt(同族) | 弹窗主卡大数字 |
| `{typography.figure-card}` | 24pt(同族) | 清理总览模块大卡大数字(`FigureSize.card`,p6-cleaner/03;原型 24 原值入表) |
| `{typography.figure-overview-compact}` | 22pt(同族) | 弹窗总览卡大数字 |
| `{typography.figure-ring}` / `-compact` | 19 / 16pt(同族) | 环心数字(全尺寸 / 弹窗) |
| `{typography.page-title}` | 26pt bold | 主窗口页名 |
| `{typography.section-title}` | 17pt bold | 节标题("此刻"/"当前最忙") |
| `{typography.figure-mini}` | 17pt semibold `.rounded` + `monospacedDigit` | 历史页均值/峰值等次级数字 |
| `{typography.card-title}` | 12pt semibold,指标色 | 卡片标题行 |
| `{typography.body}` | 12pt | 统计数值(semibold + `monospacedDigit`)、正文 |
| `{typography.caption}` | 11pt | 说明、表头、次级标签 |
| `{typography.micro}` | 10.5pt | 统计列标签、最密排注 |
| `{typography.row-name}` | 14.5pt medium(舒适)/ 12pt(紧凑) | 列表行名称(主窗口一切列表行 / 弹窗) |
| `{typography.row-value}` | 14.5pt semibold(舒适)/ 12pt(紧凑) | 列表行数值(定宽列 + `monospacedDigit`) |
| `{typography.row-sub}` | 12pt(舒适)/ 10.5pt(紧凑) | 列表行副文、路径 |

规则:
- **窗口 UI 文字只有五档**(ui-unify/01,2026-11-08 用户拍板"字号、组件都归一"):
  10.5 / 11 / 12 / 14.5 / 17 + 大数字族(FigureSize)。此前 8.5~17 共 12 档
  (11.5 / 12.5 / 13 / 13.5 / 14 / 16 已全量收编,映射见 §已知偏差)。新文字
  不在五档内 = 先改本表再写码;列表行尺寸单一出处 `RowMetrics`(两档制,见
  §Components 行两档制)。
- **一切数字**读数(百分比、字节、速率、PID)必须 `monospacedDigit()`;
  大数字另加 `.rounded` 设计族与负字距(`FigureText` 是唯一实现,不要复刻;字号只取
  `FigureSize` 令牌)。统计值(标签 + 数字)不是大数字:`{typography.body}` 12 semibold
  等宽,不走圆体(`StatValue` 是唯一实现)。卡内明细行的数值(名称 + meter + 数值行)
  是 `{typography.body}` 12 **常规** + `monospacedDigit`(`CardRowValue` 是唯一实现,
  p2-review/03)。
- 不用整体等宽字形 `design: .monospaced`(SF Mono)——数字对齐只靠 `monospacedDigit`;
  确需等宽字形的非数字内容须先在此登记例外。**登记例外(ui-unify/01)**:清理页
  文件路径行(卸载残留 / 确认清单,11pt `.monospaced`)——同名 node_modules/build
  靠路径区分,等宽有可辨识度价值;空间地图块内百分比小标(10.5pt `.monospaced`)。
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
| `{layout.row-value-rssi}` | 32pt | ~~同上:信号强度 `-99 dBm` / `—`(蓝牙设备行)~~ **superseded**(ui-unify 追改 2026-11-09):RSSI 改走行副文,不再是数值列 |
| `{layout.row-meter-compact}` | 44pt | ~~行内电量条宽(紧凑档,蓝牙设备行)~~ **superseded**(ui-unify 追改 2026-11-09)→ `RowMetrics.meterWidth` 52 |
| `{layout.row-meter}` | 64pt | ~~行内电量条宽(全尺寸档,蓝牙设备行)~~ **superseded**(ui-unify 追改 2026-11-09)→ `RowMetrics.meterWidth` 120 |
| `{layout.row-host-icon}` | 14pt | 下钻进程行宿主 App 徽标图标边长(project-visibility/02;徽标文字随行 `{typography.caption}` secondary,图标-文字间距 `{spacing.inline}`) |
| `{layout.overview-card-min-width}` | 340pt | 总览卡自适应网格的单卡最小宽(主窗口列数 1–4 由它派生:列数 = 内容宽容纳的最多列,340 + 列距 16,上限 4) |
| `{layout.module-card-min-width}` | 340pt | 清理总览模块大卡自适应网格的单卡最小宽(p6-cleaner/03):列数 = min(2, 内容宽容纳列数)——720 最小窗 1 列、默认窗 880 起 2 列、**上限 2 列**(品类只有六卡,不随 ultrawide 拉列);列距 `{spacing.group-gap}` 12 |
| `{layout.ranking-limit}` | 20 行 | 各排行(弹窗与主窗口同规则)只列前 20 名,超出补末行:弹窗「查看全部(另 N 项)」跳主窗口并落地即展开,主窗口「显示全部(另 N 项)」原地展开 / 「收起」(ranking-limit/01,2026-11-02 用户拍板;原 11-01 `popover-ranking-limit` 只截弹窗)。主窗口搜索命中不截 |
| `{layout.sheet-width}` | 460pt | 确认清单 sheet 定宽(清理页「清理…」,p4-cleaner/04;原型 B 变体同值) |
| `{layout.sheet-list-max-height}` | 220pt | 确认清单 sheet 内逐行列表的最大高(超出滚动,总量与按钮恒在视口内) |
| `{layout.spacemap-chart-min-height}` | 220pt | 空间地图**方块形态**图表区最小高(≈滚动容器内实际高,见组件行注):220 = 主窗口最小高 560 下整页仍放得下的底线(ui-unify 追改 2026-11-09;space-map-forms/01 入表) |
| `{layout.sunburst-diameter}` | ~~400pt~~ | **superseded**(space-map-forms/04):旭日改为方形铺满卡宽,直径 = 卡内容宽,无固定值——340(01)与 400(03)两代固定直径分别被 220 最小高压制 / 宽卡里只占中间一点,均废;几何在 PulseCore `SunburstLayout`(p4-cleaner/07) |
| `{layout.spacemap-sunburst-min-side}` | 360pt | 旭日方形边长下限(space-map-forms/05):窄窗防过小;宽窗边长 = 卡宽铺满(高随宽、居中,onGeometryChange 测宽回写);宽度下限由主窗口最小宽 720 保障 |
| `{layout.popover-size}` | 360×648pt | 菜单栏弹窗面板**定尺寸**(`DashboardView.panelSize`;popover-header/01 用户拍板 A,2026-11-02):AppKit 面板直接按此开窗、不读内容 fittingSize;中间滚动区 `maxHeight: .infinity` 吃掉头尾之外的全部高度——tab 栏 / 页头钉顶、底排钉底,告警横幅出没只挤中间,切 tab 面板不动 |

窗口:主窗口最小 **720×560**(spec 钉死),默认 880×620;弹窗面板 **360×648 定尺寸**
(`{layout.popover-size}`,内容撑满、不随内容伸缩)。工具栏内容必须按 720 最小窗宽预算(见 §Do's and Don'ts)。
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

**总规矩(2026-11-10 用户拍板「以后都应该使用这些标准组件」):新 UI 一律优先
组装本节标准件;标准件覆盖不了的形态,先补本表再造,不私开同义新件。**

- **卡片家族零件**(arch-review-2026-10-18/02 中4,`Pulse/Views/CardFamily.swift`):卡壳
  `cardShell(compact:)`(底色 + 圆角 + 内距,两档;`padded: false` 只给内距随版式
  变化、自己排内距的卡用——总览卡 16/12、指标主卡 20/12)、主卡头 `CardHeader`(22pt 徽章 +
  card-title 指标色)、副卡头 `CardSubHeader`(10.5pt 指标色符号 + **12 semibold 指标色标题** +
  10.5 tertiary 等宽注记;标题升彩色 12 semibold = ui-unify 追改 2026-11-09——卡头即卡片身份,
  灰标题让 P2 批次卡与排行卡不同族)、统计值 `StatValue`、卡内空态 `CardEmptyState`(12.5 medium secondary 一句 +
  10.5 tertiary 说明,居中;可带一个 11pt `.link` 动作——授权型能力卡的开启 / 授权 /
  去系统设置,与告警横幅降级出口同款,其余空态不配按钮)、卡内明细行数值 `CardRowValue`
  (默认 12 常规 `monospacedDigit` 右对齐;**尺寸随所在行走 RowMetrics 两档**——舒适档行传
  14.5 semibold,紧凑档 12;最小宽取 `{layout.row-value-*}` 令牌即 `CardRowWidth`;标签列定宽取
  `{layout.row-label*}`)、**卡内实体行 `CardEntityRow`**(ui-unify 追改 2026-11-09:行首类型
  图标 + 名称 + 可选副文 + 尾部自定义列,尺寸全走 RowMetrics 两档;图标色由调用方给——
  活跃态取所在页指标色、非活跃 `{colors.state-inactive}`,代替 6pt 状态圆点)。
  **新卡一律组装这些零件,
  不再手写卡壳 / 卡头 / 空态。**

- **卡内行两形态边界**(ui-unify 追改 2026-11-09,用户第二次问"到底有没有设计原则"后立规):
  P2 批次明细卡(外设 / 容器 / 传感器 / 五路功率 / 磁盘明细 / 网络累计 / 开发服务)的行与
  排行 / 清理的列表行**同一语言**,按内容分两形态:
  **实体行**(行描述一台设备 / 一个对象:蓝牙设备、输出设备、容器、dev server)= `CardEntityRow`,
  图标 + 名称 + 副文(RSSI、pid、路径等弱信号),尾部数值列 / meter;
  **读数行**(行描述一个测量:派生温度、风扇、功率域、卷占用、流量累计)= 标签列(定宽
  `{layout.row-label*}`)+ meter(`RowMetrics.meterWidth`)+ `CardRowValue` 数值。
  两形态字号一律 RowMetrics 两档(舒适 14.5 / 紧凑 12),不再用 P2 时代的 12pt 全档小字。
  **未知值安静原则**:逐行状态类未知(设备电量读不到)整块留空,不写"未知 / —"文案占位;
  数值列里的未知读数(容器 CPU 无样本)仍写"—"——那是表格的诚实单元格,不是状态提示。
  meter 条宽一律 `RowMetrics.meterWidth`(120 / 52),不随窗宽拉伸——弹窗与主窗口同一节奏。

- **行两档制 RowMetrics**(ui-unify/01,2026-11-08 用户拍板"功能相似组件长一个样",
  `Pulse/Views/RowMetrics.swift`):全 app **列表行**共享值的单一出处——紧凑档(弹窗)/
  舒适档(主窗口一切列表行:排行 / 清理 / sheet 清单)。字号 = 名称与数值**同号**
  (14.5 / 12,层级靠字重 medium vs semibold)、副文 12 / 10.5;图标 24 / 18;
  meter 120 / 52;行内距 14×10(舒适)/ 6×5(紧凑)。`RankingListMetrics` 与
  `CleanerListMetrics` 只留页面专属参数(行尾列 / 数值列口径 / 缩进 / 勾选框),
  共享值一律委托此处,委托关系有防漂移单测钉死(UiUnifyRowMetricsTests)。
  菜单栏位图不在两档制内(尺寸特例,见上)。

- **统一状态 chip ChipView**(ui-unify/01,`Pulse/Views/ChipView.swift`):胶囊、
  tint 15% 底 + 同色文字、semibold,全 app 唯一实现。两形态:`.regular`(11pt,
  内距 10×3,行内独立元素)/ `.inline`(10.5pt,内距 5×1,定宽不换形,挤在名称后)。
  此前六种手写(HotProcessChip / TierChip / InUseChip / StateChip / BrewChip /
  MetricChipView)字号 10~11.5、内距 5×1~10×3 互相漂移,已全部收编为 ChipView
  薄封装;语义 tint 由调用方给(positive / negative / caution / inkTertiary / 指标色)。

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
  行 = 图标 22→**24** / 名称 13→**14.5 medium**(可挂徽章)/ 副文 10.5→**12 secondary** /
  meter 110→**120 榜首归一** / 数值 13→**14.5 semibold** `monospacedDigit` **定宽列**
  (尺寸全走 `RowMetrics` 舒适档,ui-unify/01 排行升舒适档;按口径最宽现实读数量宽 + 2:组排行
  `.standard` = `9999%` / `99.9 GB` / `999 MB`,模块排行 `.rate` = `999.9 MB/s`;同卡各行同宽,
  不许按内容撑宽——速率文案会逐行撑出不同宽度。2026-10-30 用户反馈:组排行共用速率宽时
  CPU 读数右对齐、meter 与数字隔一大截且挤窄名称区,遂分两口径)/ **行尾恒留 30pt 列**(组排行放结束按钮 +
  展开箭头,模块排行留空)——所有排行的 meter 与数值在同一竖线上。组排行行高负载警示
  (组 CPU > 100%,阈值 `StatusBadgeRules` 同源)= **该行 CPU 数值 `{colors.state-negative}`
  红字**(无描边)+ **名称后挂最忙进程 chip**(`HotProcessChip`,靠名称区最右贴 meter:状态 chip 配方,
  state-negative 14% 底 + 同色字,只写组内 CPU 最高进程的显示名、无图标,10 / 10.5
  semibold,按字数封顶 18(超出中间省略)、自身不压缩;组名吃剩余宽度尾部省略);仅 CPU 口径行,内存口径行不标(2026-10-30
  用户拍板 B:要一眼看出"哪个进程在吃";此前 2026-10-26 的"高负载"文字 chip 与
  数值圈红均已撤)。紧凑档(弹窗):
  图标 18、名称 12.5→**12**、**数值 11.5→12**(同号,层级靠字重;数值列同法按 12pt 量宽)、meter 52 贴右、
  **名称区→meter→数值→行尾列间距均 4**(名称区吃满剩余宽度)、**行尾列 24 = 结束按钮 14 + 0 + 箭头 10**
  (2026-10-30 用户拍板收紧;全尺寸档仍 10 / 30 = 18 + 2 + 10)、行内距 5;卡 `{rounded.card-compact}` 12
  + `{spacing.card-padding-compact}` 12;全尺寸卡 `{rounded.card}` 18 + `{spacing.card-padding}` 16。
  排行卡不配节标题(主窗口也不配「当前最忙」节标题)。
  **meter 条宽度无过渡动画**(读数到即重画;2026-10-29 用户拍板「体感不到的东西不应该
  存在」——0.6s 缓动让面板开期 CPU 36.5% vs 无动画 8.4%,popover-layout-loop/01)。
  **行容器与主窗口滚动区一律 `LazyVStack`**(2026-10-30 popover-appkit/10 实测:排行常上百行,
  普通 VStack 全建 → 弹窗开期鼠标移动 ~33% / 滚动 ~41%,惰性后 ~7% / ~25%;不得退回 VStack)。
  **排行截断(两处同规则)**:各排行只列前 `{layout.ranking-limit}` 20 名,末行 `RankingOverflowRow`
  (`{typography.caption}` 11 medium secondary + chevron,居中,悬停底同排行行)按宿主处理溢出——
  弹窗「查看全部(另 N 项)›」跳主窗口并落地即展开该卡;主窗口「显示全部(另 N 项)⌄」原地展开,
  展开后「收起,只看前 20 名⌃」;展开态按卡 id 存 `DashboardModel.expandedRankingIDs`(切 tab 回前 20);
  主窗口搜索命中不截。上限与末行行为单一出处 `RankingOverflow`,卡壳 `RankingListCard` 统一画末行
  (ranking-limit/01,用户拍板 2026-11-02「直接经验复用,和弹窗一致」;11-01 popover-top20 只截弹窗)。
  **弹窗滚动区是通用原生列表 `NativeList`**(2026-10-31 native-list,用户拍板):AppKit NSTableView
  承载 SwiftUI 行——行视图按 kind 复用、行高缓存(排行行同 kind 量一次,卡片 / 展开行按 key 量)、
  结构不变只换可见行内容、行宿主不参与键盘焦点链;卡片序列出自 `MetricTabStack.blocks`,排行拆卡头 /
  每行 / 卡尾(`RankingListSlices`)。`popover.nativeList = NO` 回退到下述 List。
  (回退形态)**弹窗滚动区 `List`**(2026-10-31 popover-list):每张卡一个 List 行,排行卡经
  环境值 `rankingRowsInList` 拆成卡头 / 每行 / 卡尾各一行,底色按段 `cardSlice` 切开拼回整卡
  (真机触控板滚动 LazyVStack 36–43%,sample 一半在每帧重出绘制指令、四分之一在重布局)。
  卡外 8pt 间距 = 首尾段底色外各 4 透明边,不用 listRowInsets 的 bottom(macOS 上被忽略)。
- **清理页子页命名**:五个子药丸 = **「总览 | 全部清单 | 空间地图 | 应用 | 清理历史」**
  (p6-cleaner/03,丙案 v2;总览居首且为默认落地子页)。清单子页标题 = **「全部清单」**
  (2026-11-08 首改名「开发者垃圾」→「可清理」;p6-cleaner/03 再改「全部清单」——总览
  已承担"能回收多少"的第一眼,清单页名回归"它是什么:一张全量清单";组名不变;内部标识
  `CleanerSubTab.junk` 两次都不动,改名只是文案层,先例 p4-uninstaller/08)。
- **清理总览页**(p6-cleaner/03,丙案 v2;原型 = `prototype/cleaner-reorg` 分支的
  `cleaner-reorg-plan-c.html`,数值以本条为准——原型非 4pt 网格值在此收编):
  Hero 卡 + 模块大卡 2 列自适应 + 废纸篓卡,页内整页滚动。
  - **Hero 卡**:内距 24(上下)×28(左右)(原型 26×28 收 4pt 网格)、圆角
    `{rounded.card}`;大数字 `{typography.figure-main}` 44(原型 52 收 FigureSize 族
    既有最大档)+ caption 12「可回收 · 其中 X 可放心清」(X 染 `{colors.state-positive}`);
    构成条高 8 圆角 4,三段 = safe `{colors.state-positive}` / check `{colors.state-caution}` /
    inuse `{colors.ink-tertiary}`(段宽按三段合计归一,inuse 段最小可见宽 2%、为 0 不画);
    图例 11(统一配方见下):可安全清理 / 先检查 / 在用保护 / **「另有废纸篓 X」**
    (色块 `{colors.junk-trash}` 磁盘金;X 读不到 / 没查如实写「—」,不写 0);主按钮
    「一键清理 X 安全项…」(accent-clean、
    `.large` borderedProminent;X = safe 合计;一键 = 全选全部 safe 且**非在用**候选 →
    既有确认单,默认勾选仍全不勾,「先检查」与在用项永不在内)。
  - **图例统一配方**(p6-review-fixes 收编:Hero / 模块大卡 / 废纸篓卡三处同一
    `OverviewLegendItem`,此前三副本参数漂移——色块 8×8 r2.5 / 7×7 r2、块字距
    5 / 4、项间 14、Hero 条-图例纵距 7 全不在 4pt 网格):文字 11 secondary +
    `monospacedDigit`;色块 8×8 圆角 2.5;色块-文字 `{spacing.unit}` 4;图例项间
    `{spacing.group-gap}` 12;Hero 构成条与图例纵向 `{spacing.gap}` 8。
  - **模块大卡**(六品类 + 废纸篓共七张):2 列自适应(`{layout.module-card-min-width}`
    340、列距 12、上限 2 列);卡壳走 `cardShell` 全尺寸档(内距 16——原型 18×20 收编到
    零件档,不另立卡壳);图标瓦 42pt(`CategoryIconTile` size 42、圆角随组件公式
    size×0.24;类别身份色 `{colors.junk-*}` + 白符号);类名 `{typography.section-title}`
    17 bold(原型 16 收五档)+ 一句人话 11 secondary(文案蓝本 = 原型);大数字
    `{typography.figure-card}` 24;卡内构成条高 7 圆角 3.5(同三段色,空段不画、
    inuse>0 最小可见宽 3%);图例 11(统一配方,见上):可安全清理 X / 先检查 X
    (>0 才显)/ 在用 X
    (>0 才显)/ N 项;「最大一项:名称 · 大小」行(顶部分隔线 + 上距 10,11,
    名称 semibold primary)+ 右缘 chevron;**整卡可点 = 下钻**全部清单按品类过滤。
    空组不出卡(该品类候选为空自然缺位,不硬造)。下钻空态(该品类被过滤后无
    条目)走 `CardEmptyState`(与全量空态同族,p6-review-fixes 收编裸 Text)。
  - **废纸篓卡**(变体,非白名单候选):无构成条;读数大数字同 24 档 + 「N 项」
    (多卷才显「所有卷汇总」);独立「清空废纸篓…」按钮(普通 bordered、B 档;复用
    `beginEmptyTrash` → 二次确认流,p6-cleaner/03 自页头迁来,页头原按钮撤除);
    点卡不下钻。**读数四态**(p6-review-fixes;读不到 ≠ 空,只有查到了才出数字):
    没查 = 读数位给「清点废纸篓」(11pt `.link`,卡片家族授权型能力动作同款)+ 副文
    「尚未清点」;清点中 = 小号转圈 + 「正在清点…」(刷新时有上次读数则继续显示
    数字,不闪占位);读不到 = 「重试清点」+ 副文「读不到(权限不足或宗卷不可用)」,
    不出 0,Hero 图例同步写「—」;查到了 = 大数字 + 「N 项」。**进页不自动清点**:
    清点要枚举外置宗卷的废纸篓,可能弹系统授权——首次读数只来自用户点击(「清点
    废纸篓」或「清空废纸篓…」),本次打开期间清点成功过之后进页才自动刷新,读失败
    后不自动重试(CODING_STANDARDS 权限纪律)。
  - **下钻**:全部清单顶部「‹ 总览」返回行(12 accent 文字按钮 + 品类标题 17 bold +
    「X · N 项」12 secondary + 「全选安全项」)+ 该品类条目(行形态零新,继续
    RowMetrics / CleanerListMetrics 与项目大卡既有形态);总览↔清单切换不丢勾选
    (勾选在 `CleanerModel.selection`,模型层天然保持);返回 / 药丸直切 = 回总览并清过滤。
- **清理页舒适密度档**(2026-11-05 用户拍板,原型三档裁决:行 = A 档,按钮与
  segmented = B 档,行左右内距加大;参考竞品 Purge 后全页从排行紧凑档升密度;
  **ui-unify/01 起共享值改由 `RowMetrics` 舒适档单一出处**,与排行页同档同源):
  清理页四子页(垃圾/应用/历史/地图周边)的行与控件,页面专属尺寸出处仍是
  `CleanerListMetrics`(`CleanerJunkViews.swift`,委托 RowMetrics):行 = 图标
  28→**24** / 名称 14.5 medium + 副文 12 secondary / meter 130→**120 榜首归一** /
  数值 14.5 semibold 等宽**定宽列**(同法按 14.5pt 量最宽现实读数 "999.9 GB" + 2)/
  行内距 14(左右)×**10(上下)** / 勾选框 `.controlSize(.large)`;安全档 chip =
  `ChipView.regular`(11 semibold、内距 10×3);
  组头 14.5 bold + 总量 12;子页 tab 药丸 = `PillTabBar.comfortable`;**动作按钮与
  「大小|新旧」segmented 一律 B 档**(按钮 `.controlSize(.large)`、seg 默认 regular
  不再 mini);项目子组行 = 14.5 bold、上下距 10、**无背景**(权重靠字号与内距)。
  **勾选框 = 自绘 `CleanerCheckBox`**(2026-11-05 用户实报系统大号 checkbox 不好看,
  且此前垃圾页系统框 / 应用页 SF 方块两套并存):20×20 圆角 5、描边 1.5——
  off = 三级墨色描边空心,on = tint 填充 + 白 checkmark,半选(项目行)= tint
  填充 + 白 minus,禁用 40% 透明;destructive 场景(彻底删除)tint 取
  `{colors.state-negative}`。纯显示件,点击语义在宿主行:整行可点即勾,
  项目行点行 = 全选/全清该项目安全产物,收起/展开只归箭头按钮。
  **2026-11-06 二次改版**:条目 = 小卡(`{colors.surface-card-high}` 底、
  `{rounded.card-compact}` 12、卡间距 4、内距 14×14;选中 = accent-clean 12% 染底);
  组头标题 16 bold + 总量在左,右侧 = 「全选安全项」+ 大小|新旧 seg(seg tint
  accent-clean);组与组之间 18;清理页强调色 = `{colors.accent-clean}`,主窗口
  工具栏清理 tab 同色(app 层覆写,PulseCore Metric 色表不动)。
  **项目子组 = 一张大卡包含子项**(同日三次拍板:「项目产物应该是一个大卡片,
  包含住子项!子项只有缩进!」):项目大卡(card-hi、12 圆角)装头排 + 全部产物
  子项;子项是**卡内裸行**——只缩进 28、无小卡底(选中 = 强调色 10% 行底),
  与工具缓存组的独立小卡两形态并存。点头排 = 展开/收起(右缘 chevron,默认展开)。
  勾选两层口径(同日连续拍板):状态 = 反映全部非在用子项(手勾的「先检查」也让
  父级如实半选/全选);动作 = 只全选/全清**安全档**子项,没有安全项可勾(纯先检查)
  时 checkbox 置灰不给假按钮;全在用 → 勾选位换锁;组头「全选安全项」同口径。
  **候选不过滤亚兆条目**(2026-11-06 用户拍板:0 KB 的产物也是该清的东西,
  照列;`memory()` 补 KB 档给真实读数,不再显示成「0 MB」)。**产物行副标一律
  显示完整路径**(同名 node_modules/build 靠路径区分,中段省略;rationale 每行
  同文案零信息量,降为行悬停 + TierChip 悬停自解释档位)。项目行无可自动勾选项时
  给**可见**原因:全在用 = 锁图标、全为先检查 = 灰 chip「须逐个勾」。
  **卸载残留组**(p5-cleaner/02,殿后第三组)= 项目大卡同一配方原样复用(按
  `JunkGroup.groupsByOwner` 走大卡,工具缓存独占小卡形态):分组键 = 完整 bundle id,
  头排标题 = 尾段显示名(`com.tencent.qq` → `qq`),meta 前缀完整 id(同尾段的不同
  app 靠它区分,中段省略);文案名词换「应用 / 残留」。大卡头排「N 天前动过」与行副标
  「N 天未动」同档粒度(天 / 月 / 年)。全集不完整(某 Info.plist 读不了 / 扫描取消)
  时不出组,组位给一行三级墨色说明「卸载残留未检测:原因」——**「没查」与「查了
  没有」两态必须分开**(后者照空态规则不出组、不给说明)。页头副标注记「含卸载残留
  检测」/「卸载残留未检测」。
- **清理清单行**(p4-cleaner/04,`CleanerJunkViews.swift`):**舒适密度档**(上行)
  之下的既有配方:行首系统 checkbox(large);行选中底 =
  `{colors.surface-card-high}` 70% + `{rounded.inner}` 10。**安全档 chip**(`TierChip`)=
  统一 `ChipView.regular`(胶囊、tint 15% 底 + 同色文字、11 semibold),两态:可安全清理 =
  `{colors.state-positive}`、先检查 = `{colors.state-caution}`——映射的是
  GLOSSARY「安全档」(删除安全语义),不是负载警示,只在此组件出。勾选动作条 =
  `{colors.surface-card-high}` + `{rounded.card-compact}` 12,内距 8×12,右侧
  「清除勾选」bordered + 「清理…」borderedProminent(所在页指标色);确认清单走
  `{layout.sheet-width}` 460 定宽 sheet(标题 `{typography.section-title}`、逐行同清单行减
  checkbox、页脚总量 `{typography.card-title}` + 口径注记,`{layout.sheet-list-max-height}`
  220 滚动)。清单默认全不勾;右键行 = 排除该目录 / 在 Finder 中显示。**组头三态
  checkbox**(2026-10-30 用户拍板 B,`GroupCheckBox`):组标题前一枚系统 checkbox
  (NSButton allowsMixedState,SwiftUI `Toggle` 无混合态才包一层),**只吃组内「可安全
  清理」且非在用的项**——none / mixed 点击全勾、all 点击全清,先检查项与在用项
  永不被组勾选带上;组内无可勾项则不画。**项目产物组与在用灰行**(p4-cleaner/05):
  组头多一枚 segmented Picker「大小|新旧」(默认大小、regular 档——2026-11-05
  密度拍板升 B 档,不再 mini;新旧 = 最久未动在前,
  年龄未知排最后),行副标末尾追加年龄人话(「今天动过 / N 天未动 / N 个月未动 /
  N 年未动」,口径 = 项目内非产物文件的最后变动含 git 活动);未配扫描根时组位置
  出一行 `{typography.caption}` 三级墨色引导文案(不硬造空组)。**在用保护行**:整行
  55% 透明灰显、勾选位换锁形图标(`lock.fill` 三级墨色)、TierChip 位换 InUseChip
  (同胶囊配方,`{colors.inkTertiary}` 灰——在用是客观状态,不是「先检查」的警示琥珀,
  文案「在用保护 · 终端与构建正在此项目」由原因集拼出),点行无反应、右键排除保留。
- **设置「清理」页**(04 排除目录 + 05 扫描根,`CleanerSettingsView.swift`):两节
  Form。清理扫描根节 = 出厂建议清单(~/Documents / ~/Downloads / ~/Desktop /
  ~/Developer / ~/Projects / ~/dev / ~/code / ~/src,展示 ~ 写法、存储展开归一后的
  绝对路径)逐行 Toggle 勾选即加、取消即删,自添目录走文件夹选择器(自添行 =
  目录图标 + 路径 + 减号删除,与排除行同款);**与「项目根目录」页的归组配置两套
  独立、零共享**(用户拍板)。页脚说明文案钉死两条口径:项目 = 扫描根直接子目录、
  在用项目永不进清理且每次清理前重查。
- **空间地图卡**(p4-cleaner/07 + space-map-forms/01,`CleanerSpaceMapView.swift`):
  **双形态、同一画法**(用户拍板 2026-11-09:两种都要 Canvas 绘制,不要两种
  方案)——单个 SwiftUI Canvas 一次 draw call,命中一律坐标反算、不依赖形状
  hit test(方块 = rect.contains;旭日 = atan2 角度 + sqrt 半径)。形态切换 =
  卡头 `PillTabBar` `.selectedOnly` 双项图标(「方块」square.grid.3x3 /
  「旭日」chart.pie;space-map-forms/02——原 segmented 非标准件已废),
  `settings.spaceMapForm` @AppStorage 记住
  上次;切换不重置下钻位置(下钻 / 面包屑由 CleanerTabView 持有,切子药丸不丢)。
  **版面纪律(ui-unify 追改,2026-11-09 用户实报三修,两形态同守)**:①图表区
  弹性高、卡头 / 根选 / 面包屑 `layoutPriority(1)` 不被挤压——**注意清理页在
  ScrollView 里,弹性区拿到无限高度提案、塌到最小高,最小高 ≈ 实际高**;两形态
  各自处理:方块 `{layout.spacemap-chart-min-height}` 220 / 旭日 = **方形,边长 =
  max(卡宽, `{layout.spacemap-sunburst-min-side}` 360),高随宽、卡内居中**
  (onGeometryChange 测宽回写;04 用户拍板「放开铺满」+ 05 加下限与居中——
  aspectRatio 套 GeometryReader 在 ScrollView 里既不铺满也不居中,已废;03 的
  400 固定值在宽卡里只占中间一点,02 前的共用 220 曾把圆压小);②**悬停零重排**——卡内不出现 /
  消失任何占行元素(原卡顶悬停信息行已废),悬停信息与按钮一律浮在图表内;
  ③密封 / 叶子 / 「其他」点击解释 = 图表左上角浮层胶囊(cardHigh 90%,单行截断,
  不吃点击),不占卡内一行。
  - **方块(treemap,默认形态)**:squarify(`TreemapLayout`),块内 名字 + 实际
    占用(放得下时),高块底部百分比 10.5pt `.monospaced` 小标(等宽登记例外);
    「可清理」大块药丸 / 小块圆点(p4-uninstaller/05);悬停白名单块(≥140×48)
    时「这块能清」浮在该块右上角。
  - **旭日(两环,v1 形态以正确写法回归)**:内环 = 当前根的子辈、外环 = 孙辈,
    叶子与密封块延伸占满外环(`SunburstLayout`);**直径 = 方形边长 = max(卡宽,
    `{layout.spacemap-sunburst-min-side}` 360),高随宽、卡内居中**(04「放开铺满」
    + 05 下限与居中;340/400 两代固定直径已废)。**命中 = atan2 标准极角直接
    比对**(`SunburstArc.contains(angle:)`,纯值可测)——弧角本身就是标准极角,
    05 前视图层多加 π/2「换算」致悬停恒偏 90°(v1 起潜伏,回归测试钉死)。
    环形半径 0.28–0.65 /
    0.65–0.99、中心圈 0.26(01 版 0.34 中心过大环带窄,03 加宽);弧间角向留缝;
    弧内标签 10.5pt semibold(份额阈值内才显示、左半圆翻转 180° 外向可读、
    按弧长量宽截断;文字色随弧深浅切换);「可清理」= 弧内小圆点(药丸弧里放不下)。**中心圈 =
    悬停读数位**:悬停弧时显示该块名字 12 + 实际占用 14.5 + 「占当前 N%」(密封
    「只读系统区」/ 合并块「含 N 项」);不悬停时显示当前根 + 「↩ 返回上级」
    (顶层为「点击色块下钻」提示,点按中心圈 = 返回上级)。悬停白名单弧时
    「这块能清」锚在该弧中角外缘、钳制在图内(弧带窄,块内右上角配方套不进)。
  - **两形态共享**:配色 = **分区完全异色·柔和版**(2026-11-10 二轮拍板:
    01 高饱和十色 0.75 被嫌「闹」,02 同色系深浅上线即被毙「为什么一个颜色了,
    不同的分区应该完全不同颜色」)——顶层块按序循环十个 `{colors.accent-*}`
    令牌,基色不透明度 0.60;旭日内环每支一色、外环 = 父色 −0.13;hover 一律
    +0.08(封顶 0.95);块内 / 弧内文字色 ≥0.5 白、其余墨。
    「其他」合并块 = `{colors.surface-card-high}` 0.75、系统密封块 =
    `{colors.inkTertiary}` 0.5(不可下钻);**「其他」合并线两形态统一 1%**——
    小于整卷 1% 的目录不单独画出,画出来的都要够看清(space-map-forms/02)。
    「这块能清」浮层按钮同一配方(borderless 10.5 semibold 青 +
    cardHigh 90% 胶囊底,help 文案明示判定来源与地图只读);点块下钻 / 面包屑逐级
    可跳(`›` 分隔,末级加粗,末尾「回到整卷」)/ 头部「在 Finder 中显示」。块与弧
    **不做任何动画**(meter 条同款纪律)。**v1 只读:卡上没有任何删除控件**
    (ADR-0008 的 UI 边界)。
    树变换与两种几何全在 PulseCore `SpaceMap.swift` / `TreemapLayout.swift`
    (firmlink 提升把 /System/Volumes/Data/* 拼回顶层、System 余量折叠为密封块),
    视图只描边配色命中。
- **AreaTrendChartView**:56 点、线 2px 指标色、线下渐变 32%→0、4 条 8% 网格线、
  2% 左垫底;**StripChartView**:44 柱、36pt 高。二者都是自绘 Canvas,不引 Charts。
- **PillTabBar(通用药丸 tab 条,用户拍板 2026-10-22:tab 是通用组件样式)**:
  唯一视觉配方在 `Pulse/Views/PillTabBar.swift`——选中 = 该项强调色 15% 胶囊底
  + 同色前景,未选中 = secondary 前景无底;药丸间距 4;
  切换动画 0.2s snappy(选中文字自图标侧展开、胶囊生长、其余药丸滑移让位)。
  两档尺寸:`.regular`(默认 = 现状:callout 12 medium + 内距 9×5,高≈24,
  工具栏/历史页用)与 `.comfortable`(13.5→**14.5 medium** + 内距 14×8,高≈34;
  2026-11-05 用户拍板清理页整体升「舒适密度」,唯清理页子页条用此档)。
  两种文字形态:`.selectedOnly`(未选中纯图标 / 选中图标+文字;图标-only 必带
  a11y label + help)与 `.always`(文字恒显)。五处用法同一组件:主窗口工具栏
  tab(`MetricPillTabBar` 薄封装 = `.selectedOnly` + ←/→ 键盘 + 首尾再留 4pt
  与系统玻璃底的间距;选中才展开文字是用户拍板 2026-10-16 的宽度根治法)、
  历史页指标条(同工具栏形态:五项各指标色 + 与主窗口 tab 同符号,系统负载取
  仪表盘符与 CPU 区分)、历史页分项条(p2-review/07,用户拍板 2026-10-24 形态 (a):
  只在有分项的指标——温度、功率——出现,挂在指标条正下方,`.always` 无图标,一次
  看一条线不叠加;各项取分项色——功率单域取五路功率卡域配色 `PowerDomain.tint`,
  一个出处;间距沿用页面竖排间距 8 / 12,不另立数值)、历史页范围条(`.always` 无
  图标,色调随所选指标 / 分项)、空间地图形态切换(space-map-forms/02:
  `.selectedOnly` 双项图标「方块 square.grid.3x3 / 旭日 chart.pie」,卡头内,
  原 segmented 非标准件已废)。
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
- **页头 PageHeader**(popover-header/01,用户拍板 2026-11-02「每个 tab 只有一个标题,且是
  统一组件」,`Pulse/Views/PageHeader.swift`):主窗口页头 / 弹窗页头 / 清理页页头三处同一
  出处,不再各自手写。结构 = 标题一行 + 可选副标题一行 + 右侧配件槽。两档:`.full` 主窗口 =
  `{typography.page-title}` 26 bold + `{typography.body}` 12 secondary;`.compact` 弹窗 = 两行皆
  `{typography.caption}` 11 secondary;行距 `{spacing.micro}` 2。**副标题「本机一行」(芯片 ·
  核数 · 内存,`hostSummary`)只有总览带**,其余 tab 只有标题——判据在 `PageHeader.init(tab:)`
  单点,两窗不许各写一份;清理页副标题 = 扫描状态、配件 = 扫描 / 取消按钮(`CleanerPageHeader`,
  由主窗口页头槽位画,`CleanerTabView` 本体不画标题)。**每个 tab 恰一个标题**:tab 内容
  (卡片 / 子页)不得再画与页名同级的大标题。
- **弹窗 DashboardView**:面板 `{layout.popover-size}` 360×648 定尺寸;底部操作"开窗靠左、设置+退出靠右"
  (退出 = 纯图标,用户拍板)。顶部图标 tab 槽位**单行满宽均分**(P2 扩到
  11 枚后 32pt 定宽槽超出 332pt 内容区、右端裁切;均分只收窄不溢出,与主窗口
  工具栏 720 预算同一哲学)。页头 = `PageHeader` 紧凑档(页名;本机一行只在总览)+ 右侧
  运行时长。
- **状态 chip**:统一 `ChipView`(见 §Components 统一状态 chip;胶囊、tint 15% 底 +
  同色文字),两态语言(✓正常 / 高负载),阈值在 `StatusBadgeRules`(组 >100%、
  系统 <30% / >70%)。现役用法 = 指标卡大数字旁(系统负载);排行行不挂"高负载"
  文字 chip,组高负载 = 数值红字 + 最忙进程名 chip(见排行列表条,2026-10-30 用户拍板)。

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
- ~~指标主卡全尺寸内距 `.padding(20)` 与 2×2 统计 `horizontalSpacing: 18`、弹窗外框
  `.padding(14)`~~ —— 已收编(ui-unify/01,2026-11-08):20→`{spacing.card-padding}` 16、
  18→16、14→`{spacing.card-padding-compact}` 12,全上 4pt 网格。

2026-11-08 第三轮收编已完成(ui-unify/01,用户拍板"字号、组件都归一,功能相似组件
长一个样",方案 A = 排行也升舒适档):

- **字号 12 档 → 5 档**:`.caption/.caption2/.footnote/.title3` 语义字体一并换显式
  字号。映射:8.5 / 9 / 10 → 10.5(空间地图角标/横幅图标/treemap 小标);11.5 按角色
  → 11(说明)或 12(数值/按钮/横幅正文);12.5 → 12(卡题、空态、弹窗底排按钮、
  弹窗排行名称);13 行级 → 14.5、杂项 → 12;13.5 → 14.5(sheet 清单行、PillTabBar
  comfortable);14 → 14.5;16 bold 组头 → `{typography.section-title}` 17。
- **行两档制**:`RowMetrics` 单一出处(上文);排行主窗口行升舒适档(图标 22→24、
  名称/数值 13→14.5、副文 10.5→12、meter 110→120、行内距 6×7→14×10),弹窗紧凑档
  名称 12.5→12 / 数值 11.5→12;清理行图标 28→24、meter 130→120、上下距 14→10;
  sheet 清单行 13.5 档取消并入舒适档,残留/确认行定宽列 `frame(width: 78)` 改
  `CleanerListMetrics.valueWidth`。
- **chip 六合一**:`ChipView`(两形态)收编 HotProcessChip / TierChip / InUseChip /
  StateChip / BrewChip / MetricChipView(后两处为薄封装),透明度统一 15%。
- **防漂移**:`UiUnifyRowMetricsTests` 钉死两套 metrics 对 RowMetrics 的委托与五档
  落档;`RankingListMetricsTests` 量宽改读 metrics 本身。
- 例外(有意,不收):进程下钻组件簇(ProcessDrilldownView / SortableProcessTableView)
  共用组件带 `.caption` 族,归一需跨文件结构迁移(加 compact 参数走两档制),留待
  专项票;Image `.font` 的图标尺寸(7~26)不受文字五档约束。

superseded 拍板记录(原值→新值,决议不删只标):2026-10-30 弹窗数值 11.5 → 12
(ui-unify/01);2026-11-05 清理图标 28 / meter 130 / 上下距 14 → RowMetrics 舒适档
(ui-unify/01);2026-11-05 comfortable 药丸 13.5 → 14.5(ui-unify/01);
2026-11-09 蓝牙行 meter 44/64 + RSSI 数值列 → RowMetrics meter + 副文
(ui-unify 追改);2026-11-09 副卡头标题 11 medium 灰 → 12 semibold 指标色(ui-unify 追改)。

2026-11-09 第四轮收编已完成(ui-unify 追改,用户拍板 B = 八张旧卡一轮全换):
P2 批次八张明细卡(蓝牙 / 声音 / 容器 / 传感器三卡 / 五路功率 / 磁盘两卡 / 流量累计 /
dev server 行)的行升 RowMetrics 两档、状态圆点换类型图标(CardEntityRow)、副卡头标题
升彩色;两形态边界与未知值安静原则见 §Components「卡内行两形态边界」。蓝牙设备行新增
设备类型(CoD 主类 + BLE 走 IOHIDDevice usage,`BluetoothDeviceKind`),蓝牙卡开页即读
(等下一 tick 的最长 30s 空窗改为立即快照 + 「正在读取…」占位),弹窗截断 6 行补
「…共 N 台」尾行(容器卡同款)。

