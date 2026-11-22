# 01: 历史页曲线悬停读数——竖线贴点 + 时刻/数值浮层

**Status:** ready-for-agent

**What to build:** 历史页走势曲线(HistoryCurveView,九指标+分项共用)加悬停读数:
鼠标横移竖线贴着**最近的数据点**走,浮层报**时刻 + 数值**两行(「11月22日
23:00 · 63%」)。复用智能体页热力墙配方:onContinuousHover(.local) 坐标反算
→ 点吸附 → overlay 浮层(`AgentChartTooltip` title/value 形态,定位
`ChartHoverGeometry.tooltipOrigin`);竖线画在吸附点上(不是光标像素——agent
走势 07 根因同款语义)。空桶(断线处)吸附最近非空点,不显示「无数据」占位
(查读数要的是数;竖线贴点本身说明读的是哪个点)。

**背景:** iSurge 对照差距④(待办池最小打磨项)。2026-11-23 grilling 一轮
定稿,用户「同意」三 A。

**拍板(grilling,2026-11-23):**

1. 浮层 = 时间 + 数值两行(只报数值不知道是哪一刻等于白查)。
2. 形态 = 竖线贴吸附点 + 浮层(智能体页走势同款;配方现成,吸附/钳位/翻面
   都做过)。
3. 范围 = 历史页全部走势图一次做齐(九指标+分项同一组件,机械套用);
   **总览卡底部 strip 条带不在本单**(瞬时走势装饰,非历史查询工具)。

**事实核查档(Explore,2026-11-23,免重查):**

- 历史页 = 单卡 `HistoryTabView`(MetricTabStack case .history)内
  `HistoryCurveView` 自绘 Canvas(HistoryView.swift:220-298):x = 桶序号
  等距 `(i+0.5)*width/count`,空桶断线不补零,线 2px 圆头;无轴无标签。
  **现状零悬停**(全库 hover 符号只在智能体页图表与空间地图)。
- 数据点密度:hour1=60 桶(60s)/ day1=288(300s)/ days7=168(3600s)/
  days30=720(3600s)——同档桶等宽,按点吸附与按时间等价。
- 可复用件(均无 Charts 依赖,热力墙先例):`ChartHoverGeometry`
  (PulseCore 纯值+单测:tooltipOrigin 正上钳位翻面 / nearestIndex 吸附)、
  `AgentChartTooltip`(title/value/swatch,breakdown nil 两行形态)。
- 智能体页 RuleMark/chartOverlay 半套**不适用**(那是 Swift Charts;历史
  曲线是自绘,走热力墙的「坐标反算 + overlay」路径)。

**分层与文件:**

- PulseCore 新 `HistoryCurveHover.swift`(纯函数,单测):x→桶序号反算
  (`index(atX:width:count:)`)、最近非空点吸附(`nearestNonEmpty`)——
  ChartHoverGeometry 同族,进包可测。
- `HistoryView.swift` HistoryCurveView 挂悬停:@State hoverIndex;
  onContinuousHover(.local) → 反算+吸附(空桶跳过)→ overlay:细竖线
  (吸附点 x,高度=图区)+ `AgentChartTooltip`(title=时刻、value=指标
  格式化读数、swatch=曲线 tint);时刻格式按档:hour1/day1 到分钟
  (跨天补「昨天」/日期)、days7/30 到小时(「M月d日 HH时」)。时间锚 =
  该序列桶边界(取序列查询锚推第 i 桶结束时刻,不用悬停瞬间的 now——
  免得轮询间隙漂移)。
- **DESIGN.md 先补条**:历史曲线本身无组件条目,随本票立「历史曲线悬停」
  配方(复用 AgentChartTooltip 家族、竖线贴点语义、空桶吸附最近非空)。
- 弹窗 isCompact 同组件自动生效。

**测试:** PulseCore HistoryCurveHover 单测(x 反算边界:左缘/右缘/中点;
空桶吸附:全空→nil、两侧皆空取近、正常取最近);浮层/竖线目验归用户。
既有 1421 例不回归。

**冗余搜查(立票即分诊):** 历史页 hover 零存量(全库符号核查);配方与
智能体页两处同源不另造浮层;`.out-of-scope/` 无同域条目;无产品拍板残留
(三问已定);分类=UI 增强;ready-for-agent。

**验收:** 起 app → 历史页 → 任一指标图上横移鼠标——竖线跳点跟随,浮层报
「时刻 · 数值」;切 day1/days30 档时刻粒度跟着变;空档期悬停竖线吸到最近
有数据的点。
