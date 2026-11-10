# 05: hover 命中恒偏 90° 修复 + 旭日居中/下限(弃 aspectRatio)

**What to build:** 用户实报(2026-11-10,04 上线后):「空间地图有最小宽高,旭日要
居中显示,现在 hover 差了 30° 左右」。
①**hover 偏移**——根因:`SunburstArc.start/end` 本身就是标准极角(直接喂
`Path.addArc`,布局从 -π/2 起跑所以第一段在正上),但 PulseCore 注释误写
「0 弧度 = 正上」,视图层 `hitArc` 据此多做一次 `+π/2`「换算」——命中恒偏 90°、
永远落到顺时针下一段(用户目测 ≈30° 是相邻块的视觉差)。此 bug 自 p4-cleaner/07
v2(619533a)潜伏,v1 两天即被毙未暴露,01 原样移植。修:命中判定下沉 PulseCore
`SunburstArc.contains(angle:)`(相对起点偏移 < 弧宽,天然覆盖负角起点与 2π
周期表示),视图直接传 `atan2(dy, dx)`;纠正错误注释;加回归测试。
②**居中 + 铺满**——04 的 `.aspectRatio(1, .fit)` 套在 GeometryReader 上在
ScrollView 里既不铺满也不居中。换显式手段:`onGeometryChange` 测宽 → 边长
`max(卡宽, 360)` → `.frame(height:)` 落地 → `.frame(maxWidth: .infinity)` 撑满
卡宽居中。③**最小宽高**——旭日方形边长下限 360(新令牌
`{layout.spacemap-sunburst-min-side}`);宽度下限由主窗口最小宽 720 保障;方块
形态维持 220 最小高。

**Status:** done(2026-11-10,待合 develop)
用户明示,数值入表)

- [x] hover/点击命中与所画弧一致(含正上偏左的负角段)
- [x] 旭日方形边长 = max(卡宽, 360),卡内居中,高随宽
- [x] PulseCore 回归测试覆盖旧 bug 点位 + 周期折叠
- [x] DESIGN.md:版面纪律① / 旭日 bullet / 新令牌行

## Comments
- **交付(2026-11-10)**:①命中下沉 PulseCore:`SunburstArc.contains(angle:)`
  (相对起点偏移 < 弧宽,truncatingRemainder 周期折叠),视图 `hitArc` 直接传
  `atan2(dy, dx)`;PulseCore 弧角注释纠错为「标准极角」(错误注释正是 v1 挖坑
  之源)。②旭日尺寸:`onGeometryChange(for: CGFloat.self)` 测宽 → `sunburstSide`
  = max(卡宽, 360) → `.frame(height:)` + `.frame(maxWidth: .infinity)` 居中,
  aspectRatio 废弃。③新令牌 `{layout.spacemap-sunburst-min-side}` 360 入表。
- **验证**:lint + 全量 1201/1201(核心 719,含新增
  `testArcContainsStandardPolarAngle` 9 断言——含旧 +π/2 bug 会踩错的 a 尾段
  点位与负角/正角周期同点)。
- **欠目验(用户)**:①悬停任一弧,高亮与所指一致(重点验右上象限与正上偏左
  的窄段——旧 bug 的重灾区);②旭日在卡内居中、铺满卡宽;③窗口拉窄到最小,
  旭日不再明显缩小(边长下限 360)。
