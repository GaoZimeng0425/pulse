# 01: 查询层——内存/磁盘排行 + 进程档案 → MCP 三工具

**What to build:** spec §范围 1-3(纯查询,零落盘)。

1. `InsightQuery.topMemoryGroups`(AVG/MAX mem_max,JOIN groups,同 topCpuGroups 样板)+ `topDiskGroups`(SUM disk_r/disk_w,NULL→0 且如实标"部分分钟缺磁盘账")。
2. `InsightQuery.lineageMatches(pid: 或 substring 于 executable_path/argv/cwd,限 20 行)。
3. PulseCore `McpEyesSupport`:三工具中文文案单出处(口径注释:内存=当分钟峰值合计可超物理、磁盘=窗口总量、lineage=出生登记非存活)。
4. pulse-mcp 注册 `why_memory_high` / `top_disk_io` / `process_info`(query 参数:纯数字按 pid,否则子串;每行带 kill(pid,0) 活性)。
5. 测试:InsightQueryTests 三查(含 NULL 磁盘、子串命中、上限);McpEyesText 文案档位。

**Status:** done(2026-11-10,分支 feat/mcp-eyes,验证记录见 Comments)

## Comments

**2026-11-10 实施记录:**

- 全量:/tmp detach(f682e6a)核心 727 + app 491=1218,唯一挂=已知满载偶发 toast 用例(needs-triage 挂账 .scratch/alert-toast-flake/01,单跑 6/6 绿,与分支无关);本 worktree 宿主挂死一次(今日第三见,Documents 间歇问题)。
- 实现:InsightQuery 三查(内存 AVG/MAX、磁盘 SUM+NULL 标记、lineage pid/子串+LIKE 全转义)+ McpEyesSupport 文案与读侧 McpEyesQuery + 两 actor store(alert_event fire-and-forget / dev_server_state 分钟节流+10 分钟清尸)+ HistoryFeature/AlertCenter/MonitorAssembly 接线 + pulse-mcp 0.3.0 五工具。
- 测试:McpEyesTests 6 例(窗口边界/LIKE 转义/聚合/节流清尸/文案档位);既有 tableNames 动态断言自动兼容两新表。
