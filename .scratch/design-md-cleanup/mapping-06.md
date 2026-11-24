# 06 去向表

DESIGN.md 两条旧条目逐条去向:「智能体页两子 tab」L655–662;「服务页」L663–782——
本体只有三张卡的 L663–673,挂在它名下的 L674–782 其实是智能体页的内容(消耗子页
L674–686、数字卡排 L687–692、热力墙 L693–709、两图同构 L710–717、图表浮层
L718–724、走势 L725–739、token 读数格式 L740–742、会话子页 L743–762、项目大卡
L763–782),已归回智能体页各视图。共 95 条:骨架 7、服务页 13、消耗子页 9、
数字卡排 5、热力墙 15、两图同构 5、图表浮层 4、走势 12、token 1、会话子页 12、
项目大卡 12。其中归组件规范 4 条、新写到代码 10 条、文档与代码不一致 10 条。

去向取值:已在代码 / 新写到代码 / 归组件规范(票 07)/ 删·代码自明 /
删·已废或历史 / 文档与代码不一致。「已在代码」含原文已合规未动、与按标准改写
两种,说明列写明是哪一种。

「本票范围外」= 实现或既有注释所在文件不在本票允许改动的八个文件里,未动。
一条规矩既有有效部分又有与代码不符的部分时拆成两行(带 b 后缀的那行是不符部分)。

## 一、智能体页两子 tab(L655–662)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 骨-1 | 页面 = 两个子 tab;dev server 卡迁出本页 | 新写到代码 | AgentViews.swift 文件头;`AgentSubTab` | 文件头改写为页面骨架(子药丸条 + 当前子页,两个子页各是什么)。原文件头写的是早已撤掉的「三张卡 / 用量限额卡 / dev server 卡从总览迁入本页」,全部过时,已换掉 |
| 骨-2 | 定稿骨架 `.scratch/agent-tab/wireframe-agents-page.html` 是唯一视觉真相,纯线稿约定见票 | 文档与代码不一致 | (原)AgentUsageViews.swift 文件头 MARK | 线稿第 100 行仍画三个子页「消耗 / 会话 / 开发服务」,代码是两个;项目卡、会话卡形态也与线稿不同。注释里的线稿回指已删 |
| 骨-3 | 子药丸条 = `PillTabBar` comfortable 档 + 页指标色 + 玻璃外裹 `isGlassContainer` | 已在代码 | AgentViews.swift `AgentSubTabBar` | 改写:去掉「08 补 / 06 漏传」,留「漏传就没有玻璃外裹,和清理页子页条两个样」。胶囊与玻璃外裹本身的规矩归现有的「药丸页签条」组件条目(票 07 重写的十条之一) |
| 骨-4 | 选中态在 `DashboardModel.agentSubTab`,切 tab 不丢,默认落「消耗」 | 已在代码 | DashboardModel.swift `DashboardModel.agentSubTab`(本票范围外);AgentViews.swift `AgentSubTab` | 两处都写明。`AgentSubTab` 注释改写,去掉「三子页被缩编为两页」的来历 |
| 骨-5 | 「每日消耗」外壳拆掉,四块平级成卡 | 新写到代码 | AgentUsageViews.swift 文件头 | 消耗子页骨架:四张卡平级、上下排,外面不套统一的大卡 |
| 骨-6 | Claude 用量卡撤,用量并入数字卡排第 4 张 | 已在代码 | AgentUsageViews.swift `AgentUsagePaneView.usageCell` | 类型注释原文即「第 4 张 = Claude 用量」,无历史,未动 |
| 骨-7 | 两子页 = 消耗 / 会话(Claude Code 会话卡 + ZCode 会话卡) | 新写到代码 | AgentViews.swift 文件头;AgentSessionViews.swift 文件头 | 页面骨架点名两个子页;会话子页骨架写在 AgentSessionViews.swift 文件头 |

