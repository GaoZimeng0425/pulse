# 02: 空间地图三修——标准件切换器 / 同色系深浅 / 最小可见阈值

**What to build:** 用户实报(2026-11-10,双形态上线次日走查):①「左右切换不是
标准的组件」→ 换 `PillTabBar`(.selectedOnly 图标形态,DESIGN.md §Components
标准件;原系统 segmented 被点名);②「颜色不好看」→ 用户拍板**同色系深浅**:
废十色强调色循环,整图 = 卡强调色(cleanAccent)按不透明度 0.85→0.30 均分,
大块深、小块浅,旭日外环 = 父色 −0.15,文字色随深浅切换(≥0.55 白 / 其余墨);
③「应该有最小大小」→ 两形态「其他」合并线统一提到 1%(块/弧小于整卷 1% 不再
单独画出;TreemapLayout 0.003→0.01、SunburstLayout 0.005→0.01 改默认值,
合并测试本就显式传 0.01,零断言改动)。

**顺带(用户同句立规):** DESIGN.md §Components 头部补总规矩——新 UI 一律优先
组装标准组件,覆盖不了的先补表再造,不私开同义新件(此前只对卡片家族有此约束)。

**Status:** done(2026-11-10,develop@61c0c59)

- [x] 切换器换 PillTabBar(.selectedOnly,square.grid.3x3 / chart.pie 图标)
- [x] 两形态同色系深浅;深浅两端文字色都可读;hover 提亮统一 +0.08
- [x] 两形态 1% 合并线;画出的块/弧都够看清
- [x] DESIGN.md:总规矩 + PillTabBar 第五处用法 + 空间地图卡行配色/阈值重写

## Comments

- **交付(2026-11-10)**:视图只动 `CleanerSpaceMapView.swift`——色阶出口
  `blockFill`(treemap)/`ColoredArc`(旭日)两处同一套常数(ramp 0.85→0.30、
  外环 −0.15、hover +0.08、文字色 ≥0.55 切换;密封 /「其他」恒墨色文字);
  切换器 `PillTabBar` + `formBinding`(raw ↔ enum);PulseCore 只改两个布局
  默认阈值(TreemapLayout 0.003→0.01、SunburstLayout 0.005→0.01),合并测试
  本就显式传 0.01,零断言改动。DESIGN.md:§Components 头部立「新 UI 一律优先
  组装标准件」总规矩(用户同句拍板)、PillTabBar 记第五处用法、空间地图卡行
  重写配色 / 切换器 / 1% 合并线。
- **验证**:worktree 内 `sh scripts/check.sh` 全绿,用例 1200/1200(核心 718 +
  app 482;本次未撞 hosted 间歇挂)。
- **欠目验(用户)**:起 app → 清理页 → 空间地图:①卡头切换器变药丸(未选中
  纯图标,选中展开「方块 / 旭日」文字);②两形态同一种青色、大块深小块浅,
  旭日外环比内环浅一档,浅块上文字是墨色、深块上是白色;③原来细小的块/弧
  消失并进「其他」;④悬停任一块轻微提亮且文字色不跳。
