# 00: 前置重构——组身份类型化 + 结伴值收拢

**What to build:** 纯内部重构,零行为变化:把组的稳定身份从裸字符串(`ProcessGroup.id: String`)升级为类型化组标识(种类:App/项目/系统/后台服务/孤儿 + 稳定原始值),让"拿任意字符串当组 ID"成为编译错误;顺带处理 P0 两轴评审推迟的另一项——总是结伴传递的值三元组收拢为一个结构体(以 ripwire 定位现场;若发现已被后续重构吸收,记录结论即可关闭该项)。历史管线(03)会大量以组身份做键,先让类型立起来。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 组身份为类型化值,引擎/管线/排序/下钻/搜索/内存环形缓冲全部迁移,裸字符串不能直接充当
- [x] ripwire 影响面核查(`--impact` / `--verify`)通过,无遗漏调用点
- [x] 值三元组收拢落地,或确认已被吸收并记录结论
- [x] 全量测试绿,现有断言语义不变(只改构造方式)

## 落地记录(2026-10-16)

- **组身份**:`GroupIdentity`(enum,种类即 case + 稳定原始值即关联值)落地于
  GroupingEngine.swift,与 GroupCategory 1:1(`category`/`bundlePath` 派生,不再双份存储)。
  `stableKey` 逐字节复现 P0 前缀约定 id,`Comparable` = stableKey 字典序——同值并列的
  次键排序与升级前逐位一致,零行为变化。迁移面:GroupingEngine/GroupingPipeline/SampleHistory
  (GroupSample、groups 字典、series(forGroup:))/MetricTabContent(microGraphGroupIDs、
  MemoryRingSegment;“其他”聚合段不是组,id 为 nil)/DashboardModel(展开会话、微图表)/
  SystemMonitor(terminateGroup)/RankingCard 回调。“拿任意字符串当组 ID”自此是编译错误;
  P0 评审 D2 的组 id 一半就此关闭(D2 的 ProjectRoot 标记类型不在本单范围)。
- **D1 三元组(结论:收拢落地,非吸收)**:ripwire 定位结伴现场共三处——RawProcess 与
  LineageRegistry.Entry 各平铺一份、Resolver.layerSelf(executablePath:cwd:argv:) 收参一份。
  引入 `ProcessIdentity`(ProcessSnapshot.swift)收拢:两处存储合一,layerSelf 改收三元组;
  RawProcess 构造签名不变(采集层零改动),Entry/字段直读视图保留,ParentChainQuery 等既有
  消费点零迁移。
- **新增测试 4 例**(GroupingEngineTests 内):category 1:1 映射、stableKey 复现旧 id、
  Comparable 复现旧次键序、相等性区分 worktree。全量 272 绿(268 + 4);
  quality-delta 门禁清零(churn 机械编辑已 ack,`.ripwire_quality_acks` 随本单入库)。
