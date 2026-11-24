# 01: 助手快照判龄——堵住"假健康读数"灌进历史

**What to build:** 修复 REPORT 高1:helper → app → 历史链路只判断"文件读得到、JSON 合法",从不判断快照是不是旧的;energy-gate-fix 四态与历史口径因此可被冻结值长期欺骗。

**Status:** ready-for-agent

证据见 `../REPORT.md` §高1。关键锚点:
- `Packages/PulseHelper/Sources/PulseHelperCore/Collector.swift:85,106-114` 采集失败保留旧 `collectedAt`;
- `Packages/PulseHelper/Sources/pulse-helper/main.swift:34-37` 每 60s 无条件重写文件(mtime 新、`epochMs` 旧);
- `Pulse/Live/EnergyHelperClient.swift:14-33` 零时间比较;
- `Pulse/Features/EnergyImpactFeature.swift:96-125` 每轮照常广播;
- `Pulse/Features/EnergyHelperGate.swift:27-35` 只在抛异常时判失败。

**Agent Brief:**
1. `EnergyHelperClient.fetchLatest()` 增加判龄:快照 `epochMs` 与当前时间差超阈值(建议 150s ≈ 2.5 拍,阈值写成常量并注释出处)抛新的 `HelperClientError.snapshotStale`。
2. `EnergyImpactFeature.pollOnce()` 在 `collectedAt` 过期时拒绝发布 `reading` 与 `.gauges` 广播,并让 `lastFetchFailed`/`nextPollInterval` 进入 5s 快 polls 与健康日志翻转沿(沿既有 transition-not-tick 惯例)。
3. `PrivilegedHelperStatus.setInstalled(false)`/注销路径删除 `/var/run/com.gaozimeng.pulse.helper.json`,防残留快照跨会话污染。
4. 单测(纯注入,不碰真文件/真进程):陈旧 JSON → `snapshotStale`;Gate 在 status=.enabled + 陈旧快照时判 `.approvedButNotRunning`;恢复新鲜快照 → 日志只翻一次。

**验收:** 陈旧快照不再进 UI/历史;助手被杀/注销后 Gate 说实话;core/app 相关测试与 `sh scripts/check.sh` 全绿。

## 核实(2026-11-24)

真问题(后果比原文更广)。逐条属实;另:助手 plist 无 KeepAlive,被杀不会重启;电池页排行不看 Gate、`pollOnce` 不看 helperStatus 就广播——注销助手后旧排行仍显示、旧值仍每 60s 进历史。本机实测快照落后 3 分钟、助手日志 37 次超时。**Brief 修正**:第 3 步不可行(app 非 root,删不掉 /var/run 快照),改为「判龄(now − collectedAt > 150s 视为过期,覆盖首轮 distantPast)+ Gate 未批准不广播」。
