# 05: 磁盘卡完整(容量/可清除/快照/吞吐)

**What to build:** 磁盘页进入弹窗与主窗口 tab 体系,五个读数:①容器级容量对账(petal 算法,与 Finder 同口径——裸 statfs 的空闲在 APFS 上不可信);②可清除空间(两种官方"可用容量"口径之差,与"实际可用"分开文案);③各卷明细 + "其他卷"差额;④本地快照列表(TM 前缀识别);⑤系统读写速率走势(路径按探针③结论:IORegistry 内核账差分,或回退 rusage 求和 + 30s 低频档)。容量对账走低频档(30–60s 或卷事件触发),不进 1s 心跳。移植代码文件头注明 petal/stats(MIT)来源。

**Blocked by:** 01(口径与路径探针)、02(SensorProvider 骨架)

**Status:** done (2026-10-16,本机 macOS 26 实测)

- [x] 容量与可清除与 Finder 同刻一致(真机对照)——Finder 前后夹测 202.23 GB → 读数 202.29 GB → 202.29 GB,分毫不差(importantUsage 口径,探针①结论复现);可清除 = 两 key 差值 6.66 GB
- [x] 不变式单测:各卷之和 + 其他卷 == 容器总量(petal 同款断言)——合成夹具 + 真机冒烟双侧钉死(本机:数据卷 259.32 / macOS 13.66 / 虚拟内存 12.88 / Preboot 10.89 / 系统更新 0.08 / Recovery 1.54 / 其他卷 0.16 GB,合计 == 容器已用 298.75 GB)
- [x] 快照列表正确识别 TM 快照;免 root 可用(按探针②结论)——fs_snapshot_list 直用,attrlist 三件套照搬,判成败看返回值;记录解析合成 packed 字节单测(截断/越界负例)
- [x] 速率走势显示且差分带计数回退/elapsed 有限防护(合成计数序列单测)——首读置零/计数回退钳零重立基线/elapsed ≤0 或非有限钳零;主路径 IORegistry(本机探针③命中,cadence 5s),回退 rusage 求和 30s 低频档
- [x] 容量 provider 走低频 cadence,调度器体现分档——容量 `.every(30)`、吞吐 5s(IORegistry)/30s(rusage),单一 SensorScheduler 分档驱动,不进 1s 心跳
- [x] 读缺失显示占位不伪造;弹窗 + 主窗口都有磁盘页——Metric.disk tab 常驻轴;容量对账 nil / purgeable 两 key 缺失 / 快照 unavailable 各自占位;lastGood 读失败不白屏

## 实现记录(2026-10-16)

- `Pulse/DiskSensor.swift`:源缝协议两条(容量源/吞吐源)+ 容器对账纯逻辑 + purgeable 差值 + 快照记录解析 + 吞吐差分 + Live 源(IORegistry/stats、对账/petal,均 MIT 注明)+ 双 provider(容量 30s 低频档,吞吐 5s/30s 随路径)。petal 的 getattrlist 回包布局([u32][off_t@4])真机实证成立。
- `Pulse/DiskCardViews.swift`:各卷明细条形卡 + 快照列表卡(TM 前缀识别来源)。
- 接入:Metric.disk tab(内存/电池之间)、弹窗与主窗口磁盘页、SystemMonitor 三 provider 挂单一调度器、PulseFormat 十进制 GB 与速率格式化。
- 测试:DiskSensorTests 31 例 + LiveDiskSourceSmokeTests 3 例 + MetricTabModelTests 适配;全量 345 例绿。
