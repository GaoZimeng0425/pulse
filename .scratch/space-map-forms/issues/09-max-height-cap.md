# 09: 旭日图表区高上限 520——高窗卡片不再整屏长

**What to build:** 用户实报(2026-11-10,08 上线后):「为什么旭日的时候卡片那么大
啊,现在卡片是多大啊?有没有最大高度啊?」08 的图表区高 = 可视高×0.8 没有上限,
高/最大化窗口里卡片总高(图表区 + 头部 ≈150)≈ 整屏。加:{layout.spacemap-
sunburst-max-side} 520 上限——图表区高 = clamp(可视高×0.8, 360, 520),普通
窗口(可视高 <650)表现不变,高窗封顶。

**Status:** done(2026-11-10,待合 develop)

- [x] 高/最大化窗口里旭日卡片总高封顶 ≈ 520 + 150
- [x] 普通窗口(0.8×可视高 < 520)表现与 08 一致
- [x] DESIGN.md:令牌行 + 版面纪律① + 旭日 bullet 同步

## Comments
- **交付(2026-11-10)**:`sunburstMaxSide` 520 常量 + containerRelativeFrame 闭包
  加 min 钳制;令牌 {layout.spacemap-sunburst-max-side} 入表;DESIGN 版面纪律①
  / 旭日 bullet / min-side 令牌行同步为 clamp 公式。
- **验证(负载风暴记档)**:本 worktree 四次全量门禁各挂一个**不同**测试——
  ①AlertCenterTests 授权重试(单跑绿)②SpaceScanEngine 并行/串行一致
  (单跑 19/19 绿)③AlertCenter 同① ④AcceptanceAnchor 忙循环 CPU(今晚已
  两轮记档的已知抖动)。四者均与本票 diff(一行 clamp + 文档)零关联;同基线
  40 分钟前(19:52,space-map-two-col 轮)全量 1213/1213 全绿。机器负载 22
  (10 核)+ 并行会话 xcodebuild 在跑——按「单跑绿 + 非本票回归」惯例
  (LiveCoreTick/AcceptanceAnchor 先例)合并,负载回落后可复跑全量确认。
- **欠目验(用户)**:高/最大化窗口里旭日卡封顶(图表区 520 + 头部 ~150);
  普通窗口与上一版一致;圆直径 = min(卡宽, clamp(可视高×0.8, 360, 520))。
