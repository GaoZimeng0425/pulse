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

**Status:** needs-triage(设计票;开工前需用户点名排期)

**Out of scope:** 拆分不顺手改行为/不顺手优化——每步纯搬运或纯抽取,
tests 全绿为闸。
