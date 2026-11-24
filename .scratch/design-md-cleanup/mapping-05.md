# 05 去向表

DESIGN.md 四条旧条目(空间地图卡 L500–578、工具栏 L613–615、传感器卡文案与风扇条
L629–633、弹窗 DashboardView L646–650)逐条去向。共 67 条:空间地图 48、工具栏 5、
传感器 8、弹窗 6。

去向取值:已在代码 / 新写到代码 / 归组件规范(票 07)/ 归原则(票 07)/
删·代码自明 / 删·已废或历史 / 文档与代码不一致。

「本票范围外」= 实现或既有注释所在文件不在本票允许改动的六个文件里,未动。
其中 CleanerViews.swift 的 `DiskSpaceMapSection`(地-2、3、11、17、18)在本票进行
期间正被别的票并行改注释(内容属清理页);MetricTabViews.swift 的
`MetricIconTabBar`(弹-4、5)与 PulseCore 两个文件(地-19、23、48)目前没有看到
哪张票认领。

## 一、空间地图卡

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 地-1 | 空间地图住磁盘页,排第二块:主卡 / 空间地图 / 各卷 / 快照 / 读写排行 | 归原则(票 07) | MetricTabStack.swift `MetricTabStack.blocks` 的 `.disk` 分支 | 卡片顺序处留一句说明;「两窗同一套卡片组成」由票 07 写进原则 |
| 地-2 | 读清理扫描同一条管线 | 已在代码 | CleanerViews.swift `DiskSpaceMapSection`(本票范围外) | 类型注释首句已写;`.disk` 分支的说明里也带了 |
| 地-3 | 卡带就地「扫描整台 Mac / 重新扫描」按钮,与清理页头同一管线 | 文档与代码不一致 | CleanerViews.swift `DiskSpaceMapSection.body`;CleanerSpaceMapView.swift `SpaceMapSection.body` | 磁盘页只有「没扫过」和「空树」两个状态有就地按钮,扫描完成后磁盘页上没有「重新扫描」 |
| 地-4 | 清理页子药丸缩编为四项 | 已在代码 | CleanerViews.swift `CleanerSubTab`(本票范围外) | 四个 case(`overview / junk / apps / history`)自明;该文件本票进行期间正被别的票并行改注释 |
| 地-5 | 弹窗磁盘页不画地图(360pt 塞不下旭日) | 归原则(票 07) | MetricTabStack.swift `blocks` 的 `.disk` 分支(`if !isCompact, let cleanerModel`) | 留一句说明,点名这是原则里写明的例外之一 |
| 地-6 | 双形态同一画法:单个 Canvas 一次 draw call,不留两套渲染方案 | 已在代码 | CleanerSpaceMapView.swift 文件头;`// MARK: 方块形态` / `// MARK: 旭日形态` | 原夹在「形态史」段里,已改写进文件头骨架 |
| 地-7 | 命中一律坐标反算,不依赖形状 hit test(方块 rect.contains;旭日 atan2 + sqrt 半径) | 已在代码 | CleanerSpaceMapView.swift 文件头;`hitIndex` / `hitArc` 上方 MARK | 同上;MARK 去掉「v2 定谳写法」 |
| 地-8 | 形态切换 = 卡头 PillTabBar `.selectedOnly` 双项图标 | 已在代码 | CleanerSpaceMapView.swift `formPicker` | 去掉「原 segmented 被点名」的来历;图标名代码自明 |
| 地-9 | `settings.spaceMapForm` 记住上次;默认形态 = 方块 | 已在代码 | CleanerSpaceMapView.swift `SpaceMapSection.formRaw`、`SpaceMapForm` | 键名与默认值字面可读;`SpaceMapForm` 注释去掉「v3 既定形态」 |
| 地-10 | 切换形态不重置下钻位置(下钻由 DashboardModel 持有,切 tab / 切页不丢) | 已在代码 | CleanerSpaceMapView.swift `formPicker` | 补了半句「下钻位置由宿主 DashboardModel 持有」 |
| 地-11 | 地图块住在磁盘页外层页面滚动里,不自带滚动(嵌套滚动是旧坑) | 已在代码 | CleanerViews.swift `DiskSpaceMapSection`(本票范围外) | 类型注释「①不套子页 ScrollView」已写 |
| 地-12 | 两形态图表区高同式 = clamp(滚动视口 × 份额, 形态下限, 上限);`containerRelativeFrame` 量的是滚动视口 | 已在代码 | CleanerSpaceMapView.swift `treemapBody` 的 `.containerRelativeFrame` 处;常量 `chartMinHeight` / `sunburstViewportShare` / `sunburstMaxSide` | 改写:去掉字面可读的数值,留「同式」和「为什么不用弹性 maxHeight」。顺手改齐 `chartMinHeight` 注释里已过时的一句(见报告不一致清单 ⑤) |
| 地-13 | 旭日直径 = min(卡内容宽, 图表区高),卡内居中 | 已在代码 | CleanerSpaceMapView.swift `sunburstRadius` | 从旭日 `.containerRelativeFrame` 处的旧注释移到这里 |
| 地-14 | 历代已废的七版直径 / 布局方案叙述 | 删·已废或历史 | — | 只留两句还会再踩的坑:弹性 maxHeight 在页面滚动里塌到最小高(地-12);量图表自身的宽定直径会与内容宽正反馈撑爆(地-13) |
| 地-15 | 悬停零重排:卡内不出现 / 消失任何占行元素,信息与按钮浮在图表内 | 已在代码 | CleanerSpaceMapView.swift `mapCard` 类型注释 | 原先文件头一句 + 四处零散提法,收成一处 |
| 地-16 | 密封 / 叶子 /「其他」点击解释 = 图表左上角浮层胶囊,单行截断、不吃点击,不占卡内一行 | 已在代码 | CleanerSpaceMapView.swift `noticeOverlay` | 去日期与用户实报,留「做成占位行会常年空一截」;颜色与透明度代码自明 |
| 地-17 | 地图卡在上、扫描摘要卡在下(上下堆叠) | 已在代码 | CleanerViews.swift `DiskSpaceMapSection`(本票范围外) | 类型注释已写「完成 = 地图卡 + 结果摘要卡,上下堆叠」 |
| 地-18 | 摘要卡统计行 `ViewThatFits` 折行(整行 / 2+2 / 2+1) | 已在代码 | CleanerViews.swift `DiskSpaceMapSection.summaryCard`(本票范围外) | 行内注释已写。立表时那段注释还带着两列版式的来历;该文件正被别的票并行改注释 |
| 地-19 | 方块 = squarify(`TreemapLayout`) | 已在代码 | Packages/PulseCore/Sources/PulseCore/TreemapLayout.swift(本票范围外);视图侧 `// MARK: 方块形态` | 核心包注释已写算法与「只布一层」 |
| 地-20 | 方块块内 名字 + 实际占用(放得下时);高块底部百分比 10.5pt 等宽小标 | 删·代码自明 | CleanerSpaceMapView.swift `treemapBody` 的 Canvas | 阈值与字号字面可读。「等宽登记例外」属 DESIGN.md 字号节,不在本票四条内 |
| 地-21 | 「可清理」大块药丸 / 小块圆点 | 已在代码 | CleanerSpaceMapView.swift `treemapBody`(轻桥角标段) | 行内注释已写「太小画不下文字时退化为一个点」 |
| 地-22 | 悬停白名单块(够大)时「这块能清」浮在该块右上角 | 已在代码 | CleanerSpaceMapView.swift `treemapBridgeButton` | 改写:去掉错挂在这里的配色说明(家在 CleanerSpaceMapPalette.swift);140×48 字面可读 |
| 地-23 | 旭日两环:内环 = 当前根的子辈、外环 = 孙辈;叶子与密封块延伸占满外环 | 已在代码 | Packages/PulseCore/Sources/PulseCore/SpaceMap.swift `SunburstLayout`、`SunburstArc.ring`(本票范围外) | 核心包文件头第 3 条与字段注释已写 |
| 地-24 | 旭日命中 = atan2 标准极角直接比对,不做原点换算(回归测试钉死) | 已在代码 | CleanerSpaceMapView.swift `hitArc` | 去日期与用户实报,留「多加 π/2 会恒偏 90°」与测试所在 |
| 地-25 | 环形半径 0.28–0.65 / 0.65–0.99、中心圈 0.26 | 删·代码自明 | CleanerSpaceMapView.swift `sunburstBody` / `drawCenter` / `hitArc` | 数值字面可读 |
| 地-26 | 环形比例没有具名常量,绘制、命中、中心圈点按各写一遍 | 新写到代码 | CleanerSpaceMapView.swift `sunburstBody` 类型注释 | 改一处要同步其余——代码读不出这一点 |
| 地-27 | 弧间角向留缝 | 已在代码 | CleanerSpaceMapView.swift `sunburstBody`(`let pad` 上方) | 去掉「v1 同款」 |
| 地-28 | 弧内标签:份额阈值内才显示;左半圆翻转 180°;文字沿半径排;长度上限 = 本环带宽 ×0.9 | 已在代码 | CleanerSpaceMapView.swift `sunburstBody` 标签段 | 去日期与用户实报,留「按弧长量会压到相邻环的名上」 |
| 地-29 | 名字优先:大小后缀放得下才带,悬停中心圈兜底全读数 | 已在代码 | CleanerSpaceMapView.swift `arcLabel` | 去日期与用户实报 |
| 地-30 | 弧内文字色随弧深浅切换(≥0.5 白、其余墨) | 删·代码自明 | CleanerSpaceMapView.swift `sunburstBody` 标签段;CleanerSpaceMapPalette.swift `blockFill` | 判据字面可读;「方块与弧同一判据」写在 `blockFill` 注释里 |
| 地-31 | 旭日「可清理」= 弧内小圆点 | 已在代码 | CleanerSpaceMapView.swift `sunburstBody` | 行内注释已写「药丸文字弧里放不下」 |
| 地-32 | 中心圈 = 悬停读数位(悬停弧 → 名字 + 实际占用 + 占当前根份额;密封 / 合并块换说明;不悬停 → 当前根 + 返回上级;顶层为下钻提示) | 已在代码 | CleanerSpaceMapView.swift `drawCenter` | 改写:去掉错挂在这里的配色说明,只留读数规则 |
| 地-33 | 点按中心圈 = 返回上级(顶层不响应) | 已在代码 | CleanerSpaceMapView.swift `handleSunburstTap` | 去掉「v1 同款」 |
| 地-34 | 悬停白名单弧时「这块能清」锚在该弧中角外缘、钳制在图内 | 已在代码 | CleanerSpaceMapView.swift `sunburstBridgeButton` | 改写:去掉重复的「零重排」提法(家在地-15) |
| 地-35 | 配色 = 分区完全异色、鲜亮;不退回同色系深浅,不靠压饱和求柔和 | 已在代码 | CleanerSpaceMapPalette.swift `sectionColors` | 去掉「三轮拍板」经过,只留结论 |
| 地-36 | 提饱和只作用于地图,不动全 app 的 accent 令牌;密封与「其他」灰系不受影响 | 已在代码 | CleanerSpaceMapPalette.swift `vivid` | 去日期;「不动 accent 令牌」原埋在历史句里,提到句首 |
| 地-37 | 顶层块按序循环十个 accent 令牌 | 已在代码 | CleanerSpaceMapPalette.swift `sectionColors` | 数组自明 |
| 地-38 | 旭日内环每支一色、外环 = 父色淡一档 | 新写到代码 | CleanerSpaceMapPalette.swift `coloredArcs`;常量 `sectionChildStep` 上方 | 原写在 `sectionColors` 的长注释里、离代码远。保留原注释的「布局按父-子顺序产出」:外环靠上一个内环弧认父色 |
| 地-39 | hover 一律 +0.08(封顶 0.95) | 删·代码自明 | CleanerSpaceMapPalette.swift `hoverBoost`、`blockFill` | 字面可读 |
| 地-40 | 密封块、「其他」合并块用灰系(不可下钻) | 已在代码 | CleanerSpaceMapPalette.swift `blockFill` | 新写一句原因;颜色与透明度字面可读 |
| 地-41 | 「其他」合并线两形态统一 1% | 新写到代码 | CleanerSpaceMapView.swift `treemapArea` | 两处是各自的默认参数、互不引用——「必须同值、改一处同步另一处」代码读不出。「整卷」口径见报告不一致清单 ② |
| 地-42 | 「这块能清」浮层按钮两形态同一配方,help 文案明示判定来源与地图只读 | 已在代码 | CleanerSpaceMapView.swift `bridgeButton` | 配方字面可读。`onGoToJunk` 属性注释去掉「tab-regroup/03 起地图住磁盘页」的来历,只留票号 |
| 地-43 | 点块下钻;密封块不可下钻 | 删·代码自明 | CleanerSpaceMapView.swift `handleTap` | 分支与提示文案自明;「密封不可删、零暗示(ADR-0008)」行内注释已有 |
| 地-44 | 面包屑逐级可跳(› 分隔、末级加粗);末尾不放返回按钮,回顶层点首级 | 归组件规范(票 07) | CleanerSpaceMapView.swift `breadcrumbRow` | 只留一句指向规范。票 07 立「面包屑」条目时要带上:末尾不放带「›」的返回项(会被读成下一层),回顶层点首级 |
| 地-45 | 卡头「在 Finder 中显示」 | 删·代码自明 | CleanerSpaceMapView.swift `mapCard` | 按钮字面可读;文件头骨架点了名。卡头动作按钮配方的行内注释去掉「不再独一份 .small bordered」 |
| 地-46 | 块与弧不做任何动画(meter 条同款纪律) | 新写到代码 | CleanerSpaceMapView.swift `mapCard` 类型注释 | 原先没有注释;「不做」是纪律不是遗漏,必须写出来 |
| 地-47 | 地图只读:卡上没有任何删除控件(ADR-0008) | 新写到代码 | CleanerSpaceMapView.swift `bridgeButton` 类型注释 | 原先只在 help 文案和「零暗示(ADR-0008)」里侧写 |
| 地-48 | 树变换与两种几何全在 PulseCore(firmlink 提升、密封折叠),视图只描边配色命中 | 已在代码 | Packages/PulseCore/Sources/PulseCore/SpaceMap.swift 文件头(本票范围外);视图侧 CleanerSpaceMapView.swift 文件头 | 核心包文件头三件事已写;视图文件头骨架留一句 |

