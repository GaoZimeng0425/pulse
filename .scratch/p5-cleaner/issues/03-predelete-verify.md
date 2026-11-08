# 03: 删前复核(全清理统一)+ 收口

**What to build:** spec §15——执行层一道闸,所有清理组白捡。

1. 扫描快照:`JunkCandidate` 补「目录自身 mtime」字段(树上节点自身 mtime,非 newestChangeEpoch);扫描时随候选带出。
2. 执行层复核(LiveCleanTrashExecutor 移废纸篓前,逐项):目标仍存在 + 目录自身 mtime == 快照;不一致 = 该项**跳过**,outcome 记 `.failed(reason: "扫描后目录有变动,已跳过——重新扫描后再清")`(如实报,历史可查)。
3. 确认 sheet 注记补一句(用户预期管理:扫描后有变动的项会被跳过)。
4. 夹具测试:变动即跳过/未变动照删/报告如实;卸载执行器(AppUninstallRunner)同闸(它有自己的 receipt 防御,补 mtime 复核一致性)。
5. 收口:全量 check(用户发起)+ 目验清单(孤儿组扫出/大卡分组/勾选两层/排除/历史找回/地图角标跳转/删前复核触发的跳过报数)。

**Status:** ready-for-agent

- [ ] 快照字段 + 执行层复核 + 如实报
- [ ] 卸载执行器同闸
- [ ] 夹具测试
- [ ] 收口:check + 目验清单交用户
