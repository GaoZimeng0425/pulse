# 02: GPU 页(曳光弹)——IORegistry 读数 + 11-tab toolbar 一次性改造

**What to build:** GPU 家族打穿全程:Live 适配器读 IORegistry 加速器服务的 PerformanceStatistics 原始字典,核心包纯值模型做解析(总利用率/Renderer/Tiler 细分/显存分配与在用),功能模块挂 MonitorFeatures,SensorScheduler 登记可见 5s 节奏;主窗口新开 GPU tab(利用率大数 + 细分行 + 显存 + 趋势线,趋势复用统一走势图组件),弹窗加 GPU 紧凑组(利用率一行)。本票同时**一次性扛下 toolbar 容量改造**:按终态 11 tab 定尺寸(主窗口最小宽度上调或 pill 微收窄,取 DESIGN.md 令牌表允许的方案),后续各家族票只加自己的 tab 不再动布局。防御:>100 钳 100、电源管理关电(AGC)时归 0 视为正常态、缺字典跳过、静态信息进程级缓存。新页面挂进 MonitorVisibility 信号体系(GPU 页可见才采样,弹窗/主窗口关树后零逐轮重算)。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] GPU tab 上线:利用率大数、Renderer/Tiler、显存真实显示(数值与活动监视器互证 = 用户目验项,见 Comments)
- [x] 弹窗 GPU 紧凑组出现(tab 体系自动),开弹窗才采、关窗即停(gate 单测+指纹实证)
- [x] toolbar 容量:并行会话已落 PillTabBar.selectedOnly(未选中纯图标,总量恒定)根治宽度竞争——本票零额外 toolbar 改动,8 pill 随轴自动;11 pill 终态由 04/05/07 各票落地时逐票目验
- [x] 解析模型合成载荷单测 5 例(GpuModelTests:钳位/关电/回退键序/透传),Live 冒烟 1 例真读(GpuSensorTests)
- [x] 关两窗 15s 指纹全零(实测 PID 46852,含 MetricTabStack/MetricCardView/GpuFeature 新名);check.sh 664 例全绿(核心 349+app 315)

## Comments

**2026-10-22 执行完毕(develop @1b65035,hook Release 装机后指纹验收):**

- 实现:PulseCore GpuModel(原始载荷+折算,防御口径移植 stats MIT)/Metric.gpu 令牌(DESIGN.md 先补表 #e87ba4/#d55181)/MetricTab.gpu 第 8 轴/MonitorVisibility.gpuPage 旗标;app LiveGpuSource+GpuSensorProvider(5s 档+门控)+GpuFeature(趋势环 60 点);GPU tab 主卡+总览网格卡;预览 InertGpuSource。
- 门控形状:GPU 传感闸 = 弹窗 ∨ GPU 页,与排行闸分旗(gpuPage 不进 anyWindow——GPU 页可见不白开 nettop,排行页可见不白采 GPU)。
- 过程坑:Swift Testing 风格新测试不进套件(仓库纯 XCTest),转写后 664 例才见增量;轴序 5 个既有测试照 8-tab 更新。
- **待用户目验**:①GPU tab 大数与活动监视器 GPU 档数量级互证(跑点图形负载看数字抬升);②弹窗 GPU 组紧凑形态;③总览网格第 6 张卡(点卡跳 GPU 页);④PillTabBar 8-pill 下选中展开文字的观感。
- 历史 30s 不可见档刻意留给 08 票(先不空转)。
