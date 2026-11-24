# 04 去向表

DESIGN.md 五条旧条目(L372–499)逐条去向:清理页子页命名 6 条、清理总览页 36 条、
清理页舒适密度档 32 条、清理清单行 17 条、设置「清理」页 6 条,共 97 条。

去向分布:已在代码 61 / 新写到代码 2 / 归组件规范(票 07)4 / 删·代码自明 16 /
删·已废或历史 6 / 文档与代码不一致 8。

去向取值:已在代码 / 新写到代码 / 归组件规范(票 07)/ 删·代码自明 /
删·已废或历史 / 文档与代码不一致。

「说明」列里的三个词:**改写** = 该处原有同类注释,本次按标准重写(去日期与来历、
去字面可读的数值、去指向将删条目的回指);**未动** = 原有注释已符合标准,原样保留;
**新增** = 原来没有这条规矩的说明,本次新写。「范围外」= 实现或既有注释所在文件不在
本票允许改动的十个文件里,未动。

页面骨架写在 `CleanerViews.swift` 文件头(只出现在主窗口、主窗口不给本页套外层滚动、
各子页自己管滚动);清单卡、总览子页、清单家族各有自己的文件头骨架。

## 一、清理页子页命名(L372–377)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 名-1 | 四个子药丸 = 总览 / 全部清单 / 应用 / 清理历史 | 已在代码 | CleanerViews.swift `CleanerSubTab.title`、`CleanerTabView.subPillBar` | 未动;文案字符串本身就是规格 |
| 名-2 | 总览居首,且为默认落地子页 | 已在代码 | CleanerViews.swift `CleanerSubTab`(case 上方)、`CleanerTabView.subTab` 初值 | 改写:只留顺序的理由(总览 = 默认落地,进页先看能省多少;只读的清理历史殿后) |
| 名-3 | 清单子页标题 =「全部清单」 | 已在代码 | CleanerViews.swift `CleanerSubTab.title`;CleanerJunkViews.swift `JunkListCard.header` | 标题字符串本身;卡头处改写,点明标题即子页名 |
| 名-4 | 改名时组名不变 | 删·已废或历史 | —(组名在 PulseCore `JunkGroup.title`) | 那一次改名的注脚,没有现行约束 |
| 名-5 | 内部标识 `CleanerSubTab.junk` 不随标题改名(改名只是文案层) | 已在代码 | CleanerViews.swift `CleanerSubTab.title`(`case .junk` 上方) | 改写并搬家:从文件头挪到标识旁,补上原因(下钻、跨页轻桥都按它落页) |
| 名-6 | 两次改名的经过、先例 p4-uninstaller/08、丙案 v2、空间地图迁出后缩编 | 删·已废或历史 | — | 来历叙述 |

