# 架构审查总报告(2026-10-18)

三路并行只读评审(采样传感层 / 状态模型+历史层 / UI 组件层),分支 p1-implementation。
发现已跨轴去重;每条标注原始出处轴(采样=甲,模型历史=乙,UI=丙)。

## 总体判断

历史持久层质量高(窗口对齐/回拨丢弃/留存/幂等卷积口径齐整,45+ 例真 SQLite 单测),可放心。
传感层地基健康(缝切得准、547 测全绿、ADR-0004 薄协议决策依然成立),但**今天刚合入的模块排行三源把两类债各放大一号**:
同一套"门控+账本"脚手架抄了三份、rusage 计数器出现双采集通道、SystemMonitor 开始指数生长。
UI 层的令牌纪律在"已收编区域"执行干净,问题集中在边缘:新代码又带入表外值(收编是还账式非闸门式)、
卡片家族四种配方、主/弹窗装配两份平行实现。**三个轴独立指向同一件事:SystemMonitor 单点膨胀 + 组聚合口径分裂,
这是当前唯一"高"级共 finding。**

## 高优先级(建议立票,一周内)

### 1. SystemMonitor 收敛(甲1 + 乙1,双轴独立命中)
~20 发布态、13 init 参数、apply() 扇出 7 类消费者;混入非粘合逻辑(磁盘历史记账账本 pendingDisk、
排行可见性门控折算),借"UI 粘合层不写单测"豁免零测试。每工单必改此文件 = 回归中心。
→ 拆:SensorHub(门控+调度登记)/ ModuleRankingModel(三张 pid 表+时间戳)/ 历史喂入编排独立可测类型;
门控折算下沉纯函数进单测;init 参数减半。

### 2. rusage 双采集通道合一(甲2,甲自评最优先)
心跳快照(LiveProcessSource)每 pid 已读 proc_pid_rusage V3 并带磁盘字节;排行三源另起
proc_listallpips + CURRENT 第二趟;求和回退源再走一次。窗口可见时同一计数器 5s 被两条路径各取一遍。
→ RawProcess 增补 wakeups(V3 本就含),三个排行差分账本改吃心跳快照表,撤第二条全进程扫描;
门控降级为"推进/暂停差分"。此条同时消掉甲3(脚手架三抄)的数据前提。

### 3. 组聚合内核统一(乙2 + 乙4 + 甲4 部分)
三处并行:MetricTabContent.build(次键 lhs.id)/ ModuleRankingAggregator(次键 lhs.key,还住在视图层
body 里,与 allGroups 两套时钟)/ 视图内联 cpuLeader。tie-break/leader/零值行口径今天逐位一致,
一致性只靠两组互不相干的测试各钉各的。
→ 提一个 (identity, 值序列) → 排序+tie-break+leader 归一 的组聚合内核,三处全改调它;
模块排行折叠挪进 SystemMonitor 同轮落地(错位超一轮不出榜),视图只吃行数组。

## 中优先级

### 4. UI 卡片家族收口(丙3 + 丙4)
卡壳 12 处 3 种 compact 判定写法;卡头手抄 4 份;副卡头 4 份;统计值字号 4 变体;空态 5 份;
主/弹窗 tab 装配两份平行实现(总览五卡网格逐字重复)。主/弹窗同构刚拍板,是抽共用装配的唯一好时机。
→ CardShell(style:) modifier + CardHeader/StatValue/EmptyState 小组件;ModuleCardGrid + MetricTabStack 抽取。

### 5. GatedDifferingSensor 泛型收口(甲3)
门控+差分账本+lastGood 五件套手抄三份,抄漏一件 = 静默口径漂移;P2 的 GPU/ANE 都带门控。
→ 值组合泛型折叠(非继承,不违 ADR-0004),契约一次写一次测。

### 6. nettop 子进程健壮性(甲6)
看门狗只发 SIGTERM 无 SIGKILL 升级(吞信号 = 串行队列永久冻结,唯一不能自愈的源);
全文件零日志(起不来/超时/卡死无信号)。
→ 超时升级 SIGKILL;失败沿记状态日志(沿 databaseHealthy 惯例)。

### 7. 磁盘历史记账 exactly-once(甲5)
增量落库正确性依赖"lastGood 重投值恒相等"的三层隐式契约(Equatable 去重),给 Reading 加任何
时变字段即开始重复记账,无测试无编译期保护。
→ driver 交付带 fresh/stale 标记或重投轮恒 0。

### 8. 设计系统:宪法外色表 + 第二轮收编(丙1 + 丙2 + 丙5)
告警横幅裸 Color.orange + 描边(违反"强调级映射集中"与"无描边");类别身份色表(含孤儿橙)整表
未入令牌区;设置渐变砖的仿系统风格未登记例外;收编轮后新代码又带入表外值(ModuleRankingCard 的
6×7 行距、spacing 1/5/10、padding 14、FigureText 22/30/19/16、Color.primary.opacity 三档)。
→ 类别色表入 MetricAccent 同级唯一出处并在 DESIGN.md 立节;设置砖登记例外;横幅改语义令牌;
一轮收编 + FigureText compact 档立令牌。

## 低优先级(快修清单,一个票打包)
- 项目根热更新 = 组身份换 key,历史曲线无声断档(乙3):改根时一次性 UPDATE 迁移,或 GLOSSARY 钉死"改根即断史"语义——**需要用户拍板**。
- 启动主线程同步全量小时补卷积,成本随留存窗增长(乙5):补卷积挪后台。
- series() 绕过 databaseHealthy 边沿日志纪律(乙6);落库 fire-and-forget 无序 + totals 每轮 3×SUM(乙7)。
- groups 表与 stableKey 逆映射"写而不读"(乙8):接消费或注释钉死仅缓存。
- .onEvent 流结束静默死亡(甲7);磁盘求和回退档缺单轮增量上限钳制(甲8)。
- monospacedDigit 三处缺口(HistoryView 均值峰值/弹窗 uptime/告警阈值)(丙6)。
- a11y 两处(主窗齿轮+清空钮缺 label);RingCardView 用 Apple Charts 画环形 vs 走势自绘的双轨未在 DESIGN 登记(丙8)。
- 预览缺口 4 文件(RingCardView/SettingsView/GeneralSettings/MenuBarBadgeSettings)(丙7)。

## 建议票组
- 票 A「传感层收敛」(高1+2+3 + 中5+6):P2(GPU/ANE/SMC)开工前必做,否则新传感器顺着最省力的路复制债。
- 票 B「UI 组件收口 + 第二轮规范收编」(中4 + 中8):趁主/弹窗同构刚拍板。
- 票 C「历史层快修包」(低优先级里乙5/6/7/8 + 甲7/8):每条都是小时级。
- 单点拍板:项目根断史(迁移 or 文档化);monospacedDigit/a11y/预览缺口可并入任意一轮 UI 票。

## 拍板结果(2026-10-19)
- 票组全做,顺序 **A → B → C**;monospacedDigit/a11y/预览缺口并入票 B。
- 项目根断史:**改根时自动迁移**(不留断史语义)→ 票 C 项。
- 锚点④:如实记 1.10% + 另立常驻成本追击票(issues/04)。
- 票件:issues/01(票 A,ready-for-agent)/ 02(票 B,blocked by 01)/ 03(票 C)/ 04(追击,blocked by 01)。
- 走查遗留「冷启动磁盘告警 20.4GB」同日结案为误报(测试夹具污染生产日志,修复 `7aa505a`),与本审查无关。
