# 03: 票 C —— 历史层快修包(含项目根断史自动迁移)

**What to build:** 架构审查(本目录 REPORT.md)低优先级清单里的小时级快修,一条票打包。历史持久层本体质量高(审查结论),这票只清边角。

**Status:** done

范围(证据见 REPORT.md §低优先级):

- [x] **乙3 项目根断史 → 自动迁移(用户已拍板 2026-10-19:迁移,不文档化)**:改项目根 = 组身份换 stableKey,历史曲线无声断档。实现:留存上一版项目根配置快照(建议入库 metadata 表或与 lineage 同址),启动/改根时检测到根集合变化 → 一次性 UPDATE 把旧 key 迁到新 key(历史 sample 行 group_id + lineage + groups 缓存表同步改写);多对多歧义时保守跳过并记日志。GroupIdentityKey 是 key 派生唯一出处,迁移逻辑紧挨它放、单测钉死「改根前后曲线连续」
- [x] 乙5 启动主线程同步全量小时补卷积挪后台(成本随留存窗增长)
- [x] 乙6 series() 绕过 databaseHealthy 边沿日志纪律(对齐 ingest 的 transition-not-tick)
- [x] 乙7 落库 fire-and-forget 无序(批次化/串行化)+ totals 每轮 3×SUM(缓存或单查)
- [x] 乙8 groups 表与 stableKey 逆映射「写而不读」:接消费或注释钉死仅缓存(二选一,实施时看 HistoryQueries 是否真需要)
- [x] **跨会话 pid 复用后库中出生登记不更新**(2026-10-19 集成分支 code review 发现,存量限制):主干已按身份裁决「pid 复用活记录胜」(`GroupingPipeline.restoreBirths`/`adoptLive`),但 `HistoryEngine.importLineage` 把回灌 pid 全部预热进 `persistedLineagePIDs`、落库又是 `INSERT OR IGNORE`——胜出的活记录永不落库,下一会话复用进程已退出而其子进程仍在时,父链经旧记录归错。修法:活记录覆盖回灌时 upsert(`INSERT OR REPLACE` + 同步已持久化表),需定 first_seen 语义
- [x] 甲7 .onEvent 流结束静默死亡(电池等事件源加终态日志,沿 transition-not-tick)
- [x] 甲8 磁盘求和回退档缺单轮增量上限钳制(异常跳变不整块进账,参照网络差分三防护)

约束与验收:
- 每条独立小改,合一条分支;历史层测试全在真 SQLite 上跑(HistoryDatabase 既有 45+ 例的纪律),迁移条目必须带「改根 → 曲线连续」与「歧义跳过」两类测试
- `sh scripts/test.sh` 全绿;不改 UI

## Comments

- 2026-10-20 全部落地(分支 feat/ticket-c):
  - 乙3:`ProjectRootMigration`(旧根 → 新根一对一配对:路径互为前缀或末级目录名相同;歧义保守跳过记日志)+ `HistoryEngine.reconcileProjectRoots` 改写分钟表 / 小时表 / groups(worktree 后缀保留),上一版根快照存新增的 `metadata` 表(schema v2);启动与改根经 `MonitorFeature.projectRootsChanged` 派发、走历史串行写入流。lineage 表不含组键,无需改写(票面原写「lineage 同步改写」不适用)。已知边界:改根那一分钟的内存缓冲里还是旧键,冲刷时会留下一行旧键分钟行。
  - 乙5:构造不再补卷积;首笔落库在 actor 上从小时表已有的最后一小时起补。
  - 乙6:抽 `HistoryHealthEdge`,落库 / 累计 / 历史页查询共用状态沿。
  - 乙7:串行写入已随票 A 落地;累计改为只在分钟行落库后重查。
  - 乙8:注释钉死为预留(无按组历史视图前不接消费)。
  - 甲7:`SensorScheduler` 事件流非取消结束记终态日志并点名传感器(日志出口可注入)。
  - 甲8:`DiskThroughputDiffer` 单轮 20 GB/s 上限,超限整轮作废。
  - 跨会话 pid 复用:引擎记住回灌读回的记录,本会话该 pid 换成别的记录即整行覆盖一次。
- 遗留(未处理,记档):lineage 表从不清理,跨会话无限增长;回灌读回的记录每轮都要逐条比对一次(量随 lineage 表增长)。可另立小票:按 first_seen 清理久未出现的 pid。