## 二、清理总览页(L378–422)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 总-1 | 组成:Hero 卡 + 模块大卡(2 列自适应)+ 废纸篓卡,页内整页滚动 | 已在代码 | CleanerOverviewViews.swift 文件头 | 改写成页面骨架;补了「废纸篓卡在网格末位、清单为空时独占一行」 |
| 总-2 | Hero 内距 24×28、圆角 `{rounded.card}` | 删·代码自明 | CleanerOverviewViews.swift `OverviewHeroCard.body` | 数值字面可读 |
| 总-3 | Hero 卡壳走零件 `cardShell`,不另立卡壳 | 已在代码 | CleanerOverviewViews.swift `OverviewHeroCard.body`(`cardShell(padded: false)` 上方) | 改写:只留「内距随版式自定,所以 padded: false」 |
| 总-4 | 大数字 `{figure-main}` 44 | 删·代码自明 | CleanerOverviewViews.swift `OverviewHeroCard.body`(`FigureSize.main`) | 数值字面可读 |
| 总-5 | 大数字只取 `FigureSize` 档位 | 已在代码 | CleanerOverviewViews.swift `OverviewHeroCard.figureText` | 改写:去掉具体档位数值 |
| 总-6 | caption「可回收 · 其中 X 可放心清」,X 染 positive | 删·代码自明 | CleanerOverviewViews.swift `OverviewHeroCard.caption` | 文案与颜色字面可读 |
| 总-7 | 构成条:三段色、按三段合计归一、inuse 段最小可见宽、为 0 不画 | 已在代码 | CleanerOverviewViews.swift `CompositionBar`(类型注释、`minInUseFraction`);三段互斥切分的口径在 PulseCore `JunkOverview.swift` 文件头 | 类型注释未动;`minInUseFraction` 的注释改写;Hero 调用处的纯数值注释删掉 |
| 总-8 | 图例四项:可安全清理 / 先检查 / 在用保护 /「另有废纸篓 X」;废纸篓色块取 `{junk-trash}` | 已在代码 | CleanerOverviewViews.swift `OverviewHeroCard.legend` | 改写:去掉字号数值 |
| 总-9 | 废纸篓 X 读不到 / 没查时写「—」,不写 0 | 已在代码 | CleanerOverviewViews.swift `OverviewHeroCard.trashBytes`(属性注释)、`legend` | 未动 |
| 总-10 | 主按钮「一键清理 X 安全项…」:accent-clean、`.large` borderedProminent、X = safe 合计 | 删·代码自明 | CleanerOverviewViews.swift `OverviewHeroCard.body` | 字面可读 |
| 总-11 | 一键 = 全选全部 safe 且非在用的候选 → 既有确认单;默认勾选仍全不勾;先检查与在用项永不在内 | 已在代码 | Pulse/Features/CleanerModel.swift `selectAllSafeAndRequestClean`(范围外);CleanerViews.swift `CleanerTabView.body` 的 `onOneClickClean` | 判据与「不改默认态」在模型处,未动;视图处改写(选完切到清单再弹确认单) |
| 总-12 | 图例统一配方:Hero / 模块大卡 / 废纸篓卡三处同一 `OverviewLegendItem` | 已在代码 | CleanerOverviewViews.swift `OverviewLegendMetrics`(类型注释) | 改写:只留「为什么单出处」 |
| 总-13 | 图例数值:文字 11、色块 8×8 圆角 2.5、块字距 4、项间 12、条到图例 8 | 删·代码自明 | CleanerOverviewViews.swift `OverviewLegendMetrics`、`OverviewHeroCard.body` | 数值字面可读;`{spacing.unit}` `{spacing.group-gap}` 令牌名留在注释里 |
| 总-14 | 模块大卡最多七张(六品类 + 废纸篓),2 列自适应(单卡最小宽 340、列距 12) | 已在代码 | CleanerOverviewViews.swift `OverviewCardGridMetrics`、`CleanerOverviewSection.overviewScroll` | 数值字面可读;空组缺位见总-16 |
| 总-15 | 列数上限 2,不随超宽屏拉列 | 新写到代码 | CleanerOverviewViews.swift `OverviewCardGridMetrics.maximumColumns` | 新增:原来没有说明为什么封顶 |
| 总-16 | 空组不出卡,不硬造 | 已在代码 | PulseCore `JunkOverview.swift` `JunkOverviewAggregator.overview`(范围外) | 未动;视图只遍历 `overview.rows` |
| 总-17 | 模块大卡卡壳走 `cardShell` 全尺寸档 | 删·代码自明 | CleanerOverviewViews.swift `OverviewModuleCard.body` | 字面可读 |
| 总-18 | 图标瓦 42(`CategoryIconTile`)+ 类别身份色 `{junk-*}` + 白符号 | 已在代码 | CleanerOverviewViews.swift `OverviewModuleCard.headerRow`;身份色单出处在 MetricAccent.swift `JunkGroup.identityColor` | 未动;`overviewSymbolName` 注释里的「42pt」去掉 |
| 总-19 | 类名 17 bold + 一句人话 11 secondary | 删·代码自明 | CleanerOverviewViews.swift `OverviewModuleCard.headerRow`、`JunkGroup.overviewTagline` | 数值字面可读;`overviewTagline` 注释去掉「原型蓝本」 |
| 总-20 | 模块大卡大数字 `{figure-card}` 24 | 删·代码自明 | CleanerOverviewViews.swift `OverviewModuleCard.headerRow`(`FigureSize.card`) | 数值字面可读 |
| 总-21 | 卡内构成条高 7 圆角 3.5,inuse > 0 最小可见宽 3%,空段不画 | 已在代码 | CleanerOverviewViews.swift `OverviewModuleCard.body` → `CompositionBar` | 同总-7 |
| 总-22 | 模块大卡图例:可安全清理 X / 先检查 X(> 0 才显)/ 在用 X(> 0 才显)/ N 项 | 已在代码 | CleanerOverviewViews.swift `OverviewModuleCard.legendRow` | 改写:去掉「原型同款」 |
| 总-23 | 「最大一项:名称 · 大小」行:分隔线 + 上距 + 右缘 chevron | 删·代码自明 | CleanerOverviewViews.swift `OverviewModuleCard.largestRow` | 字面可读 |
| 总-24 | 整卡可点 = 下钻该品类清单 | 已在代码 | CleanerOverviewViews.swift `OverviewModuleCard`(类型注释) | 改写 |
| 总-25 | 下钻空态走 `CardEmptyState`,与全量空态同族 | 已在代码 | CleanerJunkViews.swift `JunkListCard.body` | 改写 |
| 总-26 | 废纸篓卡是变体:无构成条;读数大数字同档 +「N 项」;多卷才显「所有卷汇总」 | 已在代码 | CleanerOverviewViews.swift `OverviewTrashCard`(MARK 行、`readingSlot`、`metaRow`) | MARK 行未动 |
| 总-27 | 独立「清空废纸篓…」按钮:普通 bordered、`.large`;复用 `beginEmptyTrash` → 二次确认流 | 删·代码自明 | CleanerOverviewViews.swift `OverviewTrashCard.actionRow`、`CleanerOverviewSection.trashCard` | 字面可读 |
| 总-28 | 「清空废纸篓」入口在废纸篓卡上,页头不放 | 已在代码 | CleanerViews.swift `CleanerPageHeader.body`;CleanerOverviewViews.swift `CleanerOverviewSection.trashCard`(方法注释) | 页头处改写(原写的是按钮尺寸与迁移经过) |
| 总-29 | 点卡不下钻 | 已在代码 | CleanerOverviewViews.swift `OverviewTrashCard`(MARK 行) | 未动 |
| 总-30 | 读数四态:读不到 ≠ 空,只有查到了(或刷新在飞时的上次读数)才出数字 | 已在代码 | CleanerOverviewViews.swift `OverviewTrashCard`(`phase` 注释、`readingSlot`、`metaText`);状态机在 Pulse/Features/CleanerOverviewTrashCounter.swift `OverviewTrashPhase`(范围外) | `readingSlot` 注释改写;`busy` 注释顺带按代码改齐(见报告不一致清单 ⑭) |
| 总-31 | 进页不自动清点:首次读数只来自用户点击;清点成功过之后进页才自动刷新;读失败不自动重试 | 已在代码 | CleanerOverviewViews.swift `CleanerOverviewSection.body`(`.task` 上方);门卫在 CleanerOverviewTrashCounter.swift `autoRefreshUnlocked`(范围外) | 未动 |
| 总-32 | 下钻返回行:「‹ 总览」+ 品类标题 +「X · N 项」+「全选安全项」;排序 seg 不进返回行 | 已在代码 | CleanerJunkViews.swift `JunkListCard.drillBackRow`(方法注释) | 改写 |
| 总-33 | 下钻里的条目行形态零新(继续 `RowMetrics` / `CleanerListMetrics` 与项目大卡) | 已在代码 | CleanerJunkViews.swift `JunkListCard.groupRows`(方法注释) | 未动 |
| 总-34 | 总览 ↔ 清单切换不丢勾选(勾选在 `CleanerModel.selection`) | 已在代码 | CleanerViews.swift `CleanerTabView.junkFilter`(属性注释) | 未动 |
| 总-35 | 返回 / 药丸直切 = 回总览并清过滤 | 已在代码 | CleanerViews.swift `CleanerTabView.junkFilter`、`pillSelection`(属性注释) | 未动 |
| 总-36 | 原型数值收编的叙述(26×28 收 4pt 网格、52 收 44、16 收 17、18×20 收 16) | 删·已废或历史 | — | 来历叙述;现行值在代码里 |