## 二、工具栏

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 栏-1 | 药丸 tab 挂 `.principal` | 已在代码 | MainWindowView.swift `body` 的 `.toolbar`;`MainSearchField` 类型注释 | 修饰符字面可读;`MainSearchField` 注释里写了「药丸 tab 占了 principal」 |
| 栏-2 | 搜索框定宽 132pt + 齿轮挂 `.primaryAction` | 已在代码 | MainWindowView.swift `MainSearchField`(`.frame(width: 132)` 处);`.toolbar` | 改写定长处的注释:去掉「原 168」与用户拍板,留「宁可搜索框窄,不要溢出菜单」 |
| 栏-3 | 标题不进工具栏(`.toolbar(removing: .title)`) | 已在代码 | MainWindowView.swift `.toolbar(removing: .title)` 上方 | 既有注释无日期、有原因(标题占宽是溢出推手;NSWindow.title 仍是 Pulse,离屏守卫靠它),未动 |
| 栏-4 | 任何新增工具栏项必须重新验证 720 最小窗宽不触发 `>>` 溢出菜单 | 新写到代码 | MainWindowView.swift `.toolbar {` 开头 | 替换原注释里的「P2 扩到 11 枚」「内距 12→9 是 P1 早期」两段来历 |
| 栏-5 | 720 最小窗宽预算(全局原则) | 归原则(票 07) | MainWindowView.swift `.toolbar {` 开头 | 留一句指向(DESIGN.md §Layout、§Do's and Don'ts 的现有表述,由票 07 改写) |

