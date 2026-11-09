# 01: UI 归一——字号五档 / 行两档制 / chip 六合一

**What to build(用户 2026-11-08 拍板,方案 A = 排行也升舒适档):**

"字号、组件都应该归一,有统一的标准;功能相似组件不管是布局还是样式颜色也应该差不多。"

1. **字号 12 档 → 5 档**:10.5 / 11 / 12 / 14.5 / 17 + 大数字族(FigureSize 不动);
   语义字体(.caption/.caption2/.footnote/.title3)换显式字号。逐点映射见 DESIGN.md
   v1.1 §已知偏差 2026-11-08 条目。
2. **行两档制**:`Pulse/Views/RowMetrics.swift` 单一出处——紧凑档(弹窗)/ 舒适档
   (主窗口一切列表行,排行 13→14.5 升档、清理图标 28→24 / meter 130→120 / 上下距
   14→10、sheet 清单 13.5 档并入);`RankingListMetrics` / `CleanerListMetrics` 委托,
   只留页面专属参数。
3. **chip 六合一**:`Pulse/Views/ChipView.swift`(regular 11 / inline 10.5 两形态、
   tint 15%)收编 HotProcessChip / TierChip / InUseChip / StateChip / BrewChip /
   MetricChipView。
4. **顺带**:三处老挂账上 4pt 网格(主卡内距 20→16 / 2×2 间距 18→16 / 弹窗外框 14→12);
   等宽路径字体登记为 DESIGN.md 合法例外;空间地图「可清理」角标 8.5→10.5(底框
   36×13→38×14)。
5. **防漂移**:`UiUnifyRowMetricsTests`(委托关系 + 五档落档 4 例);
   `RankingListMetricsTests` 量宽改读 metrics 本身。
6. DESIGN.md 升 v1.1(typography 行两档令牌 + 组件条目 + 收编记档 + superseded 拍板标注)。

**Status:** done

- [x] RowMetrics / ChipView 单一出处落地
- [x] 排行链 + 清理四文件 + 监控页全量清扫(约 110 处)
- [x] 防漂移测试 + check.sh 全绿
- [x] DESIGN.md v1.1

## Comments

- 2026-11-08 实施:两轮子代理清扫(清理页 50 处 / 监控页 20 处)+ 主管排行链。
  子代理揪出票面没列的第 6 个 chip(BrewChip,chipFontSize 第 4 个引用点),一并归一。
- 遗留例外(有意不收):进程下钻组件簇(ProcessDrilldownView / SortableProcessTableView)
  共用组件带 .caption 族,归一需跨文件结构迁移(加 compact 参数走两档制),待专项票;
  Image .font 图标尺寸不受五档约束。
- 动了已拍板样式的三处(都有 superseded 标注):弹窗数值 11.5→12(2026-10-30 拍)、
  清理图标 28/meter 130(2026-11-05 拍)、comfortable 药丸 13.5→14.5(2026-11-05 拍)
  ——归一票整体拍板覆盖。
- 2026-11-08 用户目验追改三处 + 全局同类扫(feat/ui-unify-followup):
  ① 空间地图「在 Finder 中显示」.small bordered → 页内头部动作按钮统一配方
  (borderless 12 semibold secondary,与「全选安全项」同款);
  ② 应用页搜索框手绘灰底盒 → 系统原生 roundedBorder + 放大镜/清空内嵌;排序 seg
  「占用 ↓|按名」→「占用|名称」+ tint 强调色(与垃圾页「大小|新旧」同款);
  ③ 清理历史行首三角 → 行右缘 chevron(与项目大卡点头排同款)+ 行距上两档制。
  同类扫额外收编:FDA 横幅「去授权」.small → .link(告警横幅降级出口同款);
  残留探测 spinner .mini → .small(全仓 spinner 统一)。未动:主窗工具栏搜索
  (工具栏面,定宽 132/⌘F 已拍板)、进程下钻簇(遗留例外票)、地图根 seg(内容标签)。
- 2026-11-08 二轮目验(用户实报「历史下面没有卡」+ 全查细节,feat/ui-unify-cards):
  清单类子页统一为一种语言——组头式标题在页层、每条目一张小卡(card-hi/12 圆角/
  选中 accent 12%)、展开 = 卡内缩进裸行(28/14):历史子页撤大卡壳改逐 run 小卡;
  应用子页撤整页大卡(banner/控件条页层化)、条目小卡、残留展开去嵌套小卡改卡内裸行、
  游离 CardHeader 改组头式、空态收编 CardEmptyState;横幅圆角 12→10 全对齐(fda/
  staleness)。地图子页保留单张大卡(图表卡 = 卡家族语言)。
- 2026-11-09 三轮目验(用户实报「前两 tab 有卡头标题后两没有」,feat/ui-unify-cards2):
  根因 = 11-08 二轮改偏——当时误判垃圾页为"页层组头+散卡",照它撤了应用/历史大卡;
  实际垃圾/地图均为"一张大卡 + CardHeader"。四子页统一回大卡+CardHeader 形态:
  应用/历史恢复大卡壳与卡头(小卡条目/展开裸行保留),装载态对齐 CardEmptyState;
  四卡头统一清理页强调色(可清理的 08 中性拍板 superseded——躲金目标由 Teal 达成)。