## 三、清理页舒适密度档(L423–469)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 密-1 | 清理页的行与控件走舒适密度档;页面专属尺寸出处 `CleanerListMetrics`,委托 `RowMetrics` 舒适档,不借排行的紧凑档 | 已在代码 | CleanerListCommonViews.swift `CleanerListMetrics`(类型注释) | 改写 |
| 密-2 | 行数值:图标 24 / 名称 14.5 medium / 副文 12 / meter 120 / 行内距 14×10 / 数值 14.5 semibold 等宽 | 删·代码自明 | RowMetrics.swift `RowMetrics`(舒适档);CleanerListCommonViews.swift `CleanerListMetrics` | 数值字面可读(范围外) |
| 密-3 | meter 归一口径恒为全量榜首(下钻视图里条的长短与全量一致) | 已在代码 | CleanerJunkViews.swift `JunkListCard.groupRows`(方法注释) | 未动 |
| 密-4 | 数值定宽列:同卡各行同一竖线,不按内容撑宽 | 已在代码 | CleanerListCommonViews.swift `CleanerListMetrics.valueWidth` | 改写:不再点名量的是哪个读数(文档与原注释都只写一个,代码量两个,见不一致 ⑩) |
| 密-5 | 勾选框 `.controlSize(.large)` | 删·已废或历史 | — | 系统勾选框已换成自绘 `CleanerCheckBox`,没有 controlSize |
| 密-6 | 安全档 chip = `ChipView.regular`(11 semibold、内距 10×3) | 删·代码自明 | CleanerJunkRowViews.swift `TierChip`;档位数值在 ChipView.swift `ChipView.Profile.regular` | 字面可读;尺寸本身归「状态芯片」条目 |
| 密-7 | 子页搜索框 `CleanerSearchField`(与分段控件等高、同工具栏搜索框配方) | 归组件规范(票 07) | CleanerAppUninstallSheet.swift `CleanerSearchField` | 页面注释里的来历(CleanerAppViews.swift `controlsBar`)删掉;组件定义处的说明保留,另留一句坑:别换回系统 `.roundedBorder` 输入框 |
| 密-8 | 组头标题 14.5 bold + 总量 12 | 文档与代码不一致 | CleanerJunkViews.swift `JunkListCard.groupHeader` | 文档两处分别写 14.5(本行)与 16(密-10);代码是 17 bold。注释不写数值 |
| 密-9 | 子页药丸条 = `PillTabBar.comfortable`;主窗口工具栏 / 历史页不受影响 | 已在代码 | CleanerViews.swift `CleanerTabView.subPillBar` | 改写 |
| 密-10 | 组头:组名 + 总量在左,右侧 =「全选安全项」+ 大小 ⇄ 新旧 seg(seg 取清理页强调色);组与组之间 18 | 已在代码 | CleanerJunkViews.swift `JunkListCard.groupHeader`(方法注释) | 改写;字号不一致见密-8,其余数值字面可读 |
| 密-11 | 动作按钮与 segmented 一律 B 档:按钮 `.controlSize(.large)`,seg 保持 regular(不再 mini) | 新写到代码 | CleanerListCommonViews.swift `CleanerListMetrics`(类型注释末句) | 新增到单一出处;原来「B 档」散在页头按钮、动作条两处,已收拢 |
| 密-12 | 项目大卡头排 14.5 bold、上下距 10、无独立背景 | 删·代码自明 | CleanerJunkViews.swift `JunkListCard.projectCard` | 字面可读 |
| 密-13 | 自绘勾选框 `CleanerCheckBox`:四态;destructive 场景 tint 取 `{state-negative}`;纯显示件,点击语义在宿主行 | 归组件规范(票 07) | CleanerListCommonViews.swift `CleanerCheckBox`;destructive 用法在 CleanerAppRowViews.swift `LeftoverDisclosure.actionRow` | 组件定义处的自述改写(去日期、去尺寸),规矩正文留给票 07 |
| 密-14 | 条目 = 独立小卡(抬升底、12 圆角、卡间距 4);选中 = 强调色染底 | 已在代码 | CleanerJunkRowViews.swift `JunkRow.rowBackground` | 改写:去掉透明度数值。文档写「内距 14×14」,代码是左右 14、上下 10(见不一致 ⑤) |
| 密-15 | 清理页强调色 = `{accent-clean}`;主窗口工具栏清理 tab 同色(app 层覆写,PulseCore 色表不动) | 已在代码 | MetricAccent.swift `Surface.cleanAccent`;MetricTabViews.swift 工具栏 tab 的 `tint` | 未动(范围外) |
| 密-16 | 项目大卡 = 一张抬升底大卡装头排 + 全部子项;子项是卡内裸行,只缩进、无小卡底(选中 = 强调色行底);与工具缓存组的独立小卡两形态并存 | 已在代码 | CleanerJunkViews.swift `JunkListCard.projectCard`(方法注释)、`groupRows`(方法注释);CleanerJunkRowViews.swift `JunkRow.indented`;CleanerListCommonViews.swift `CleanerListMetrics.indentLeading` | 改写;原来「项目大卡是什么」在四处各说一遍,完整说法只留在 `projectCard` |
| 密-17 | 点头排 = 展开 / 收起,右缘 chevron,默认展开 | 已在代码 | CleanerJunkViews.swift `JunkListCard.projectCard`、`collapsedProjects`;收展点击区的行内注释 | 改写(原注释说「项目产物 = 去收起」,与现状相反) |
| 密-18 | 勾选两层口径:状态反映全部非在用子项;动作只全选 / 全清安全档子项;没有安全档可勾时置灰不给假按钮;全在用换锁 | 已在代码 | CleanerJunkViews.swift `JunkListCard.projectCard`(方法注释) | 改写并合成一处;理顺「全在用走换锁,不是置灰」(原两处说法有出入) |
| 密-19 | 组头「全选安全项」同口径:只吃 safe 非在用;组里没有可勾项不出 | 已在代码 | CleanerJunkViews.swift `JunkListCard.groupHeader`(方法注释)、`groupsBody`(行内注释) | 改写;原行内注释带「拍板 B」 |
| 密-20 | 候选不过滤亚兆条目 | 已在代码 | Pulse/Features/CleanerModel.swift `candidates`(范围外) | 未动 |
| 密-21 | 同上条的括注「0 KB 的产物也是该清的东西,照列」 | 文档与代码不一致 | 同上;PulseCore `ProjectArtifactMatcher.appendArtifacts`、`JunkMatcher.candidates` | 见不一致 ⑨ |
| 密-22 | `memory()` 补 KB 档给真实读数,不再显示成「0 MB」 | 已在代码 | PulseCore `PulseFormat.swift` `PulseFormat.memory`(范围外) | 未动 |
| 密-23 | 产物行副标一律显示完整路径(中段省略);rationale 降为行悬停;TierChip 悬停自解释档位 | 已在代码 | CleanerJunkRowViews.swift `JunkRow.rowContent`(副标的行内注释)、`TierChip`(help 的行内注释) | 改写 |
| 密-24 | 项目行没有可自动勾选项时给可见原因:全在用 = 锁图标 | 已在代码 | CleanerJunkViews.swift `JunkListCard.projectCard`(方法注释) | 并入密-18 |
| 密-25 | 同上条:全为先检查 = 灰 chip「须逐个勾」 | 文档与代码不一致 | CleanerJunkViews.swift `JunkListCard.projectCard` | 见不一致 ⑦ |
| 密-26 | 卸载残留组复用项目大卡(按 `JunkGroup.groupsByOwner` 走大卡;工具缓存独占小卡形态) | 已在代码 | CleanerJunkViews.swift `JunkListCard.groupRows`、`projectCard` | 改写。「殿后第三组」见不一致 ⑧ |
| 密-27 | 分组键 = 完整 bundle id;头排标题 = 尾段显示名;meta 前缀完整 id;名词换「应用 / 残留」 | 已在代码 | CleanerJunkViews.swift `JunkListCard.projectCard`(行内注释)、`projectMeta` | 未动 |
| 密-28 | 头排「N 天前动过」与行副标「N 天未动」同档粒度(天 / 月 / 年) | 已在代码 | CleanerJunkRowViews.swift `JunkAgeText`(类型注释) | 改写;保留了「别用 `timeIntervalSinceNow`」这个坑 |
| 密-29 | 全集不完整时不出组,组位给一行说明「卸载残留未检测:原因」;「没查」与「查了没有」两态分开 | 已在代码 | CleanerJunkViews.swift `JunkListCard.orphanUnavailableHint`;CleanerModel.swift `orphanDetectionUnavailableReason`(范围外) | 未动 |
| 密-30 | 页头副标注记「含卸载残留检测」/「卸载残留未检测」 | 已在代码 | CleanerViews.swift `CleanerPageHeader.subtitle` | 未动 |
| 密-31 | 子页列表写成「垃圾 / 应用 / 历史 / 地图周边」 | 文档与代码不一致 | CleanerViews.swift `CleanerSubTab` | 见不一致 ⑬(轻微) |
| 密-32 | 原型三档裁决、参考竞品、ui-unify/01 起改单一出处 | 删·已废或历史 | — | 来历叙述;「与排行页同档同源」的口径留在密-1 |