## 二、服务页本体(L663–673)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 服-1 | 页标题「服务」、图标沿用 cube.box.fill、强调色沿用 containers 令牌(前身容器页) | 已在代码 | MetricTabModel.swift `MetricTab` 的 `.services`(`title` / `symbolName` / `accent` 三处注释)(本票范围外) | 原文已有。DevServerViews.swift 文件头骨架留一句指向 |
| 服-2 | 页面骨架:三卡上下堆叠(dev server / 监听端口 / 容器) | 新写到代码 | DevServerViews.swift 文件头 | 页面根视图 `MetricTabStack.blocks` 的 `.services` 分支不在本票允许的文件里,骨架写在 DevServerViews.swift 文件头 |
| 服-3 | dev server 卡配方原样;「全部停止」流不动 | 已在代码 | DevServerViews.swift `DevServerCardView` | 卡注释原有「全部停止上抛请求,确认流在 KillRequestFlow,绝不自动杀」。文件头与卡注释里的「总览页」是过时说法,已改为服务页;MARK 去掉日期;行注释去掉「ui-unify 追改」 |
| 服-4 | dev server 闲置告警落点跟卡走,落服务页 | 已在代码 | AlertEngine.swift `AlertRoute.services`(本票范围外) | 原文已有 |
| 服-5 | 监听端口卡:全机监听 TCP 端口 + 占用进程;行 = 端口号主名 + 占用者副文(名字 · pid,多进程「等 N 个进程」) | 已在代码 | PortsCardView.swift `PortsCardView`、`row(_:)`、`holderSummary(_:)` | 原文已有,未动 |
| 服-5b | 端口号「等宽」 | 文档与代码不一致 | PortsCardView.swift `row(_:)`;CardFamily.swift `CardEntityRow`(本票范围外) | 端口号作 `CardEntityRow` 的 name 传入,name 没有 `.monospacedDigit()`(只有副文有),不是等宽数字。未改 |
| 服-6 | dev server 标注(种类 · 闲置) | 已在代码 | PortsCardView.swift `devServerLabel(_:)` | 原文已有;改写为「文案与 dev server 卡同口径」 |
| 服-6b | dev server 标注是琥珀色,与 dev server 卡同口径 | 文档与代码不一致 | PortsCardView.swift `row(_:)`、`devServerLabel(_:)`;DevServerViews.swift `DevServerCardView.row(_:)` | 文档写琥珀;代码里这个标注恒 `.secondary`,不随闲置转琥珀。dev server 卡才是闲置时取 `Metric.disk.accentColor`。原代码注释也写「琥珀」,已按代码改齐;行为未改 |
| 服-7 | 行级「结束」= 该端口全部占用进程;确认单逐个点名;复用 KillRequestFlow 文案 | 已在代码 | PortsCardView.swift `PortsCardView` 类型注释、`row(_:)`;PortInventoryModel.swift `PortEntry`、`PortHolder.killTarget`(本票范围外) | 原文已有,未动 |
| 服-8 | 号序 + `{layout.port-row-limit}` 截断展开 | 文档与代码不一致 | PortsCardView.swift `shownEntries`;PortInventoryModel.swift `PortInventory.init`、`PortsCardMetrics.rowLimit`;PortsFeature.swift `PortsFeature.init`(后两者本票范围外) | 号序与上限已在代码。但 `PortsFeature` 默认按 rowLimit(20)构造盘点,`entries` 在构造时就只剩前 20 条,展开后 `shownEntries` 取的还是这 20 条——点「显示全部(另 N 个端口)」行数不变,只换标签。行为问题,未改 |
| 服-9 | root 进程端口读不到,卡脚一行小字如实注明 | 已在代码 | PortsCardView.swift `PortsCardView` | 原文已有,未动 |
| 服-10 | `.ports` 传感器家族 10s 档,可见才扫 | 已在代码 | PortsFeature.swift `PortsFeature`、`PortScanProvider`(本票范围外) | 原文已有,含探针耗时 |
| 服-11 | 容器卡:docker.sock 单发快照表,数据卷占用行不做 | 已在代码 | MetricTabStack.swift `blocks` 的 `.services` 分支注释(本票范围外);ContainerCardViews.swift `ContainersCardView` | 卡序注释原文已有。ContainerCardViews.swift 的 MARK 还叫「容器页」且带日期,已改为「服务页容器卡」 |

