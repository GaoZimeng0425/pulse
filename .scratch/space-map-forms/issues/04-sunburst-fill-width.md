# 04: 旭日铺满卡宽——固定直径废,方形高随宽

**What to build:** 用户实报(2026-11-10,03 上线后):「为什么旭日这么小,放开
铺满屏幕,旭日只有中间的一点点」——03 的 400 固定直径在宽窗口里只占中间一块,
两侧留白。修法:旭日图表区改为**正方形、高随宽**(`.aspectRatio(1, contentMode:
.fit)`——ScrollView 的无限高度提案下按宽度成正方),直径 = 卡内容宽,废
`{layout.sunburst-diameter}` 固定值;方块形态维持 220 不动。

**Status:** done(2026-11-10,待合 develop)
令牌行标 superseded;几何半径全按 min(宽,高)/2 自适应,无需改)

- [x] 旭日直径 = 图表区宽(方形铺满卡宽),宽窗不再中间一小块
- [x] 命中/标签/圆点/中心圈/轻桥全部随新直径自适应(本就按比例,零改动预期)
- [x] DESIGN.md:令牌 {layout.sunburst-diameter} 标 superseded;旭日 bullet 与
      版面纪律①改为「方形高随宽」

## Comments
- **交付(2026-11-10)**:改动极小——`sunburstBody` 的 frame 换
  `.aspectRatio(1, contentMode: .fit)`(ScrollView 无限高度提案下按宽度成正方,
  直径 = 卡内容宽),废 `sunburstDiameter` 常量与 `{layout.sunburst-diameter}`
  固定值(令牌行标 superseded,沿用 rssi 行写法);命中 / 标签 / 圆点 / 中心圈 /
  轻桥全按 min(宽,高) 比例,零改动。SwiftLint aspectRatio 规则单行豁免
  (scaledToFit 语义不合,仓内已有三处 warning 先例,本次选择显式豁免注释)。
- **验证**:lint + 全量 1200/1200(核心 718 + app 482)。
- **欠目验(用户)**:清理页 → 空间地图 → 旭日:圆铺满卡宽(窗口越宽圆越大),
  中心圈 / 环带 / 弧内文字同步变大;下钻 / 悬停 / 中心圈返回上级照旧。
