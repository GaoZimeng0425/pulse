# 02: GPU 页(曳光弹)——IORegistry 读数 + 11-tab toolbar 一次性改造

**What to build:** GPU 家族打穿全程:Live 适配器读 IORegistry 加速器服务的 PerformanceStatistics 原始字典,核心包纯值模型做解析(总利用率/Renderer/Tiler 细分/显存分配与在用),功能模块挂 MonitorFeatures,SensorScheduler 登记可见 5s 节奏;主窗口新开 GPU tab(利用率大数 + 细分行 + 显存 + 趋势线,趋势复用统一走势图组件),弹窗加 GPU 紧凑组(利用率一行)。本票同时**一次性扛下 toolbar 容量改造**:按终态 11 tab 定尺寸(主窗口最小宽度上调或 pill 微收窄,取 DESIGN.md 令牌表允许的方案),后续各家族票只加自己的 tab 不再动布局。防御:>100 钳 100、电源管理关电(AGC)时归 0 视为正常态、缺字典跳过、静态信息进程级缓存。新页面挂进 MonitorVisibility 信号体系(GPU 页可见才采样,弹窗/主窗口关树后零逐轮重算)。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] GPU tab 上线:利用率大数、Renderer/Tiler、显存真实显示,数值与活动监视器 GPU 档数量级互证
- [ ] 弹窗 GPU 紧凑组出现,开弹窗才采、关窗即停
- [ ] toolbar 按终态 11 tab 定尺寸,720/最小宽下新布局验证不溢出(本票只放 GPU 一个新 tab)
- [ ] 解析模型合成载荷单测(钳位/关电/缺键三分支),Live 冒烟一次真读
- [ ] 关两窗 15s 指纹全零(ADR-0006 验收协议);check.sh 全绿