## 三、消耗子页(L674–686)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 耗-1 | 数字卡排 = 四张一排(今日消耗 / N 天合计 / 日均 / Claude 用量) | 已在代码 | AgentUsageViews.swift `numberCard`、`usageCell`、`usageSubline` | MARK「数字卡排(四张一排)」与第 4 张注释原文已有 |
| 耗-2 | 日历图 + 走势:内容宽 ≥ 断点一排两列等高,否则上下一列;弹窗恒一列;不用 `ViewThatFits` | 已在代码 | AgentUsageViews.swift `AgentUsagePaneView.chartTwoColumnMinWidth` | 改写:去掉日期与「07 立 1280 后修订」,留「量的是内容宽不是窗宽」「不要改回 ViewThatFits」 |
| 耗-3 | 「重新扫描」在日历图卡头,与「天 / 周」粒度药丸并排 | 删·代码自明 | AgentUsageViews.swift `heatCard` | 卡头尾部的 HStack 一眼可见。粒度 state 的注释去掉「替代 06 的年占位」 |
| 耗-4 | 卡头文字按钮配方(`arrow.clockwise` + 文字,borderless 12 semibold secondary) | 归组件规范(票 07) | AgentUsageViews.swift `AgentUsagePaneView.rescanButton` | 实现处留一句指向「卡头文字按钮」组件规范 |
| 耗-5 | 扫描中换 mini 转圈 + 「扫描中」并禁用 | 已在代码 | AgentUsageViews.swift `rescanButton` | 本页状态,写在原处;补了「防重入」 |
| 耗-6 | 项目大卡网格:单卡保底、上限 3 列,列数按容器实宽算 | 已在代码 | AgentProjectCardViews.swift `AgentProjectCardGrid` | 改写,数值不重复写(代码里是三个常量) |
| 耗-7 | 行内 HStack 等高、末行不满自动满宽;不用 GridItem minimum(硬下限,窄容器溢出);容器多窄都单列 100% 宽 | 已在代码 | AgentProjectCardViews.swift `AgentProjectCardGrid`、`rows` | 改写:把「LazyVGrid 行内拉不齐高度」和「GridItem minimum 是硬下限」分开写。原先 AgentUsageViews.swift 里重复的一份压成指向;网格上方的 MARK 去掉「三度修正」 |
| 耗-8 | 同规则适用日历图 + 走势双列与数字卡排:同行卡片一律等高 | 已在代码 | AgentUsageViews.swift `chartRow`、`numberCell` | 并排两卡那处注释改写(靠同构等高,不靠拉伸)。数字卡排的「同行四卡等高」在代码行尾注释里——行尾注释不算整行注释,硬约束不许动,原样保留 |
| 耗-9 | 05 的视觉细节全保留,06 只改结构与归属 | 删·已废或历史 | — | 改版来历,不是规矩;仍然有效的部分散在耗-1 至耗-8 各行 |

## 四、数字卡排(L687–692)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 数-1 | 等宽 lift 小卡:cardHigh 底 + 圆角 12 + 内距 8×12 + 卡间 8 | 删·代码自明 | AgentUsageViews.swift `numberCell`、`usageCell` | `numberCell` 注释留结构一句 |
| 数-2 | 标签 → 数值(28,今日消耗取页 accent)→ 副行;弹窗超宽读数 `minimumScaleFactor` 兜底 | 删·代码自明 | AgentUsageViews.swift `numberCell`、`usageCell` | 读代码即得 |
| 数-3 | 环比 ▲ 绿 / ▼ 红 / 无基准灰 | 已在代码 | AgentUsageViews.swift `AgentDeltaText` | 原文已有,含「无基准如实 —,不出 0% 假读数」 |
| 数-4 | 日均副行是峰值不是环比 | 删·代码自明 | AgentUsageViews.swift `numberCard` | 文案即「峰 X/天」 |
| 数-5 | 随 7/30 档位联动(N 天合计 / 日均(N 天)) | 已在代码 | AgentUsageViews.swift `AgentUsagePaneView.Range` | 原文已有(「数字卡排随档位联动」) |