## 三、传感器卡文案与风扇条

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 传-1 | 风扇转速 rpm 0 写「停转」(真读数),不写「0 rpm」 | 已在代码 | SmcCardViews.swift `SmcFanText.speed` | 去掉回指「DESIGN.md §Components 传感器卡」 |
| 传-2 | 读不到 / 无风扇写「—」,不是 0 rpm | 已在代码 | SmcCardViews.swift `SmcDerivedCardView.fanRow` | 注释已写「不伪造 0 rpm」 |
| 传-3 | 风扇 meter 按该扇上下限归一,钳 0…1 | 已在代码 | SmcCardViews.swift `SmcFansCardView` 类型注释;Packages/PulseCore/Sources/PulseCore/SmcModel.swift `SmcFanReading.speedFraction` | 两处都已有;视图侧去掉「C 拍板」 |
| 传-4 | 上下限不可用(max ≤ min)给空条 | 已在代码 | Packages/PulseCore/Sources/PulseCore/SmcModel.swift `speedFraction`(本票范围外);SmcCardViews.swift `sharedLimitsNote` | 核心包注释写全了原因;视图侧「读不到的扇不标,与空条同一口径」 |
| 传-5 | 上下限标注文案「下限 N · 上限 M rpm」 | 已在代码 | SmcCardViews.swift `SmcFanText.limits` | 字面自明;`fanRow` 注释去掉「ui-unify 追改」 |
| 传-6 | 上下限标注用 `{typography.micro}` 10.5 tertiary | 文档与代码不一致 | SmcCardViews.swift `SmcFansCardView.fanRow`;`sharedLimitsNote` | 逐扇行下的标注在主窗口是 12pt,不是 10.5;见报告不一致清单 ③ |
| 传-7 | 全部风扇上下限相同 → 卡头注记写一次;不同 → 逐扇行下各写;两处不同时出现 | 已在代码 | SmcCardViews.swift `SmcFansCardView` 类型注释、`sharedLimitsNote` | 已写全 |
| 传-8 | 派生卡最快风扇行多扇时数值前带扇名 | 已在代码 | SmcCardViews.swift `SmcDerivedCardView.fanRow` | 已写全 |

