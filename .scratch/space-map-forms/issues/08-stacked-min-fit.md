# 08: 回上下堆叠,旭日直径 = min(卡宽, 可视高 × 0.8)

**What to build:** 用户实报(2026-11-10,07 上线后):「不对,应该是上下布局,
不是两列,旭日图应该跟随宽高中小的那个值画」。①mapSection 回上下堆叠
(07 两列版废;摘要卡 ViewThatFits 折行保留——全宽下首选原整行,无害);②旭日
尺寸 = **直径 min(卡内容宽, 图表区高)**,图表区高 = 可视高 × 0.8
(`containerRelativeFrame(.vertical)` 量滚动视口;扣两成给页头/卡头/面包屑与
摘要卡露头)、下限 {layout.spacemap-sunburst-min-side} 360——矮窗不顶天立地
(06 教训)、宽窗不缩成一小块(03/04 教训)、随窗口大小伸缩。06 的卡级宽探针退役
(min(w,h) 不需要知道宽的数值)。

**Status:** done(2026-11-10,develop@2e7ce52)
(后者语义更新 + 新增 viewport-share 令牌))

- [x] 上下堆叠恢复;旭日直径 = min(卡内容宽, 可视高×0.8),卡内居中
- [x] 窗口高度变化时圆随之伸缩(矮窗小、高窗大),不顶天立地、不缩成一点
- [x] DESIGN.md:版面纪律①④重写 + 旭日 bullet + 令牌两行(新增 viewport-share)

## Comments
- **交付(2026-11-10)**:CleanerViews 回堆叠(07 条件分支/探针/阈值全撤,
  spaceMapCard 抽取与摘要 ViewThatFits 保留);CleanerSpaceMapView 尺寸链换成
  单条 `.containerRelativeFrame(.vertical) { max($0 × 0.8, 360) }`——直径由
  既有 sunburstRadius = min(宽,高)/2 天然得出,零测宽状态、零反馈可能。
  新令牌 {layout.spacemap-sunburst-viewport-share} 0.8 入表;min-side 语义更新
  为直径/图表区高下限。08 起旭日尺寸世代史:固定直径(340/400)→ aspectRatio
  → 自测宽(正反馈撑爆)→ 卡宽即边长(顶天立地)→ 两列半宽卡 → **min(卡宽,
  可视高×0.8)**, DESIGN 版面纪律①留了全案记档。
- **验证**:lint + 全量 1213/1213(worktree 内一次过)。
- **欠目验(用户)**:①上下堆叠恢复(地图卡在上、摘要卡在下);②圆直径 =
    宽与高中小的那个(宽窗里受高度约束、窄窗里受宽度约束),卡内居中;③拉高
    窗口圆变大、压矮变小,不再顶天立地。