## 五、热力墙(L693–709)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 热-1 | 自封装小组件;等比缩放、不滚动、每月一刻度 | 已在代码 | AgentUsageCharts.swift `AgentHeatWall` | 类型注释改写:去日期与「07 起不再抖动」,留结论。「固定边 14 + 横向滚动 + 每 8 周刻度」是被推翻的旧方案,不带 |
| 热-2 | 格子边长 = (容器宽 − 51×间距 3)÷ 52 | 删·代码自明 | AgentUsageCharts.swift `AgentHeatWall.side` | 公式读代码即得 |
| 热-2b | 边长公式只扣 51 个间距 | 文档与代码不一致 | AgentUsageCharts.swift `AgentHeatWall.side`、`inset` | 代码还扣了两侧各 3pt 留白,文档公式漏了这一项 |
| 热-3 | 52 列一年 364 天,最新在右 | 已在代码 | AgentUsageCharts.swift `AgentHeatWall.weeks`、`cellRect(_:)`、`hitTest(_:)`;AgentUsageViews.swift `heatCard` | 原文已有(「旧 → 新,列主序」) |
| 热-4 | 月刻度 = 列首日月份与前列不同的列标「N 月」 | 已在代码 | AgentUsageCharts.swift `AgentHeatWall.draw(in:levels:)` | 原文已有 |
| 热-5 | 四档色阶:值 / 年峰值 × 4 向上取整,≤8% 灰档 | 已在代码 | AgentHeatScale.swift `AgentHeatScale.levels`、`grayFloor`(本票范围外) | 原文已有 |
| 热-6 | 进行中的今天按时刻折算成全天等效量再分档(折算下限 6h 防凌晨虚高) | 已在代码 | AgentUsageCharts.swift `AgentHeatWall.levels`;AgentHeatScale.swift `projectedValues`(本票范围外) | 视图侧改写:留「不折算的话今天和完整天比天然吃亏」的原因,去掉「11-14 实报」 |
| 热-7 | accent 透明度 0.25 / 0.5 / 0.75 / 1;图区底 6% 灰 | 删·代码自明 | AgentUsageCharts.swift `AgentHeatWall.color(level:)`、`draw(in:levels:)` | 读代码即得 |
| 热-8 | 悬停读数 = 命中格 accent 描边 + 浮层;锚定命中格而不是跟随光标;坐标反算,不依赖形状 hit test | 已在代码 | AgentUsageCharts.swift `AgentHeatWall`、`hitTest(_:)` | 类型注释改写,保留「锚定命中格」「坐标反算」两句纪律 |
| 热-9 | 按周档:列 = 连续 7 天(末列以今天收尾,滚动周不是自然周),一列 7 格同色,四档按周峰值归一,今天那份照样折算 | 已在代码 | AgentUsageCharts.swift `AgentHeatGranularity`;AgentHeatScale.swift `weeks`、`weekLevels`(本票范围外) | 粒度枚举注释改写:补「滚动周不是自然周」「按周峰值归一,与按天各一套峰值」 |
| 热-10 | 按周:悬停命中整列,描边 = 整列外包框,浮层侧放(列右侧垂直居中,放不下翻左) | 已在代码 | AgentUsageCharts.swift `hoverRect(_:)`、`tooltip(for:levels:)`;ChartHoverGeometry.swift `sideTooltipOrigin`(本票范围外) | 原文已有,未动 |
| 热-11 | 按周浮层标题「近 7 天 · 11月8日 – 11月14日」/「11月1日 – 11月7日」 | 已在代码 | AgentUsageCharts.swift `agentTooltipWeek` | 原文已有,未动 |
| 热-12 | 页脚峰值随档「最多一天 / 最多一周」 | 已在代码 | AgentUsageViews.swift `heatPeakText(_:)` | 原文已有,未动 |
| 热-13 | 量化式与按周聚合在 PulseCore `AgentHeatScale` | 已在代码 | AgentHeatScale.swift `AgentHeatScale`(本票范围外) | 原文已有 |
| 热-14 | 切档清悬停 | 新写到代码 | AgentUsageCharts.swift `AgentHeatWall.body`(切粒度的 `onChange` 上方) | 原无注释,补一行原因:两档下标含义不同(天序号 / 列序号) |