## 四、弹窗 DashboardView

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 弹-1 | 面板 `{layout.popover-size}` 360×648 定尺寸 | 已在代码 | DashboardView.swift `panelSize` | 去用户拍板与「定高 A」;留「不读 fittingSize,两边各算必错位」 |
| 弹-2 | 底部操作「开窗靠左、设置 + 退出靠右」 | 已在代码 | DashboardView.swift `footer` | 去「用户拍板」与「决定记录于工单 05 Comments」。同在底排里的齿轮动作注释去日期、用户实测与「不再响应」的来历;`DashboardView` 类型注释收成纯骨架 |
| 弹-3 | 退出 = 纯图标 | 文档与代码不一致 | DashboardView.swift `footer` | 轻微:文档只点了退出,代码三个按钮全是纯图标;注释按代码写。见报告不一致清单 ④ |
| 弹-4 | 顶部图标 tab 槽位单行满宽均分(32pt 定宽槽 11 枚超出 332pt 内容区) | 已在代码 | MetricTabViews.swift `MetricIconTabBar` 类型注释(本票范围外) | 实现不在我可改的文件里,且那里已有注释;按「一条规矩一个家」没有在 DashboardView.swift 重复写。`DashboardView` 类型注释点了它的名字以便找到 |
| 弹-5 | 均分只收窄不溢出,与主窗口工具栏 720 预算同一哲学 | 已在代码 | 同上(`MetricIconTabBar` 类型注释末句) | 同上 |
| 弹-6 | 页头 = `PageHeader` 紧凑档(页名;本机一行只在总览)+ 右侧运行时长 | 已在代码 | DashboardView.swift `pageHeader` | 去日期与用户拍板;加「两窗不各写一份」 |

