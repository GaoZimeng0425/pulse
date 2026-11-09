# 01: 空间地图双形态——treemap 与两环旭日同画法切换

**What to build:** 空间地图卡支持两种展示形态:treemap(既定,v3)与两环旭日(v1 形态回归)。
用户拍板 C(2026-11-09),约束:**两种形态必须是同一种画法**——单个 SwiftUI `Canvas`
一次 draw call + 坐标反算命中(treemap = rect.contains;旭日 = atan2 角度 + sqrt 半径),
不留两套渲染方案,不引任何依赖(外部建议的 AppKit CGPath / Skia / Metal / ImGui 路线
不适用于 SwiftUI 工程,本仓 Canvas 先例已证零卡顿)。形态切换器在卡头,`@AppStorage`
记住上次选择(与 `settings.selectedPage` 同惯例);下钻 / 面包屑 / 密封与「其他」解释 /
「这块能清」轻桥 / 「可清理」角标 / Finder / v1 只读,两形态共享同一套交互与文案。

**背景:** v1 旭日(逐弧 Shape + ZStack)2026-11-03 因卡顿被用户毙掉,根因是写法
不是形态;几何(`SunburstLayout`)与极坐标命中(v2,619533a)在 PulseCore / git
历史里都是对的。本次以 Canvas 写法回归旭日,与 treemap 并存。

**Status:** done(2026-11-09,待合 develop)

- [x] 两形态各自渲染正确;切形态不丢下钻位置(drillPath 保留)
- [x] 旭日命中可靠(极坐标反算,含跨 0 弧;中心圈 = 返回上级)
- [x] 「可清理」角标两形态都有(旭日用小圆点;悬停白名单块/弧浮出「这块能清」)
- [x] 形态选择跨子药丸 / 跨启动记住(@AppStorage settings.spaceMapForm)
- [x] DESIGN.md 393 行(仍写已删的 CleanerSunburstView)收编为双形态
- [x] 不回退当日 ui-unify 追改三修(弹性高 / 悬停零重排 / 点击解释左上角浮层)

## Comments

- **交付(2026-11-09)**:全部落在 `CleanerSpaceMapView.swift`(重写)+ DESIGN.md
  两处收编。旭日两环几何零新代码——`SunburstLayout`/`SunburstArc` 在 PulseCore
  从未删除,视图层换 Canvas 写法回归;命中 = atan2+sqrt 反算(p4-cleaner/07 v2
  算法,含跨 0 弧两段判定),中心圈 ≤0.34R 点按 = 返回上级(顶层只提示不响应)。
  弧内标签 10.5pt semibold 白、份额阈值内才显示、左半圆翻转 180°、NSFont 量宽
  截断(Canvas 里 Text 无 maxWidth 约束);「可清理」弧内小圆点(药丸弧里放
  不下)。不透明度统一为一套:常规 0.75 / 密封 0.5 / hover 0.9(v1 的密封
  不透明实心随双形态归一废除)。
- **合入前撞车与对齐(2026-11-09)**:本分支开出后,并行会话在同文件落了三条
  用户实报修复(445f848 / 5ec95e8:图表区弹性高最小 220、废卡顶悬停信息行改
  图表内浮层按钮〔零重排〕、点击解释改左上角浮层)。直接合并会静默回退这三修,
  故 rebase 重解:两形态同守三条纪律——旭日的悬停信息改由**中心圈读数位**承载
  (悬停弧 → 名字 / 大小 / 占当前 N%,零重排),「这块能清」锚弧中角外缘浮出,
  与方块形态共用同一按钮配方(`bridgeButton`);并行会话未登记的 220 收编入表
  `{layout.spacemap-chart-min-height}`,`{layout.sunburst-diameter}` 改为旭日直径上限。
- **验证**:worktree 全量门禁命中已知间歇挂(测试宿主连接前挂死,构建阶段已
  过)——按既定退路 /tmp detach worktree 重跑 `sh scripts/check.sh`(rebase 后
  版本另跑一轮,结果见合并提交)。
- **欠目验(用户)**:起 app → 清理页 → 空间地图子药丸:①卡头出现「方块 / 旭日」
  双选;②切「旭日」= 两环 + 中心圈(根名 / 大小 / ↩ 返回上级);③鼠标悬停弧:
  中心圈换成该块名字 / 大小 / 占比,卡片其余部分不跳动;④白名单命中弧有青色
  小圆点,悬停浮出「这块能清」可点;⑤点内环块下钻、面包屑逐级跳回、中心圈点按
  回上级、点灰色密封块左上角浮出解释;⑥把主窗口拖矮:两形态图表区都跟着缩、
  页头不被挤;⑦切回「方块」下钻位置不丢;重启 app 后形态选择记得住。
