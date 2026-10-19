# 03: 票 C —— 历史层快修包(含项目根断史自动迁移)

**What to build:** 架构审查(本目录 REPORT.md)低优先级清单里的小时级快修,一条票打包。历史持久层本体质量高(审查结论),这票只清边角。

**Status:** ready-for-agent

范围(证据见 REPORT.md §低优先级):

- [ ] **乙3 项目根断史 → 自动迁移(用户已拍板 2026-10-19:迁移,不文档化)**:改项目根 = 组身份换 stableKey,历史曲线无声断档。实现:留存上一版项目根配置快照(建议入库 metadata 表或与 lineage 同址),启动/改根时检测到根集合变化 → 一次性 UPDATE 把旧 key 迁到新 key(历史 sample 行 group_id + lineage + groups 缓存表同步改写);多对多歧义时保守跳过并记日志。GroupIdentityKey 是 key 派生唯一出处,迁移逻辑紧挨它放、单测钉死「改根前后曲线连续」
- [ ] 乙5 启动主线程同步全量小时补卷积挪后台(成本随留存窗增长)
- [ ] 乙6 series() 绕过 databaseHealthy 边沿日志纪律(对齐 ingest 的 transition-not-tick)
- [ ] 乙7 落库 fire-and-forget 无序(批次化/串行化)+ totals 每轮 3×SUM(缓存或单查)
- [ ] 乙8 groups 表与 stableKey 逆映射「写而不读」:接消费或注释钉死仅缓存(二选一,实施时看 HistoryQueries 是否真需要)
- [ ] 甲7 .onEvent 流结束静默死亡(电池等事件源加终态日志,沿 transition-not-tick)
- [ ] 甲8 磁盘求和回退档缺单轮增量上限钳制(异常跳变不整块进账,参照网络差分三防护)

约束与验收:
- 每条独立小改,合一条分支;历史层测试全在真 SQLite 上跑(HistoryDatabase 既有 45+ 例的纪律),迁移条目必须带「改根 → 曲线连续」与「歧义跳过」两类测试
- `sh scripts/test.sh` 全绿;不改 UI