## 六、两图同构(L710–717)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 构-1 | 两卡结构 = 卡头 → 图区 → 共用自绘日期轴带 `AgentChartAxis` → 页脚;两图同一绘制函数 | 已在代码 | AgentUsageCharts.swift `AgentChartAxis`;AgentUsageViews.swift `chartRow` | 轴带注释改写:去掉「用户实报」叙述,留「同一函数、同一组常量,对齐由构造保证」;`labelCenterOffset` 注释去掉「06 原值」 |
| 构-2 | 页脚:热力墙「Claude 与 ZCode 合计 / 最多一天」、走势「近 N 天 · 日均 / 最多一天」 | 删·代码自明 | AgentUsageViews.swift `heatCard`、`trendCard`、`chartFooter(leading:trailing:)` | 文案在代码里 |
| 构-3 | 走势绘图区高 = 热力墙同宽图区高;Charts 自带 x 轴隐藏;y 标签挪进图内左上;绘图区铺满卡宽、左右缘与热力墙齐 | 已在代码 | AgentUsageCharts.swift `AgentTrendChart`、`AgentHeatWall.gridHeight(forWidth:)` | 走势类型注释改写:补「轴标签占了绘图区以外的宽,绘图区就比热力墙窄」的原因 |
| 构-4 | 并排不再靠 fixedSize 拉伸,同构即等高 | 已在代码 | AgentUsageViews.swift `chartRow` | 并排两卡处的注释改写 |
| 构-5 | 热力墙月签相邻不足 32pt 丢前一个 | 已在代码 | AgentUsageCharts.swift `AgentHeatWall.monthLabelMinGap`、`draw(in:levels:)` | 原文已有;去掉「——10 修」 |

## 七、图表浮层(L718–724)——通用件

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 层-1 | 浮层两行:日期(「今天 · 11月14日」/「11月13日 周四」,跨年补年)+ 8×8 色块 + 读数 12 semibold 等宽 | 归组件规范(票 07) | AgentUsageCharts.swift `AgentChartTooltip`;`agentTooltipDate` | 实现处留一句指向「图表悬停读数与浮层」。日期标题格式的注释原文已有,未动。「06 的单行 cardHigh 90% 胶囊作废」是被毙方案,不带 |
| 层-1b | 浮层只有两行 | 文档与代码不一致 | AgentUsageCharts.swift `AgentChartTooltip.bucketsGrid(_:)` | 该时段有分项时代码还加第三块 2×2 四桶明细(Input / Output / Cache R / Cache W),文档没写。票 07 立规范时要定这块算不算通用变体 |
| 层-2 | 底 = 系统 `.regularMaterial`,圆角 8,内距 6×8 | 归组件规范(票 07) | AgentUsageCharts.swift `AgentChartTooltip` | 同一句指向 |
| 层-3 | 定位走 `ChartHoverGeometry`:锚点正上方居中、间距 6、实测尺寸钳位、首帧未量到尺寸先隐藏 | 归组件规范(票 07) | AgentUsageCharts.swift `AgentChartTooltip`;ChartHoverGeometry.swift `tooltipOrigin`(本票范围外) | 指向句里点名 `ChartHoverGeometry`。「首帧隐藏」的原因在 `AgentHeatWall.tooltipSize` 注释里原文已有 |

