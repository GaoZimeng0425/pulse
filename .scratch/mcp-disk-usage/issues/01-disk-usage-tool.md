# mcp-disk-usage: 上次扫描快照的目录占用查询

## 拍板(用户,2026-11-10)

要的不是容量/剩余空间,是**哪些目录占多少磁盘空间**;拿历史数据(上次清理扫描的快照)答,**不实时扫描**。

## 范围

一个只读 MCP 工具 `disk_usage`(pulse-mcp 0.4.0;既有 10 工具零改动):

- 无 `path` → 各扫描根的一级子目录排行(top_n,默认 10)+ 扫描总量上下文;
- 有 `path` → 该目录子树总占用(实际占用口径)+ 直接子目录排行 + 文件数;
- 数据年龄 = 上次扫描时刻,如实标注;扫描被取消/部分目录枚举失败/扫描后已清理的路径,各自如实说明;
- 路径不在快照内 → 报扫描根范围,不猜。

## 架构

数据 = `~/.Pulse/scan-cache-v1.bin`(SpaceScanCache v2/v3 可读;app 关着也能读)。纯逻辑/文案在 PulseCore(`DiskUsageQuery` + `McpDiskUsageText`,夹具单测);pulse-mcp 只读文件接线;**app 侧零改动**(不碰扫描器/界面)。文件名常量提公共(SpaceScanCache.defaultFileName),与 app 侧 CleanScanResultStore 同串。

**Status:** done(2026-11-10,分支 feat/mcp-disk-usage)

## Comments

**2026-11-10 实施记录:**

- PulseCore `McpDiskUsage.swift`:`DiskUsageQuery.subtree`(精确节点命中,否则前缀聚合——被排除/枚举失败的目录只算覆盖到的部分)+ `topChildren`(子目录降序,文件不入列只计数)+ `McpDiskUsageText`(快照年龄/取消/部分/已清路径四类如实注记)。
- pulse-mcp:`disk_usage(path? , top_n)`;缓存缺席 → "还没扫过,去 app 点扫描整台 Mac"。
- 测试:PulseCore +5(精确/前缀聚合/子目录排序/文案四注记/常量与 store 同串)。
