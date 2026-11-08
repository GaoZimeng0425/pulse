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
