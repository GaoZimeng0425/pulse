# 02: 落盘——告警历史 + dev server 状态 → MCP 两工具

**What to build:** spec §范围 4-5 + §架构落点。

1. 迁移 `mcp-eyes-v1`:alert_event(ts/kind/subject_key/subject_name/value,PK 三列)+ dev_server_state(pid PK/kind/name/memory_bytes/idle_seconds/ports/first_seen/last_seen)。
2. PulseCore 两个 actor:`AlertEventStore.record`(INSERT OR REPLACE,exact 秒)+ `recent(hours:)`(同 kind+subject 聚合:最新值+次数+首末时刻);`DevServerStateStore.upsert`(分钟节流:同分钟且 pid 集未变则跳过;pid 不在集合且 last_seen 超 10 分钟删除)+ `current(now:)`。
3. 接线:HistoryFeature 暴露两 store(同 cleanHistory 样板);onEvent 消费 `.devServers` 入串行写流;AlertCenter 注入 store,handle(.fired) fire-and-forget 记一笔(MonitorAssembly 装配顺序:HistoryFeature 先建)。
4. PulseCore `McpEyesSupport` 补两工具文案(告警按主体去重列最新;dev server 标"最后见到 N 分钟前",久未见如实说可能已退出)。
5. pulse-mcp 注册 `recent_alerts(hours)` / `list_dev_servers`。
6. 测试:两 store 真 SQLite 夹具(节流/删除/聚合);HistoryFeature 消费事件落表;文案档位。

**Status:** done(2026-11-10,分支 feat/mcp-eyes,验证记录见 Comments)


## Comments

**2026-11-10 实施记录:**全量 /tmp detach(f682e6a)核心 727 + app 491 = 1218,唯一挂 = 已知满载偶发 toast 用例(挂账 .scratch/alert-toast-flake/01,单跑 6/6 绿,与分支无关);本 worktree 宿主挂死一次(当日第三见,Documents 间歇问题,既有档案)。