## 四、清理清单行(L470–492)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 行-1 | 行首系统 checkbox(large) | 文档与代码不一致 | CleanerJunkRowViews.swift `JunkRow.rowContent` | 见不一致 ②;现行为自绘 `CleanerCheckBox` |
| 行-2 | 行选中底 = `{surface-card-high}` 70% + `{rounded.inner}` 10 | 文档与代码不一致 | CleanerJunkRowViews.swift `JunkRow.rowBackground` | 见不一致 ③ |
| 行-3 | 安全档 chip `TierChip` 的色映射:可安全清理 = positive、先检查 = caution | 归组件规范(票 07) | CleanerJunkRowViews.swift `TierChip.tint` | 组件自述保留。原注释写「先检查 → warning」,与代码不符,已改齐为 caution |
| 行-4 | 映射的是删除安全语义,不是负载警示 | 归组件规范(票 07) | CleanerJunkRowViews.swift `TierChip`(类型注释) | 同上 |
| 行-5 | 勾选动作条:抬升底 + 12 圆角,右侧「清除勾选」bordered +「清理…」borderedProminent | 删·代码自明 | CleanerJunkViews.swift `JunkListCard.actionBar` | 字面可读。文档写「内距 8×12」,代码是上下 10、左右 12(见不一致 ⑥) |
| 行-6 | 动作条常驻:空选时主按钮灰显 + 注脚,不整条消失 | 已在代码 | CleanerJunkViews.swift `JunkListCard.actionBar` | 改写 |
| 行-7 | 确认清单:定宽 sheet,标题 + 逐行 + 页脚总量与口径注记,列表限高滚动 | 删·代码自明 | CleanerConfirmSheet.swift `CleanConfirmSheet.body` | 数值字面可读 |
| 行-8 | 确认单逐行同清单行,减 checkbox | 文档与代码不一致 | CleanerConfirmSheet.swift `CleanConfirmSheet.confirmRow` | 见不一致 ⑪;「列照清单行来,去掉勾选框与大小条」已新增进类型注释 |
| 行-9 | 清单默认全不勾 | 已在代码 | CleanerJunkViews.swift `JunkListCard.actionBar`(空选注脚文案);CleanerModel.swift `selectAllSafeAndRequestClean`(范围外) | 未动 |
| 行-10 | 右键行 = 排除该目录 / 在 Finder 中显示 | 删·代码自明 | CleanerJunkRowViews.swift `JunkRow.body`(`contextMenu`) | 字面可读 |
| 行-11 | 组头三态 checkbox(`GroupCheckBox`)只吃 safe 非在用;none / mixed 全勾、all 全清;无可勾项不画 | 文档与代码不一致 | — | 见不一致 ①:组件已移除。口径由「全选安全项」承接(密-19);三态只剩项目大卡头排(密-18) |
| 行-12 | 组头排序 seg「大小 ⇄ 新旧」:默认大小、regular 档;新旧 = 最久未动在前,年龄未知排最后 | 已在代码 | CleanerJunkViews.swift `JunkListCard.groupHeader`(Picker 上方);PulseCore `JunkRules.swift` `JunkSortOrder.age`(范围外) | 改写。「只有项目产物组有 seg」见不一致 ⑫ |
| 行-13 | 行副标末尾追加年龄人话;口径 = 项目内非产物文件的最后变动(含 git 活动) | 已在代码 | CleanerJunkRowViews.swift `JunkRow.ageText` | 未动 |
| 行-14 | 未配扫描根时在组位出一行引导,不硬造空组 | 已在代码 | CleanerJunkViews.swift `JunkListCard.scanRootsHint` | 未动 |
| 行-15 | 在用保护行:整行灰显、勾选位换锁、chip 位换 `InUseChip`(三级墨色灰,不是警示琥珀;文案由原因拼出) | 已在代码 | CleanerJunkRowViews.swift `JunkRow.inUseReasons`(属性注释)、`InUseChip`(类型注释) | `inUseReasons` 注释改写(去掉票号碎片);透明度数值不写 |
| 行-16 | 在用行点行无反应,右键排除保留 | 已在代码 | CleanerJunkRowViews.swift `JunkRow.inUseReasons`(属性注释) | 新增半句(原来没写) |
| 行-17 | 原注释「08 票前的组头三态 checkbox 组件已随…移除」 | 删·已废或历史 | CleanerConfirmSheet.swift `CleanConfirmSheet` 上方 | 孤儿注释(文件里已无对应代码),连同多余空行一并删 |

