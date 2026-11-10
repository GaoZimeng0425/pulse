# p6-cleaner/03:总览页(Hero + 七模块大卡 + 下钻导航)

Status: done(2026-11-10 合 develop @ec7b4d5)
Blocked by: 01(02 未合时 AI 卡随空组不出)

## 目标

丙案 v2 落地:清理页首个子页「总览」,原型 = `prototype/cleaner-reorg`(分支)的 `cleaner-reorg-plan-c.html`。

## 范围

1. 子药丸:「总览 | 全部清单 | 空间地图 | 应用 | 清理历史」;首个子页文案「可清理」→「全部清单」(内部标识 `CleanerSubTab.junk` 不动,p4-uninstaller/08 改名先例)。
2. 总览聚合纯值进 PulseCore:品类聚合模型(总量 / safe / check / inuse / 最大一项)+ 全部清单过滤参数 + 废纸篓读数(复用 TrashExecutor 汇总);夹具 = 原型那批真机数据。
3. UI:Hero 卡(可回收总量大数字 + 三段构成条 + 图例含废纸篓 + 主按钮「一键清理 X 安全项…」,动作本体在 04,此票先占位走既有「清理…」流程亦可——实施时以不落死代码为准,按钮直接接 04 的计划生成最省)+ 模块大卡 2 列自适应(42pt 图标瓦 / 16 bold 类名 + 一句人话 / 24pt 大数字 / 构成条 / 「最大一项」行 + chevron)+ 废纸篓卡(读数 + 独立「清空废纸篓…」按钮,页头原按钮撤除)。
4. 交互:点大卡 → 全部清单按品类过滤 + 顶部「‹ 总览」返回;总览 ↔ 清单切换不丢勾选;空组卡不出。
5. **DESIGN.md 先补表再写码**(AGENTS 规矩):模块卡最小宽(720 最小窗 1 列、默认窗 2 列)/ 图标瓦 42 / 构成条 / hero 内距 / 24pt 大数字档;模块卡类别色走类别身份色体系,需新色先入表。
6. 文案蓝本 = 原型(类名 + 一句人话);行形态继续走 RowMetrics / CleanerListMetrics,零新行形态。

## 验收

720 最小窗 1 列不溢出、默认窗 2 列;勾选跨页保持;观感目验归 04 收口。

## Comments

2026-11-10 实施(feat/p6-cleaner-03 @82bb0f7,check.sh 全绿):

- **DESIGN.md 新增令牌**:`{colors.junk-*}`(六品类+废纸篓身份色:dev=CPU 蓝/browser=GPU 粉/app=App 棕/proj=内存紫/ai=蓝牙青/leftover=传感器橙红/trash=磁盘金——原型拍板映射;唯一出处 `MetricAccent.swift` 的 `JunkGroup.identityColor` + `JunkTrashIdentity`,指标色作类别身份借用同空间地图先例)、`{typography.figure-card}` 24(`FigureSize.card`)、`{layout.module-card-min-width}` 340(2 列自适应,720→1 列/880→2 列/上限 2)、§Components 新「清理总览页」条目(构成条 hero 8 卡 7、图标瓦 42、hero 内距 24×28、卡壳收编 cardShell 16)。原型非 4pt 网格值收编:hero 内距 26×28→24×28、卡内距 18×20→16(cardShell)、类名 16→17(五档纪律)、hero 大数字 52→44(FigureSize 族既有最大档)。
- **关键定案**:①三段构成互斥切分——在用与档位正交(safe 项也会被在用保护),inuse 段吃全额、safe/check 段只计非在用部分,三段相加恒等于合计(构成条不重不漏,测试钉死);safeBytes 因此天然 = 一键可自动勾选量。②一键清理 = **替换**勾选(复用 mcp-clean 的 applyExternalSelection)+ requestClean 既有确认单 + 跳「全部清单」落地弹单(原型行为);默认勾选仍全不勾。③下钻态组头并入返回行(标题/合计/全选安全项),排序 seg 只在全量视图(原型同款);meter 归一恒为全量榜首(下钻视图条长短与全量一致)。④废纸篓「所有卷汇总」只在多卷有料时显(原型恒显,单卷下是噪声)。⑤地图轻桥与总览下钻互斥:轻桥定位 = 全量清单滚动到组,下钻 = 过滤视图,两条路径都清对方的态。
- **测试计数**:核心 710(+7 = JunkOverviewTests:夹具聚合/三段互斥/空组不出序/一键排除先检查与在用/无活动全 safe/过滤/废纸篓夹具)· app 侧 480(+2 = testOverviewTitle、testOverviewCardCopyCoversAllGroupsAndTrash;testFour→testFiveSubTabsOnAxis 改名不增数)· 合计 1190。
- **偏离项**:无(空组 AI 卡随空组自然不出,票面已写);MetricTabCleanerAxisTests 未动(tab 级无变化)。
- 2026-11-10 合并补笔(@2784791):并 02 时接缝——`JunkOverview.isInUse` 由路径版换组感知版 `CleanInUse.reasons(for:)`:第四路(home 锚 `.aiService`)入总览分段与一键口径、不越组,清单灰行/删除计划/总览三处同口径;补第四路回归测试(退回路径版即红)。门禁复跑:核心 718 · app 482 · 合计 1200。
