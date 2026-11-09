# 01: 空间地图双形态——treemap 与两环旭日同画法切换

**What to build:** 空间地图卡支持两种展示形态:treemap(既定,v3)与两环旭日(v1 形态回归)。
用户拍板 C(2026-11-09),约束:**两种形态必须是同一种画法**——单个 SwiftUI `Canvas`
一次 draw call + 坐标反算命中(treemap = rect.contains;旭日 = atan2 角度 + sqrt 半径),
不留两套渲染方案,不引任何依赖(外部建议的 AppKit CGPath / Skia / Metal / ImGui 路线
不适用于 SwiftUI 工程,本仓 Canvas 先例已证零卡顿)。形态切换器在卡头,`@AppStorage`
记住上次选择(与 `settings.selectedPage` 同惯例);下钻 / 面包屑 / 密封与「其他」解释 /
悬浮信息行 / 「可清理」角标 / Finder / v1 只读,两形态共享同一套交互与文案。

**背景:** v1 旭日(逐弧 Shape + ZStack)2026-11-03 因卡顿被用户毙掉,根因是写法
不是形态;几何(`SunburstLayout`)与极坐标命中(v2,619533a)在 PulseCore / git
历史里都是对的。本次以 Canvas 写法回归旭日,与 treemap 并存。

**Status:** ready-for-agent(立票即分诊:单一视图文件 + DESIGN.md 收编,无新令牌值、
无 PulseCore 改动,几何复用既有 16 例测试;用户已拍板形态与画法,无待决产品点)

- [ ] 两形态各自渲染正确;切形态不丢下钻位置(drillPath 保留)
- [ ] 旭日命中可靠(极坐标反算,含跨 0 弧;中心圈 = 返回上级)
- [ ] 「可清理」角标两形态都有(旭日用小圆点;悬浮行「这块能清」共享)
- [ ] 形态选择跨子药丸 / 跨启动记住
- [ ] DESIGN.md 393 行(仍写已删的 CleanerSunburstView)收编为双形态

## Comments