## 五、设置「清理」页(L493–499)

| # | 原规矩(一句话) | 去向 | 位置 | 说明 |
|---|---|---|---|---|
| 设-1 | 页面 = 清理扫描根 + 排除目录两节 Form | 已在代码 | CleanerSettingsView.swift `CleanerSettingsView`(类型注释) | 改写。代码是两个配置节 + 第三个说明节(见不一致 ⑮,轻微) |
| 设-2 | 清理扫描根:出厂建议清单,逐行 Toggle 勾选即加、取消即删 | 已在代码 | CleanerSettingsView.swift `suggestedRoots`、`suggestedRow` | `suggestedRoots` 注释改写;`suggestedRow` 未动 |
| 设-3 | 展示 ~ 写法,存储展开归一后的绝对路径 | 已在代码 | CleanerSettingsView.swift `suggestedRow` | 未动 |
| 设-4 | 自添目录走文件夹选择器;自添行 = 目录图标 + 路径 + 减号删除(与排除行同款) | 已在代码 | CleanerSettingsView.swift `customRootRow` | 未动 |
| 设-5 | 与「项目根目录」页的归组配置两套独立、零共享 | 已在代码 | CleanerSettingsView.swift `CleanerSettingsView`(类型注释) | 改写 |
| 设-6 | 页脚说明文案钉死两条口径:项目 = 扫描根直接子目录;在用项目不进清理且每次清理前重查 | 已在代码 | CleanerSettingsView.swift `CleanerSettingsView.body`(页脚字符串) | 字符串本身就是规格,不重复进注释 |

