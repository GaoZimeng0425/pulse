# 02: 主卡小走势图悬停——与历史页行为一致(时间戳并行环补齐)

**Status:** ready-for-agent

**What to build:** 各指标 tab 主卡的小走势图(AreaTrendChartView,56 点面积图,
CPU/内存/GPU/ANE/电池/磁盘/网络主卡右列 + 弹窗竖版)加悬停读数,配方与
history-hover/01 完全同款:竖线贴吸附点 + `AgentChartTooltip`「时刻 · 数值」
两行。**总览卡底部迷你条带(StripChartView)不做**(用户拍板 2026-11-24:
氛围件不查数,36pt 悬停体验差)。

**背景:** history-hover/01 落地后用户在指标 tab 主卡上晃鼠标无反应——
「每个 chart 不都应该行为一致吗」;拍板加主卡、不加迷你条带。

**事实核查档(2026-11-24 主 checkout 核查,免重查):**

- AreaTrendChartView = 自绘 Canvas(MetricTabViews.swift:14-94):x = 点序号
  等距 `index/(count-1)*width`,**右对齐**(不足 56 点左侧 2% 垫底);
  调用点仅两处(MetricMainCardView regular :239 / compact :260,
  `values: model.trend, tint, domainMax`)+ 一处 Preview。
- **趋势数据全是无时间戳的 RingSeries<Double>**(心跳节奏 5s 关窗/1s 弹窗
  混合,按序号×假设节拍猜时刻在弹窗开关后会错到分钟级——不做近似):
  - CPU/内存:SampleHistory.record(PulseCore,单点喂入 :187-193);
  - GPU:monitor.gpu.trend(GpuFeature);网络:NetworkFeature.trend
    (:23 append rates);磁盘:DiskModel 累加器双环(:496-497);
  - ANE:monitor.power.aneTrend;DashboardModel :53-101 组装进 MetricCardModel。
- 数值格式化:MricCardModel 带 `metric: Metric`,各 factory 已按指标格式化
  主数字;悬停数值 = 同族 formatter(CPU/GPU/电池 %、内存字节、网络/磁盘速率)。

**方案(并行时间环,机械套用):**

- 每个喂值点同步 append 一个时间环(与值环同容量同节拍,天然对齐):
  SampleHistory(systemCPULoadTimes/memoryUsedTimes)、GpuFeature、NetworkFeature、
  DiskModel 双环、PowerFeature aneTrend 各补并行 `RingSeries<Date>` /
  `[Date]`;append 处与值同批,时间取该轮 takenAt(与采样同源,不另取钟)。
- MetricCardModel 增 `trendTimes: [Date]`(default [],factory 逐个接线);
  AreaTrendChartView 增 `times: [Date]` 与 `valueText: (Double) -> String`
  两参:悬停竖线贴点 + 浮层「HH:mm:ss · 数值」(主卡窗口只有几分钟,时刻到
  秒;times 为空/长度不齐 → 不出悬停,诚实降级不猜)。反算/吸附复用
  PulseCore `HistoryCurveHover`(点等距同构,x 式 `i/(count-1)*w` 与历史页
  `(i+0.5)*w/count` 不同——**反算函数按本图 x 式另写一版或参数化**,别硬套)。
- 残留态守卫照抄 01 的教训:换 tab/数据换窗后越界与「点尚无新值」都安静收起;
  本图右对齐垫底槽(index < count-window.count)悬停**不出**(那是垫的 2%
  假点,不是读数)。
- DESIGN.md AreaTrendChartView 条目补悬停规格;时刻格式 HH:mm:ss(短窗)。

**测试:** 反算函数(新 x 式)单测 + 垫底槽不出读数的判定单测(纯函数);
各喂点接线靠 check.sh 既有回归面;浮层目验归用户。

**冗余搜查(立票即分诊):** 主卡 hover 零存量;配方与 01 同源不另造件;
迷你条带明确出界(拍板);无产品拍板残留;分类=UI 一致性补齐;
ready-for-agent。

**验收:** 起 app → 任一指标 tab(CPU/内存/磁盘/网络等)→ 主卡右侧小走势图
上横移鼠标——竖线贴点、浮层报「14:32:05 · 63%」;弹窗竖版同款;总览迷你
条带仍无悬停(拍板如此)。