## 交接给票 07 / 票 08

**票 07 立条目时要接走的:**

- 归组件规范:地-44 面包屑——› 分隔、非末级可点、末级加粗、末尾不放带「›」的
  返回项(会被读成当前层级的下一层)、回顶层点首级。代码侧现在只剩一句指向,
  这条「为什么末尾不放返回项」只靠票 07 写进规范。
- 归原则:地-1、地-5「主窗口与弹窗同一套卡片组成」(传感器明细卡与空间地图只在
  主窗口,写成规则的一部分);栏-5「720 最小窗宽预算」。

**本票范围外、但已是某条规矩唯一的家、还带着历史叙述的三处(DESIGN.md 那几段
删掉后需要有人按同一标准改写):**

- MetricTabViews.swift `MetricIconTabBar` 类型注释(弹-4、5):「P2 扩到 11 枚后的
  修复:…原 32pt 定宽槽 11 枚要 392pt,右端被裁切;改由 HStack 均分」。
- CleanerViews.swift `DiskSpaceMapSection` 类型注释(地-2、11、17)与
  `summaryCard` 行内注释(地-18):「上下堆叠 = …拍板原样」「与原清理页子页的两处
  差异」「…前的旧坑」「半宽卡(两列版式,…)」。立表时这个文件正被别的票并行改注释。
- Packages/PulseCore/Sources/PulseCore/SpaceMap.swift 文件头(地-23、48)与
  TreemapLayout.swift 文件头(地-19):前者带探针日期与「此前注释写错」的经过,
  后者是「旭日图 → 条形图 → treemap」的选型史。

**票 08 核回指时会碰到的(本票新写或沿用的 DESIGN.md 引用):**

- CleanerSpaceMapView.swift `breadcrumbRow`:「DESIGN.md 的面包屑组件规范」——
  依赖票 07 立条目,目前 DESIGN.md 里还没有这一条。
- MetricTabStack.swift `.disk` 分支:按新原则名引「主窗口与弹窗同一套卡片组成」——
  DESIGN.md 现在的对应条目叫「主窗口 / 弹窗同内容」,票 07 改名后才对得上。
- MainWindowView.swift `.toolbar`:「DESIGN.md §Layout 与 §Do's and Don'ts」。
- 令牌名:`{layout.spacemap-chart-min-height}`、`{layout.spacemap-sunburst-min-side}`、
  `{layout.spacemap-sunburst-viewport-share}`、`{layout.spacemap-sunburst-max-side}`
  (CleanerSpaceMapView.swift 常量注释),`{layout.popover-size}`(DashboardView.swift
  `panelSize`)。四个空间地图令牌都在用,票 07 删已废令牌时别误删。