## 八、走势(L725–739)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 势-1 | 走势用官方 Swift Charts(`LineMark` + 自定 `AxisMarks`) | 删·代码自明 | AgentUsageCharts.swift `AgentTrendChart` | `import Charts` 与 MARK 即得 |
| 势-2 | 域顶留 15% 头寸 | 删·代码自明 | AgentUsageCharts.swift `AgentTrendChart.chart(_:)` | 读代码即得 |
| 势-2b | y 轴在左,三档 0 / 半值 / 峰值 + 网格线 | 文档与代码不一致 | AgentUsageCharts.swift `AgentTrendChart.chart(_:)` 的 `chartYAxis`、`yLabels(rawMax:proxy:plot:)` | 代码只有半值、峰值两档标签与网格线,没有 0 档;标签画在图内左上而不是 y 轴上(文档 L715 自己也写「y 标签挪进图内左上」,两条互相矛盾)。代码注释原文即「半值 / 峰值」 |
| 势-3 | x 轴 MM-DD 每天一格 | 删·代码自明 | AgentViews.swift `agentShortDate` | 一点一天;标签格式注释原文已有 |
| 势-4 | 30 天图标签 -45° 斜排防重叠 | 删·已废或历史 | — | 被同一条后面的「按宽抽稀横排」取代;全仓没有 `rotationEffect`。它取代的更早方案「N 天前」抽样刻度同样是历史 |
| 势-5 | 悬停读数 = 吸附日 `RuleMark` 竖线 + 高亮点 + 点正上方浮层 | 已在代码 | AgentUsageCharts.swift `AgentTrendChart` | 类型注释原有这一句;类型注释其余部分按构-3 改写时,这一句原样保留 |
| 势-6 | 日期轴一律不带 unit;域 = 首…末日零点,线贴绘图区左右缘 | 新写到代码 | AgentUsageCharts.swift `AgentTrendChart.chart(_:)`(`return Chart` 上方) | 域的注释原文已有;「不带 unit」的原因原先只在文件头的改版叙述里,现在挪到 `return Chart` 上方,并补「竖线不贴点先查这里」 |
| 势-7 | `proxy.value(atX:)` 吃绘图区坐标,overlay 本地坐标须先减 plotFrame 原点 | 已在代码 | AgentUsageCharts.swift `AgentTrendChart.chart(_:)`(悬停闭包内) | 行内注释原文只有结论,补了「漏减会整体右偏一个 y 标签区的宽」 |
| 势-8 | 标签按宽抽稀横排(单签 ≥44pt,从今天倒数、末点恒标;首左末右锚、中间居中) | 新写到代码 | AgentUsageCharts.swift `AgentTrendChart.axisStrip(_:)`;ChartHoverGeometry.swift `labelStride`、`labelIndices`(本票范围外) | 原无注释,补上,含「不用斜排」的原因 |
| 势-8b | 每天一刻度保留;用 `AxisValueLabel(centered: false, anchor:, horizontalSpacing: 0)` | 文档与代码不一致 | AgentUsageCharts.swift `AgentTrendChart.chart(_:)`、`axisStrip(_:)` | 全仓没有 `AxisValueLabel`;x 轴整个隐藏,标签是 Canvas 自绘,没有逐天刻度。结论(抽稀、末点恒标、首左末右锚)仍有效,按实际实现写进注释 |
| 势-9 | 线 2pt 页 accent + 单调插值、线下渐变面积 32%→0、末点圆点;轴字 micro tertiary | 删·代码自明 | AgentUsageCharts.swift `AgentTrendChart.chart(_:)` | 读代码即得;「与 `AreaTrendChartView` 同配方」这句口径一致性留在类型注释里 |
| 势-10 | 缺天画 0 | 已在代码 | AgentUsageWindow.swift `AgentUsageWindow.dayTotals`(本票范围外) | 原文已有(「账本无行的天 = 0」) |

## 九、token 读数格式(L740–742)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| token-1 | 唯一出处 PulseCore `AgentTokenFormat`(app 层 `agentTokenText` / `agentTokenFigure` 仅转发):999 / 556k / 6.9M / ≥1000M 进 B | 已在代码 | AgentViews.swift `agentTokenText`、`agentTokenFigure`;AgentTokenFormat.swift `AgentTokenFormat`(本票范围外) | 两处原文都写明「唯一出处」,格式规则在核心包,未动 |

