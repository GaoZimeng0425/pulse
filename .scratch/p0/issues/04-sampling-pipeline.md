# 04: 菜单栏真数字:采样管线

**What to build:** 采样从假变真:后台 actor 以自适应节奏驱动 LiveProcessSource——弹窗关闭 5s、打开 1s;CPU 差分器用相邻两次快照的累计 CPU 时间差 ÷ 墙钟得到进程 CPU%(与活动监视器同算法);菜单栏数字 = 系统 CPU 负载(全部进程 CPU% 之和 ÷ 逻辑核数,0–100%),超过 70% 变红。差分器以"同一进程两次累计值"为夹具做纯逻辑单测。

**Blocked by:** 01, 02。

**Status:** ready-for-agent

- [x] 菜单栏数字随真实负载跳动,与本机活动监视器读数同量级
- [x] 跑多核死循环时数字明显攀升、超过 70% 变红,停止后回落
- [x] 弹窗开/关时采样节奏在 1s/5s 间切换(合盖省电)
- [x] CPU 差分纯逻辑单测:构造两次累计值,断言 CPU% 正确、核数换算正确
- [x] 进程两次采样间消失不崩溃(差分按存活进程交集计算)
- [x] 采样一轮的开销毫秒级(约 800 pid 量级)

## Comments

- **2026-10-13(工单 04 完成)**:CPUDiffer / SamplingScheduler(纯逻辑)+ Sampler actor(注入时钟与睡眠,零真实等待的单测)+ SystemMonitor(@Observable)落地;菜单栏与弹窗头部接真实系统 CPU 负载,>70% 变红;组卡保持假数据待工单 05。
- **关键发现(继承的前一 agent 探针抓到、本次定位修复)**:本机(Apple Silicon,`mach_timebase_info` = 125/3)的 `pti_total_user/system`(及 rusage 时间字段)是 **mach_absolute_time 原始 tick 而非纳秒**,不换算所有 CPU% 会缩小约 41.7 倍(6 个死循环只显示 1.9% 负载)。已在 `LiveProcessSource.nanoseconds(fromTicks:)` 按时间基准换算,并在 `LiveProcessSourceSmokeTests.testCPUTimeFieldMatchesPOSIXReferenceScale` 用 getrusage 基准做了刻度校准回归测试(先红后绿)。`docs/probe.swift` 的 `_ns` 标签同步改为 `_tick`。临时探针 TempLoadProbeTests 已删除,必要部分折入上述正式测试。
- **端到端验证**(真实系统、同算法):空闲 39.6% → 8 个单核死循环 84.6%(>70% 变红阈值)→ 停止后 38.8%;一轮采集 810 pid 冷 44ms / 热 35ms。
- 测试 40 个全绿:CPUDifferTests 10 / SamplingSchedulerTests 7 / SamplerTests 3 / Live 冒烟 5(含新刻度校准)/ 其余为既有工单。