## 六、文档与代码不一致(汇总,均以代码为准,未改行为)

| # | 文档说什么 | 代码实际是什么 | 位置 |
|---|---|---|---|
| ① | 组头有一枚系统三态 checkbox(`GroupCheckBox`) | `GroupCheckBox` 已不存在;组头是「全选安全项」文字按钮。三态只剩项目大卡头排的自绘 `CleanerCheckBox`(`.mixed`) | CleanerJunkViews.swift `groupHeader`、`projectCard` |
| ② | 行首系统 checkbox(large) | 自绘 `CleanerCheckBox`,没有 controlSize | CleanerJunkRowViews.swift `JunkRow.rowContent` |
| ③ | 行选中底 = 抬升底 70% + 圆角 10 | 独立小卡:常态抬升底、圆角 12,选中 = 强调色 12%;卡内裸行:无底,选中 = 强调色 10%、圆角 8 | CleanerJunkRowViews.swift `JunkRow.rowBackground` |
| ④ | 组头标题 14.5 bold(一处)、16 bold(另一处) | 17 bold | CleanerJunkViews.swift `groupHeader` |
| ⑤ | 条目小卡内距 14×14 | 左右 14、上下 10(与同一文档自己写的「14(左右)×10(上下)」一致) | CleanerJunkRowViews.swift `JunkRow.body`、RowMetrics.swift |
| ⑥ | 动作条内距 8×12 | 上下 10、左右 12 | CleanerJunkViews.swift `actionBar` |
| ⑦ | 全为先检查的项目行挂灰 chip「须逐个勾」 | 没有这个 chip:勾选框置灰 + 悬停说明 | CleanerJunkViews.swift `projectCard` |
| ⑧ | 卸载残留组「殿后第三组」 | 是 `JunkGroup.allCases` 的第六个(末位) | PulseCore `JunkRules.swift` `JunkGroup` |
| ⑨ | 括注字面说「0 KB 的产物也是该清的东西,照列」 | 匹配器层把「零字节且非部分扫描」的目录当噪音不列;照列的是亚兆但非零的条目(当时被格式化成「0 MB」的那批)。`CleanerModel.candidates` 的现有注释沿用了「0 KB 产物…照列」的字面说法,与同一条调用链上匹配器的注释打架 | CleanerModel.swift `candidates`;PulseCore `ProjectArtifactMatcher.appendArtifacts`、`JunkMatcher.candidates` |
| ⑩ | 定宽列按 "999.9 GB" 一个读数量宽 | 量的是 "999.9 GB" 与 "99.9 TB" 两个,取宽 | CleanerListCommonViews.swift `CleanerListMetrics.valueWidth` |
| ⑪ | 确认单「逐行同清单行减 checkbox」 | 还去掉了大小条;图标瓦按档位染色(safe = 强调色、先检查 = `Surface.warning` 磁盘金),而清单行图标瓦是中性灰、档位色在 chip 上取 `caution` | CleanerConfirmSheet.swift `confirmRow` 对 CleanerJunkRowViews.swift `JunkRow.rowContent`、`TierChip.tint` |
| ⑫ | 排序 seg 只在项目产物组的组头上 | 每个组头都有,模型为每组各存一个排序 | CleanerJunkViews.swift `groupHeader`;CleanerModel.swift `sortOrder` |
| ⑬ | 舒适密度档管「垃圾 / 应用 / 历史 / 地图周边」四子页 | 子页现为总览 / 全部清单 / 应用 / 清理历史(空间地图住磁盘页);总览不用 `CleanerListMetrics` | CleanerViews.swift `CleanerSubTab` |
| ⑭ | (旧代码注释,非 DESIGN.md)废纸篓卡「inventorying / running 期间禁用」 | `busy = trashPhase != .idle`,确认单开着、结果横幅未关时也禁用。注释已改齐 | CleanerOverviewViews.swift `OverviewTrashCard.busy`、`CleanerOverviewSection.trashCard` |
| ⑮ | 设置页「两节 Form」 | 两个配置节 + 第三个说明节(轻微) | CleanerSettingsView.swift `body` |

⑭ 不在五条旧条目里,是改写时发现并顺手改齐的代码注释,一并列出。

## 七、给票 07 的提示

- 归组件规范的条目:密-7(搜索框)、密-13(勾选框)、行-3 / 行-4(安全档 chip 的色映射与语义)。
- 任务说明把「组头三态 `GroupCheckBox`」列为通用件,但该组件已不存在(不一致 ①)。
  「勾选框(含组头三态)」条目请按现存形态立:三态只出现在项目大卡头排
  (`CleanerJunkViews.swift` `projectCard`),两层口径写在那里。
- 原 `CleanerViews.swift` 文件头里的「空态一律走 `CardEmptyState`,不手写空态」
  属卡片家族零件 / 空态规范,文件头改写成骨架后不再放;各使用处的局部标注保留。
