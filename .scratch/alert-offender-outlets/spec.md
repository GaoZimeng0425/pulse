# alert-offender-outlets:告警点名责任 app(归因出口全覆盖)

Status: done(2026-11-12 合 develop @e0a577c)

## 背景

iSurge 对照差距之一:告警点名责任 app。现状摸底(2026-11-12)——归因引擎
`AlertOffenderAttribution`(纯函数,触发当轮组排行+进程差分 → 承载组+前三名)
**已经上线且只喂了 NemoNotch toast**;其余四个出口全不带:

| 出口 | 现状 | 差距 |
|---|---|---|
| NemoNotch 卡 | ✅ 带归因(toast body = 前三名进程串) | 无 |
| 系统通知 | title 带组名(groupCPU/newGroupMemory);systemLoad 无主体;body 无进程明细 | 「谁在吃」不进正文 |
| 应用内提示(主窗口+弹窗横幅 activeAlerts) | 复用通知 title/body | 同上 |
| 日志 | subjectName | 无进程明细 |
| 告警历史(alert_event 表 / MCP recent_alerts) | 5 列无归因 | AI 问「当时谁干的」答不了 |

## 目标

告警触发时,**五个出口一致地**看到「是谁在吃」:系统通知正文、应用内提示行、
日志、NemoNotch 卡(已有)、告警历史落库(MCP recent_alerts 可查)。归因口径
不变:触发当轮快照(AlertOffender.swift 既有定案——用户收到时想知道「现在谁在吃」);
diskAvailable / devServerIdle 无归因不硬造(既有定案)。

## 范围

1. **AlertCenter fired 时算一次归因**(现状 deliver 里 toast 单独算):提到
   handle 的 fired 分支算好,deliver / 日志 / 历史落库共用。`AlertOccurrence`
   不动(引擎纯值,动它牵连大);AlertCenter 新增 `offenders:
   [String: AlertOffenderSummary]`(key = `"\(kind)|\(subjectKey)"`,同通知
   identifier 规则),fired 写入、resolved 清除。AlertViews 提示行按 key 取归因。
2. **归因文案单出处**:toast 的 `offenderBody(lead:entries:metric:)` 拼法挪成
   `AlertOffenderAttribution` 的纯函数(供三出口共用,口径一致);toast 的
   clamp 截断留在 toast 侧(横幅宽度限制是它独有的)。
3. **系统通知**:`AlertNotificationContent.make(for:offender:)` body 追加归因
   串(有 entries 才追加;title 保持短不动)。
4. **应用内提示**:AlertViews row 副文换用同款带归因 body 函数。
5. **日志**:fired 日志追加归因摘要(承载组 + 第一名进程)。
6. **历史落库**:新迁移 `alert-offender-outlets-v1` 给 alert_event 加
   `offender_group TEXT` + `offender_entries TEXT`(JSON 数组,AlertOffenderEntry
   补 Codable);`AlertEventStore.record` 加 offender 参数;老行 NULL 兼容。
7. **MCP recent_alerts**:读侧聚合输出带「最近一次归因」(组名+进程串);工具
   描述同步一句。

## 验收

- 高负载告警触发:系统通知正文与应用内提示行都能看到「承载组 + 前几名进程
  (CPU%/内存)」,与 NemoNotch 卡口径一致。
- recent_alerts 返回历史告警带归因;迁移前老库老行读出无归因不炸。
- diskAvailable / devServerIdle 告警维持原文案(无归因不硬造)。
- 告警解除后 offenders 不残留(同主体再触发归因是新算的)。

## 测试

- PulseCore:`AlertOffenderTests` 补共享文案函数;AlertEventStore 往返(JSON
  列);McpEyes recent_alerts 带归因 + 老行 NULL。
- PulseTests:AlertCenterTests——注入假 sender 断言通知 body 带归因;
  offenders 字典 fired 写入 / resolved 清除。
- 合并前 `sh scripts/check.sh` 全绿。

## Comments

- 2026-11-12 立项:用户拍板(iSurge 差距挑选,「现存一个需求 md,然后做告警点名责任 app」)。
- 2026-11-12 实施:范围 1-7 全落地(13 文件,+379/−67);文案单出处
  `AlertOffenderAttribution.bodyText`(toast 的 offenderBody 迁来,toast 侧保留
  clamp);AlertCenter.offenders 字典 fired 写 / resolved 清;补发路径同带归因;
  迁移 `alert-offender-outlets-v1` 两列 JSON。门禁:核心 759 · app 502 · 合计
  1261 全绿;SpaceScanCache 性能预算用例一次高负载毛刺(5.18s>5s)单跑即绿,
  与本次改动零关联,记档合并。合并 develop @e0a577c(hook 装机完成),已推 origin。
