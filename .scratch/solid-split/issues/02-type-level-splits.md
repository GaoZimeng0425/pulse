# 02: CleanerModel / SpaceMapSection 类型级拆分(设计票,未开工)

**What to think through:** 两笔文件级拆分还不掉的 S 债,需要类型级手术:

1. **CleanerModel(986 行,@Observable 六职责)**:扫描编排/进度与停滞兜底/
   缓存装载/勾选会话/清理执行/历史落账混居一类。
   **为什么不能 extension 分文件了事**:状态属性全 `private`/`private(set)`
   是封装资产,extension 跨文件要求大面积拆 private → 以牺牲封装换文件
   分居,与 SOLID 初衷相反;类型级拆协作对象才是正解,但牵 20+ 测试与全部
   视图调用点(行为面手术),必须单独窗口分步搬。
   **分步草案**:①先把「总览读数」(278-415,纯派生)抽只读 struct;
   ②缓存装载(416-485)抽会话装载器;③扫描编排(486-661)抽引擎驱动;
   ④每步 tests 全绿再进下一步;勾选/执行/历史留主类(它们共享私有状态最重)。
2. **CleanerSpaceMapView(847 行,单 struct 767 行)**:SpaceMapSection 内含
   两个嵌套绘制 struct(BlockFill/ColoredArc)与多个私有视图成员;拆的是
   **视图组合结构**(把绘制层抽子视图),不是文件。建议先抽 BlockFill/
   ColoredArc 两件(纯绘制,输入输出清晰)热身,再议表单/双形态主体。

**背景:** solid-split/01 的 Out of scope;2026-11-22 深查定谳。

**Status:** in-progress(2026-11-22 步骤 1/2 已落,见 Comments;装载/编排定谳另票)

- [x] 步骤 1:SpaceMap 配色域抽 `SpaceMapPalette`(816912f;106 行,纯搬运)
- [x] 步骤 2:总览废纸篓清点器抽 `OverviewTrashCounter`(46ebc41;101 行,
      转发面保调用点零变化,CleanerModelTests 28 处断言全绿)
- [ ] ~~缓存装载抽会话装载器~~ / ~~扫描编排抽引擎驱动~~:**实读定谳改判**
      (2026-11-22)——两节直接编织主类十几处私有状态(phase/mapTrees/
      loadedFromCache/loadedCacheMeta/lastSavedMeta/recycledPaths/
      sessionCleanedCount/installedApps/scanStartedAt…),不是内聚子状态机;
      抽离 = 状态搬家 + 回调网,行为面风险大,需先做状态分组设计再动手,
      不属于「测试全绿即证明」的搬运件。复活条件:清理域下次功能票触及
      这两节时顺势设计(或用户点名专项)。

**Out of scope:** 拆分不顺手改行为/不顺手优化——每步纯搬运或纯抽取,
tests 全绿为闸。
