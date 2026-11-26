# 01: 采样固定 5 秒

**What to build:** 对全部进程的采样从「弹窗打开 1 秒 / 其余 5 秒」改为固定 5 秒。
删掉 1 秒档、按弹窗可见性选档的逻辑,以及采样循环上「弹窗可见性变化」的入口。
用户看到的是弹窗、主窗口、菜单栏数字都每 5 秒更新一次;弹窗里的 CPU / 内存走势图
点间隔均匀、横跨约 5 分钟。

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

## Agent Brief

**Category:** refactor

**Summary:** 采样节奏收敛为单一取值 5 秒;删除节奏切换消息;同步测试、术语表、
ADR-0006 修订与重叠到的注释。

**Current behavior:**

采样调度(`SamplingScheduler`,PulseCore 纯逻辑)持有一个节奏值,有两档:
`SamplingCadence.popoverOpen`(1 秒)和 `popoverClosed`(5 秒)。采样 actor
(`Sampler`)对外有 `setPopoverVisible(_:)`,经它切档。`SystemMonitor.setPopoverTab`
在更新可见性之后,另起一个 Task 调用 `sampler.setPopoverVisible`。这条消息没有
编号。

**Desired behavior:**

- 节奏只有一个取值 5 秒,一处定义。`SamplingCadence` 的两档与按可见性选档的函数
  删除;调度只保留「上次采样时刻 + 固定间隔 → 距下次采样还要等多久」。
- `Sampler` 删除 `setPopoverVisible`;`SystemMonitor.setPopoverTab` 不再向采样
  循环发消息,只更新可见性并派发给功能模块。
- 启动首轮不等待、超时恒为 0、以采样完成时刻重新起算:三条口径不变。
- 分段睡眠(`maxSleepSlice`,默认 0.5 秒)行为不变。`Sampler` 类型注释里「为了
  及时察觉节奏切换」的理由改掉;测试注入该参数的写法保留。
- 排行采集开关的消息(`setRankingsActive(_:generation:)`)不动。

**Key interfaces:**

- `SamplingScheduler`:公开面收窄为固定间隔下的 `delay(until:)`、
  `recordSample(at:)` 与初始化;不再有切换节奏的方法。
- `Sampler`:删除 `setPopoverVisible`。
- `SystemMonitor.setPopoverTab(_:)`:签名不变,去掉内部发给采样循环的那一步。

**Documentation:**

- `GLOSSARY.md`「采样」定义改为固定 5 秒。
- `docs/adr/0006-window-visibility-gating.md` 末尾追加一条修订(2026-11-25):节奏
  不再由弹窗在场驱动,注明是用户拍板、与原决策相反。只追加,不改原文。
- 与新写内容重叠、且把「弹窗 1 秒」当现状陈述的注释一并更新。已知的几处:采样
  调度测试的文件头、`PulseApp` 里设置窗那段注释、`MeterBar` 的缓动说明、
  `HistoryFeature` 的重查说明、`AreaTrendChartView` 的时刻轴说明。实施时以全仓
  搜索为准;存量工单号不补。

**Acceptance criteria:**

- [ ] 采样调度只有一个间隔取值(5 秒),不存在按可见性选档的入口;全仓没有
      `setPopoverVisible` / `popoverOpen` / `popoverClosed` 的引用
- [ ] `SystemMonitor.setPopoverTab` 不向采样循环发任何消息
- [ ] 只验证 1 秒档的测试删除(`SamplingSchedulerTests` 三条、`SamplerTests`
      一条);保留的节奏测试改名,不再以弹窗开合命名;全量检查通过
- [ ] 术语表与 ADR-0006 修订落档
- [ ] 人工验收:弹窗与主窗口同一指标约每 5 秒同步更新;弹窗走势图点间隔均匀

**Out of scope:** 弹窗可见性的上报路径(归票 02);排行采集开关;分段睡眠的取舍;
走势图的点数或跨度。

## Comments

- 2026-11-25 立票(unified-cadence/spec.md),取代 arch-review-2026-11-24/02 的
  第 1 项。
- 机器高负载时,`SpaceScanCacheTests` 的解码限时用例与 `SpaceScanEngineTests`
  的并行 / 串行一致性用例会偶发失败,与本票无关。全量检查遇到时单独重跑确认。
