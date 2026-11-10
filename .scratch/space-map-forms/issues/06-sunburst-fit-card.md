# 06: 旭日尺寸正反馈撑爆修复——卡级宽探针,边长 = 卡内容宽 − 2×12

**What to build:** 用户实报(2026-11-10,05 上线后):「你是不是把半径写成直径了,
现在旭日比整个 app 面积还大,应该跟外层卡片差不多,小一个 padding」。
排查:半径/直径没写错(`min(宽,高)/2`);根因是 05 的测宽回写把
`onGeometryChange` 挂在**图表自身**的 frame 上——图表越宽 → ScrollView 内容宽
越大 → 量到的宽更大 → 边长再涨,正反馈失控。修:宽改由**卡级宽探针**提供
(`mapCard` 尾部量卡片给本节的宽,与图表自身尺寸无关,零反馈回路);旭日方形
边长 = max(卡内容宽 − 2×12, {layout.spacemap-sunburst-min-side} 360),
定宽定高、卡内居中——即用户拍板的「跟外层卡片差不多,每侧小一个 padding」
(12 = {spacing.card-padding-compact},既有令牌)。

**Status:** done(2026-11-10,待合 develop)
spacing 令牌,无新数值)

- [x] 旭日不再溢出/撑爆;边长 = 卡内容宽 − 24,卡内居中,随窗口宽窄伸缩
- [x] 宽探针挂卡级(量卡片给的宽),图表自身尺寸影响不到它
- [x] DESIGN.md:版面纪律① / 旭日 bullet / min-side 令牌行更新(记 05 正反馈翻案)

## Comments
- **交付(2026-11-10)**:宽度来源换卡级探针——`mapCard` 尾部
  `onGeometryChange` 量卡片给本节的内容宽(与图表自身尺寸无关);旭日
  `.frame(width: side, height: side) + .frame(maxWidth: .infinity)` 定宽定高
  居中,side = max(卡内容宽 − 2×12, 360)。12 = {spacing.card-padding-compact}
  既有令牌(用户拍板「跟外层卡片差不多,小一个 padding」)。
- **教训(05 根因)**:测宽挂在图表自身 frame 上,与 ScrollView 内容宽正反馈——
  图表越宽内容越宽、量到的更宽,直到比窗口还大。凡「尺寸跟随可用空间」的测量
  必须挂在不可被该尺寸影响的探针上。
- **验证**:lint + 全量 1213/1213(核心 721 + app 492;首轮误在主 checkout 跑
  过一次 develop 的门禁,已在本 worktree 重跑)。develop 并行推进
  p6-review-fixes(DESIGN.md 342-380 行段),与本票改动段不相交,合并零冲突。
- **欠目验(用户)**:旭日与外层卡片差不多大、每侧留 12pt 呼吸位;窗口拉宽圆
  跟着变大、拉窄变小但不小于 360;不再出现超出卡/窗口的巨圆。