## 十、会话子页(L743–762)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 会-1 | 每会话一块 lift 小块(cardHigh 底、圆角 10、内距 12 / 弹窗 10,块间 8) | 新写到代码 | AgentSessionViews.swift 文件头 | 文件头改写为子页骨架(块分左右两半,各是什么);数值不重复写。原文件头的「08 重设计…06 版…」改版叙述去掉 |
| 会-2 | 左 = 图标 + 项目名;工作目录经 `AgentSessionLocation` 折回主仓;worktree 另挂带分支图标的 chip | 已在代码 | AgentSessionViews.swift `AgentSessionTile`、`agentSessionLocation(_:)`;AgentSessionLocation.swift `AgentSessionLocation`(本票范围外) | 小块注释改写:去掉「09 / 用户实报」,留「不折回主仓就看不出属于哪个项目」 |
| 会-3 | 分支 chip(同款 ink-tertiary;detached 显短 SHA;非 git 仓库安静缺位) | 已在代码 | AgentSessionViews.swift `AgentSessionTile`;SessionGitStatusModel.swift `SessionGitStatus`(本票范围外) | 原文已有。detached 取前 7 位的规则在核心包,视图注释不再重复 |
| 会-4 | 工作区有未提交改动(含未跟踪文件)再挂「未提交」chip(琥珀) | 已在代码 | AgentSessionViews.swift `AgentSessionTile`;SessionGitStatusModel.swift `SessionGitStatus`(本票范围外) | 原文已有;「含未跟踪文件」的口径在核心包 |
| 会-5 | 数据 = 智能体页可见才采,15s 档(cwd 集变化提前 5s),git 子进程全在后台任务 | 已在代码 | AgentSessionFeature.swift `AgentSessionFeature`(本票范围外) | 原文已有(「三道闸」) |
| 会-6 | 状态 chip:Claude 忙 = 页 accent、其余 ink-tertiary;ZCode 在跑 / 空闲 | 删·代码自明 | AgentSessionViews.swift `ClaudeSessionsCardView.tile(_:)`、`ZCodeSessionsCardView.tile(_:)` | 读代码即得 |
| 会-7 | 摘要:Claude 任务摘要 / ZCode 更新于 N 前 | 删·代码自明 | AgentSessionViews.swift 两张卡的 `tile(_:)` | 读代码即得 |
| 会-8 | 路径行:`folder` + home 缩写 `~` 的工作目录,中段截断,help 显全路径 | 已在代码 | AgentSessionViews.swift `AgentSessionPathLabelStyle`、`agentSessionLocation(_:)`;AgentSessionLocation.swift `abbreviate`(本票范围外) | 原文已有 |
| 会-9 | 元信息:Claude 会话名(与项目 / worktree 同名不写)· 模型 · 运行时长 · 子代理 N · pid;ZCode 会话短 id | 已在代码 | AgentSessionViews.swift `ClaudeSessionsCardView.meta(_:location:)`、`ZCodeSessionsCardView.shortSessionID(_:)` | 原文已有 |
| 会-10 | 右 = 带标签读数块(标签 → 读数 → meter → 注脚):Claude「上下文 N%」+「已用 / 窗口上限」(无读数「—」+「尚无请求」);ZCode「子代理在跑 a / b」+「累计 N tokens」 | 已在代码 | AgentSessionViews.swift `AgentSessionMetric`、`ClaudeSessionsCardView.contextCaption(_:)`、两张卡的 `tile(_:)` | 原文已有,未动 |
| 会-11 | 卡头右计数「N 个实例」/「近一天 N 个会话」 | 已在代码 | AgentSessionViews.swift `AgentSessionCount` | 原文已有,未动 |
| 会-12 | 读数一律自带口径与单位,不出裸数字 | 新写到代码 | AgentSessionViews.swift 文件头 | 文件头改写时留下这一句和原因(单摆一个「23%」读者看不出是什么) |

