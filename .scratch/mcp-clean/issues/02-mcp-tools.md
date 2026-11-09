# 02: MCP 侧——list_cleanable / clean 两工具

**What to build:** spec §架构 MCP 部分(pulse-mcp 可执行,中文 prose 与现有三工具同风格)。

1. 端点发现:读 `~/.Pulse/mcp-clean.json`;pid 活性检查(kill(pid,0))——死 pid = app 未运行,如实报「Pulse 未运行,请先打开」。token 进 `X-Pulse-Token` 头。
2. `list_cleanable`:GET /cleanable → 人话清单(标题/路径/大小/多久没动/所属组/扫描数据年龄;明确注明只含安全档与非在用项)。app 未运行/清单为空/未扫描各有诚实文案。
3. `clean(paths)`:POST /clean(10 分钟客户端超时)→ 确认等待文案 + 逐项结果(已清/在用跳过/扫描后有变动跳过/失败原因/未识别路径原样退回)。
4. 既有三工具(why_cpu_high / current_metrics / history_query)零改动。
5. 测试:格式化在 PulseCore(01 已覆盖);本票只接线,pulse-mcp 包不加测试 target(与其现状一致)。

**Status:** done(2026-11-09,随 01 同分支;验证=Ai 客户端重开会话后 list_cleanable / clean 可见——pulse-mcp 每会话一进程,旧会话仍是旧工具集)

## Comments

**2026-11-09 实施记录:**

- main.swift:端点发现(pid 活性 kill(pid,0)+ESRCH 当未运行)+ 同步
  URLSession(list 30s / clean 610s);`paths` 兼容数组与单字符串两种传法;
  server instructions 与版本号(0.1.0→0.2.0)更新说明清理工具语义。
- 文案全部来自 `McpCleanText`(PulseCore),可执行只接线;既有三工具零改动。