## 十一、项目大卡(L763–782)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 项-1 | 卡 = cardHigh 底 + 圆角 10 + 内距 16,段间 16、段内 8;四段 | 新写到代码 | AgentProjectCardViews.swift 文件头 | 文件头改写为四段骨架。原文件头的「07 重设计…06 版五层四条分隔线…」改版叙述去掉;数值不重复写 |
| 项-2 | 头 = folder.fill(在跑 / 今天取页 accent,静了取 inactive)+ 项目名 + 在跑 chip;右「占 N%」;下接主数值 + 环比 | 删·代码自明 | AgentProjectCardViews.swift `AgentProjectCardView.header`、`isActive`、`valueRow` | `header` 注释原文已有;数值读代码即得 |
| 项-2b | 状态图标 folder.fill 12 | 文档与代码不一致 | AgentProjectCardViews.swift `AgentProjectCardView.header`;IconSize.swift `IconSize.inline` | 代码是 `IconSize.inline`(11),文档的 12 是图标归档前的旧值 |
| 项-3 | 五格读数(Input / Output / Cache R / Cache W / Cache×)两端对齐等间距(首格贴左、末格贴右且内部右对齐,格间 Spacer 均分) | 已在代码 | AgentProjectCardViews.swift `AgentProjectCardView.bucketsRow` | 改写:留「排成等宽列末格会悬在中段」,去掉「08 / 用户实报 07」 |
| 项-3b | 五格的值 14.5 semibold 等宽,标签 micro tertiary | 删·代码自明 | AgentProjectCardViews.swift `AgentProjectCardView.bucket(_:_:alignment:)` | 读代码即得;「06 的 12 与标签层级太近」是被改掉的旧值 |
| 项-4 | 倍率 = 缓存读 ÷ 净(输入 + 输出),分母 0 → 「—」 | 已在代码 | AgentProjectCardViews.swift `bucketsRow`;AgentUsageWindow.swift `AgentProjectSummary.cacheMultiplier`(本票范围外) | 原文已有;「分母 0 显示 —」补进 `bucketsRow` 注释 |
| 项-5 | 构成两行「模型 / 来源」:左标签列 + 分段条(段间 2pt 缝;模型色按序;来源 = 前两色)+ 图例(份额 0 不进) | 已在代码 | AgentProjectCardViews.swift `compositionBlock`、`compositionRow(label:entries:)`、`AgentSegmentedBar`;MetricAccent.swift `AgentModelTint`(本票范围外) | 原文已有;`AgentSegmentedBar` 注释去掉「07:」,改成留原因 |
| 项-5b | 模型构成 = 占比前二 + 「其他」 | 文档与代码不一致 | AgentUsageWindow.swift `AgentUsageWindow.topModels`(本票范围外) | ≤3 个模型时原样列出,>3 个才取前二 + 「其他」;文档漏了前一分支 |
| 项-6 | 全卡唯一一条 hairline,下接元信息尾行(符号引导:活跃 N/窗口 天 · 现存会话数 · 请求数)+ 右「今天活跃 / 静了 N 天」 | 已在代码 | AgentProjectCardViews.swift 文件头、`AgentProjectCardView.footer`、`idleText` | 文件头写明「全卡只有一条 hairline」;`footer` 注释去掉「不再三段灰字挤一行」 |
| 项-7 | 现存会话数口径(Claude≈近 30 天未删文件 + ZCode 有账全史,扫描现数不落库;slug 末词与账本项目名做唯一尾段归并) | 已在代码 | AgentUsageWindow.swift `AgentUsageWindow.sessionCounts`、`AgentProjectSummary.sessions`(本票范围外) | 原文已有 |
| 项-8 | 五格读数对齐 tokscale 参数(四桶 + 缓存倍率 + 会话数) | 已在代码 | AgentProjectCardViews.swift「段 2:五格读数(tokscale 对齐)」MARK | 这句不在 DESIGN.md 两条里,原在 AgentUsageViews.swift 文件头;它管的是项目卡,那边 MARK 已有,文件头改写时不再重复 |
| 项-9 | Cost 美元与精确 Last Active 不做 | 删·已废或历史 | — | 属范围取舍的来历,不是实现规矩;原在 AgentUsageViews.swift 文件头,改写时去掉。想留住建议放 `.out-of-scope/` |

## 备注

- 页面骨架落点:智能体页 → AgentViews.swift 文件头;消耗子页 → AgentUsageViews.swift
  文件头;会话子页 → AgentSessionViews.swift 文件头;项目大卡 →
  AgentProjectCardViews.swift 文件头;服务页 → DevServerViews.swift 文件头(根视图
  在 MetricTabStack.swift,不在本票允许的文件里)。
- 指向组件规范的两句话用的条目名是「图表悬停读数与浮层」(AgentUsageCharts.swift
  `AgentChartTooltip`)和「卡头文字按钮」(AgentUsageViews.swift `rescanButton`),与票
  07 Agent Brief 的叫法一致;票 07 换名字的话要回来改这两处。
- 本票顺带按标准改写的三条相邻注释(不在两条旧条目里,但贴在本票重写的内容上):
  AgentUsageViews.swift `projectLimit`(去日期与「用户拍板」);AgentProjectCardViews.swift
  网格的 MARK(去「三度修正」);DevServerViews.swift `row(_:)`(去「ui-unify 追改」)。
- 本票未动的残留:三处代码行尾注释(AgentUsageViews.swift `numberCell` 两处、
  AgentProjectCardViews.swift `compositionRow` 一处),其中 `numberCell` 的「同行四卡
  等高」那一处带日期——行尾注释挂在代码行上,硬约束不许动代码行。
