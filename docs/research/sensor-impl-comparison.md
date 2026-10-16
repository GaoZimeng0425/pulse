# 传感器实现对比调研:stats / petal / mole vs Pulse

> 2026-10-15 只读调研。输入:本地克隆的三个参考库(/tmp/stats-ref、/tmp/petal-ref、
> /tmp/mole-ref)+ 本仓库现有实现。目标:为 P1(磁盘/网络/电池)与 P2(GPU/ANE/
> 温度风扇/声音/蓝牙/容器)逐传感器钉死 API、算法、缓存与陷阱,每条论断带
> `repo 文件:行号` 引用。结论与 §4 现方案对照:哪些照做、哪些要修订。
>
> 协议边界(与设计文档 §12 一致):stats(MIT)与 petal(MIT)的算法/代码可移植,
> 文件头注明来源;mole(GPL-3.0)只取产品点子,不看不抄实现——本文引用 mole
> 代码行仅用于说明"它做了什么",不构成移植依据。

## 1. 架构对比总览

| | Pulse(我们) | stats | petal | mole |
|---|---|---|---|---|
| 形态 | 常驻 SwiftUI 菜单栏 | 常驻菜单栏(模块化) | 一次性全盘扫描 + 增量跟随 | CLI 一次性 TUI + `--watch` 流 |
| 数据驱动 | 单个 `Sampler` actor,固定 5s/1s 心跳(`Pulse/Sampler.swift:3-16`),快照→差分→归组→MainActor 交付(`Pulse/Sampler.swift:102-130`) | 每模块若干 Reader,各自 `Repeater`(DispatchSourceTimer)按自己的 interval 跑 `read()`(`stats-ref Kit/module/reader.swift:209-238`) | 三阶段:精确容器对账 → rayon 并行目录扫描 → FSEvents 增量(`petal-ref src/scan.rs:397-427`、`petal-ref src/watch.rs:1-10`) | 分层采集调度:fast/process(1s)/full(30s)三档(`mole-ref cmd/status/collection.go:43-54`;`mole-ref cmd/status/main.go:18-22`) |
| 状态与缓存 | 上轮快照 + tick 差分存在 actor 内(`Pulse/Sampler.swift:76-77`) | Reader 持有上次计数与各类 TTL 缓存;启动时从 DB 恢复上次值,UI 冷启动即有数(`stats-ref Kit/module/reader.swift:93-97`) | 扫描前先记 FSEvents 位置,结果上屏后从该位置重放增量(`petal-ref src/watch.rs:31-34`) | Collector 内分层缓存:静态硬件、BT 30s、GPU/net/disk 快缓存(`mole-ref cmd/status/metrics.go:235-259`) |
| 数据获取 | libproc/sysctl 用户态直调 | IOKit/IOReport/SMC/DASession 直调为主,少数走子进程(nettop/ps/top/system_profiler/pmset) | libc 直调(getattrlist/getattrlistbulk/statfs/fs_snapshot_list/FSEvents) | gopsutil + 子进程+正则为主(反模式,见 §2.9) |

**动态常驻 vs 一次性扫描的取舍,对 P1/P2 的启示:**

1. **不是所有传感器都该搭同一班心跳。** stats 给每个 Reader 独立 interval:磁盘活动 1s(`stats-ref Modules/Disk/readers.swift:174-175`)、SMART 默认 30s(`stats-ref Modules/Disk/readers.swift:526-528`)、网络详情 15s 节流(`stats-ref Modules/Net/readers.swift:469-479`)、公网 IP 用 `NSBackgroundActivityScheduler`(`stats-ref Modules/Net/main.swift:151`)。我们把 CPU/内存/网络吞吐留在 5s/1s 心跳里,而磁盘**容量对账**(一次 getmntinfo + N 次 getattrlist)和 SMART 这类"几乎不变"的量应有自己的低频档(容量 30–60s、SMART 开机+每小时),不进采样轮——与设计文档 §4 对 SMART 的既定口径一致。
2. **首帧就有数。** stats 在 Reader init 时从 DB 恢复上次值立即回调(`stats-ref Kit/module/reader.swift:93-97`);petal 用容器精确对账先画满第一帧、扫描后台补树(`petal-ref src/scan.rs:397-414`)。P1 磁盘卡的容量/快照部分天然满足(一次对账即全量),网络 "Today/7 天" 累计卷则必须落 SQLite 才能冷启动有数(设计文档 §5 已规划)。
3. **事件驱动优于轮询的场合要用事件。** stats 电池不走轮询,挂 `IOPSNotificationCreateRunLoopSource`(`stats-ref Modules/Battery/readers.swift:34-48`);petal 增量靠 FSEvents(`petal-ref src/watch.rs:45-77`)。我们的电池卡可挂同一个通知源(挂在采样循环之外),磁盘容量可在 `NSWorkspace` 卷挂载/卸载通知时重算对账。
4. **系统睡眠/唤醒要主动清差分基线。** stats 的磁盘活动 Reader 监听 `didWakeNotification` 清空 samples(`stats-ref Modules/Disk/readers.swift:176`),蓝牙 Reader 睡眠时停扫、唤醒重启(`stats-ref Modules/Bluetooth/readers.swift:101-109`),传感器 Reader 唤醒后重置 HID 会话(`stats-ref Modules/Sensors/readers.swift:43`)。Pulse 的 Sampler 目前没有唤醒处理——P1 起所有差分型指标(网络计数、磁盘 rusage)都应在唤醒后丢第一轮或清基线,否则 UI 会出现一根巨刺。

## 2. 逐传感器对比

### 2.1 磁盘容量(容器级口径)

**stats 的做法**(每卷容量,不是容器对账):

- 枚举:`FileManager.mountedVolumeURLs(skipHiddenVolumes)` → `DASessionCreate` → `DADiskCreateFromVolumePath` → `DADiskGetBSDName`(`stats-ref Modules/Disk/readers.swift:53-71`);Recovery 卷直接跳过(`stats-ref Modules/Disk/readers.swift:356-368`);可移动卷默认过滤(`stats-ref Modules/Disk/readers.swift:344-350`)。每轮都重枚举,但用"路径/文件系统没变就只更新 free"的档位避免重复建对象(`stats-ref Modules/Disk/readers.swift:80-88`),卷消失用集合差移除(`stats-ref Modules/Disk/readers.swift:108-114`)。
- 容量:`statfs` 取 total/`f_bavail`(`stats-ref Modules/Disk/readers.swift:123-127`)——注意 stats 读 free 前先 `removeAllCachedResourceValues()`(`stats-ref Modules/Disk/readers.swift:121`)。
- purgeable:APFS 卷用 `CSDiskSpaceGetRecoveryEstimate`,**缓存 60s**(`stats-ref Modules/Disk/readers.swift:129-140`);非 statfs 路径回退到 `volumeAvailableCapacityForImportantUsageKey`(`stats-ref Modules/Disk/readers.swift:156-163`)。
- 磁盘活动(吞吐):IORegistry `kIOBlockStorageDriverStatisticsKey` 的 Bytes{Read,Written} 差分,elapsed 用 `DispatchTime.now().uptimeNanoseconds`(`stats-ref Modules/Disk/readers.swift:248-257`);差分前检查 `bytes >= previous` 且 elapsed 有限,防止计数器回绕出负值(`stats-ref Modules/Disk/readers.swift:274-279`);从 IOMedia 向上找 block storage driver 时带环检测(visited ≤ 256,`stats-ref Modules/Disk/readers.swift:284-321`)。
- SMART:NVMe 走 `IONVMeSMARTInterface` 插件接口,`percent_used` → 寿命、`data_units_written × 512×1000` → 累计写入(`stats-ref Modules/Disk/readers.swift:609-671`);ATA 默认关、可开(`stats-ref Modules/Disk/readers.swift:519-521`),首次读失败会尝试一次性 `SMARTEnableDisableOperations` 再读(`stats-ref Modules/Disk/readers.swift:708-712`);u128 溢出钳到 Int64.max(`stats-ref Modules/Disk/readers.swift:817-831`)。

**petal 的做法**(容器对账,正是 §4 选的口径):

- `statfs('/')` 拿根卷设备 → `container_of` 把 `/dev/disk3s1s1` 归约成容器号 `disk3`(`petal-ref src/disk.rs:188-194`);容器已用 = `(f_blocks - f_bfree) × f_bsize`(`petal-ref src/disk.rs:208`)——这里的 `f_bfree` 是**容器共享空闲**,所以裸 statfs 的 free 在 APFS 上不可信,这正是 §4 引 petal 的原因。
- `getmntinfo(MNT_NOWAIT)` 枚举全部挂载点,过滤 `apfs` 且同容器(`petal-ref src/disk.rs:220-224`);每卷精确已用用 `getattrlist(ATTR_VOL_INFO | ATTR_VOL_SPACEUSED)`(`petal-ref src/disk.rs:165-186`);Data 卷按挂载点 `/System/Volumes/Data` 识别(`petal-ref src/disk.rs:228-232`),VM/Preboot/Update 有固定标签(`petal-ref src/disk.rs:233-235`)。
- 对账兜底:各卷已用之和 < 容器已用时,差额记为 "Other volumes"(未挂载卷通常是 Recovery + 容器元数据,`petal-ref src/disk.rs:241-245`)——这一步 §4 的"与容器总量对账"就是指它,翻译时别漏。
- purgeable:`kCFURLVolumeAvailableCapacityKey` 与 `kCFURLVolumeAvailableCapacityForImportantUsageKey` **两 key 差值**(important − free,`petal-ref src/disk.rs:129-163`)。与 stats 的 `CSDiskSpaceGetRecoveryEstimate` 是两条不同路径,数值可能略有出入(见 §5)。
- 快照:`fs_snapshot_list` 列 Data 卷快照;attrlist **必须**带 `ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_CRTIME`,否则 EINVAL(`petal-ref src/disk.rs:84-87`);64KiB 缓冲循环读记录(`petal-ref src/disk.rs:88-103`);`com.apple.TimeMachine.` 前缀识别本地 TM 快照(`petal-ref src/disk.rs:55-57`),`com.apple.os.update`/`com.bombich.ccc` 识别来源(`petal-ref src/disk.rs:62-69`)。
- 扫描(我们的可回收产物扫描 §8.1 同款技术):子目录 rayon 并行、文件当轮累计(`petal-ref src/scan.rs:345-348`、`:323-324`);硬链接按 `(dev, ino)` 去重(`petal-ref src/scan.rs:334`);iCloud dataless 目录跳过、绝不触发回源下载(`petal-ref src/dirlist.rs:17-19`、`petal-ref src/scan.rs:377-386`);macOS 上用 `getattrlistbulk` 一次 syscall 拿整目录元数据(`petal-ref src/dirlist.rs:3-4`),APFS 克隆共享字节用 `ATTR_CMNEXT_PRIVATESIZE` 单独量(`petal-ref src/dirlist.rs:29-51`)。
- 增量:FSEvents 从"扫描开始前的位置"重放,事件丢失时整体重扫(`petal-ref src/watch.rs:1-10`、`:26-29`)——对应我们把容量重算挂在卷事件上的思路。

**vs 我们 §4**:算法与 §4 完全一致,且补充了两个 §4 没写死的细节:(a) "Other volumes" 对账兜底必须做,否则总数对不上;(b) purgeable 有 stats/CSDiskSpace 与 petal/两 key 差值两条实现路径,P1 建议照 §4 用 petal 两 key 差值(Finder 口径),stats 的 `CSDiskSpaceGetRecoveryEstimate` 留作对照探针。吞吐差分 §4 走 rusage 求和,stats 的 IORegistry 路径(`stats-ref Modules/Disk/readers.swift:248-255`)是 P2 备选(它能拿到系统级含内核 IO 的精确值)。

### 2.2 网络

- 单接口字节计数:`sysctl` mib `[CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, if_index]`,index 由 `if_nametoindex` 得到(`stats-ref Modules/Net/readers.swift:704-712`);解包时逐 `if_msghdr` 步进,只认 `RTM_IFINFO2` 的 `if_msghdr2`,并校验 `ifm_index` 匹配(`stats-ref Modules/Net/readers.swift:714-736`);取 `ifi_obytes`(上传)/`ifi_ibytes`(下载)(`stats-ref Modules/Net/readers.swift:729-730`)。
- **差分防坑三件套**(§4 没写,实现时必须带上):
  1. 首读不产生速率:上一值为 0 时跳过差分,避免把开机以来的累计量当成第一秒的带宽(`stats-ref Modules/Net/readers.swift:304-309`);
  2. 负值钳 0(计数器可能因接口重置回退,`stats-ref Modules/Net/readers.swift:311-312`);
  3. 重连跳变防护:Δ 超过"协商链路速率 ×1.5 × interval"或未知链路时的 100Gbps 上限则丢弃本轮(`stats-ref Modules/Net/readers.swift:314-323`),配合唤醒清基线(§1.4)。
- 接口选择:默认取 `SCDynamicStoreCopyValue("State:/Network/Global/IPv4").PrimaryInterface`,若是 utun/ipsec/ppp/tun/tap/gif/stf/wg 等虚拟前缀则降级找物理口(`stats-ref Modules/Net/readers.swift:111-123`、`:131-133`);物理口回退用 `getifaddrs` 过滤 UP+RUNNING+非 loopback+非 pointopoint(`stats-ref Modules/Net/readers.swift:146-165`)。OrbStack/VPN 用户机器上这层降级是刚需。
- VPN 双计:stats 在检测到系统代理 scope 含 tun/tap 时把带宽**除以 2**(用户可关的启发式,`stats-ref Modules/Net/readers.swift:171-176`、`:330-333`)——这是它单接口计数 + VPN 出口的补丁;我们选定物理网卡后不需要这个 hack,但要知道它的存在。
- 累计卷:stats 把 Δ 累加进内存 total 并支持按天/周/月重置(`stats-ref Modules/Net/readers.swift:325-326`、`:755-791`);我们的 Today/7 天按 §5 落 SQLite,不做内存累计。
- 子进程路径(仅作对照):stats 的"每进程流量"用 `nettop -P -L 1`(`stats-ref Modules/Net/readers.swift:433-442`)。§4 已排到 P3,维持不变。
- 不抄的部分:公网 IP 靠 `curl api.mac-stats.com`(`stats-ref Modules/Net/readers.swift:669-702`)——违反我们"全程本地无网络"的边界;WiFi 详情(SSID/RSSI/信道,CoreWLAN + 定位权限,`stats-ref Modules/Net/readers.swift:551-589`、`:591-644`)是 P2 之外的加分项,不在 Vitals 面板清单内,暂不做。

**vs 我们 §4**:API 与口径一致;修订点 = 差分三件套 + 虚拟接口降级必须进实现清单。

### 2.3 电池

- 事件驱动:`IOPSNotificationCreateRunLoopSource` 挂 RunLoop,电源状态变化才 `read()`,不轮询(`stats-ref Modules/Battery/readers.swift:34-48`)。
- 电量/状态:`IOPSCopyPowerSourcesInfo` → `IOPSCopyPowerSourcesList` → `IOPSGetPowerSourceDescription`,按 `kIOPSInternalBatteryType` 挑内建电池(`stats-ref Modules/Battery/readers.swift:61-71`);UPS 单列(`stats-ref Modules/Battery/readers.swift:73-84`);电量 = `kIOPSCurrentCapacityKey / 100`(`stats-ref Modules/Battery/readers.swift:91`);`kIOPSTimeToEmptyKey` / `kIOPSTimeToFullChargeKey`(`stats-ref Modules/Battery/readers.swift:93-94`)。
- 健康度:IORegistry `AppleSmartBattery`(`stats-ref Modules/Battery/readers.swift:16`)上读 `DesignCapacity`、`AppleRawMaxCapacity`(ARM)/`MaxCapacity`,逐级回退 `NominalChargeCapacity` → `BatteryData["NominalChargeCapacity"]` → `FullChargeCapacity`(`stats-ref Modules/Battery/readers.swift:102-116`);健康 = `round(100 × max/designed)` 且钳 100(`stats-ref Modules/Battery/readers.swift:120-123`)。循环次数 = `CycleCount`(`stats-ref Modules/Battery/readers.swift:100`)。
- 功率:电流 `Amperage`、电压 `Voltage/1000`(`stats-ref Modules/Battery/readers.swift:125`、`:191-196`);**ARM 上功率优先取 SMC `PPBR`**,拿不到才算 V×A/1000(`stats-ref Modules/Battery/readers.swift:138-139`);适配器功率 SMC `PDTR`(`stats-ref Modules/Battery/readers.swift:140`)。SMC 键属 P2 范围,P1 先用 V×A。
- 温度回退链:IORegistry `Temperature/100` → `AppleSmartBatteryPack.BatteryData["Temperature"]` → SMC `TB1T`/`TB2T` 均值(`stats-ref Modules/Battery/readers.swift:198-221`)。
- 两个防御点:设计容量为 0 时钳成 1 防除零(`stats-ref Modules/Battery/readers.swift:106-108`);`ChargerData["NotChargingReason"] != 0` 且未充电、电量未满时把"优化充电已介入"置真——macOS 会表现为"接着电但不充"(`stats-ref Modules/Battery/readers.swift:148-158`),不做这个映射 UI 会误报故障。
- 电源适配器瓦数:`IOPSCopyExternalPowerAdapterDetails` 的 `kIOPSPowerAdapterWattsKey`(`stats-ref Modules/Battery/readers.swift:129-136`)。

**vs 我们 §4**:一致;修订点 = (a) 建议事件驱动而非每轮 IOPS 轮询(轮询也便宜,二选一);(b) NotChargingReason 语义映射进实现清单;(c) `AppleRawMaxCapacity` 的 ARM/Intel 分叉(我们是 arm64-only,可只走 ARM 分支)。

### 2.4 GPU 利用率

- 枚举:`fetchIOService(kIOAcceleratorClassName)`,每个 accelerator 读 `PerformanceStatistics` 字典(`stats-ref Modules/GPU/reader.swift:103-117`)。
- 键名:`"Device Utilization %"`(总利用率,回退 `"GPU Activity(%)"`)、`"Renderer Utilization %"`、`"Tiler Utilization %"`、`"Temperature(C)"`、`"Fan Speed(%)"`、`"Core Clock(MHz)"`、`"Memory Clock(MHz)"`(`stats-ref Modules/GPU/reader.swift:139-145`)——与 §4 列的键名一一对应,且 stats 多留了一层 `GPU Activity(%)` 回退,照抄。
- 防御:值 >100 钳 100(`stats-ref Modules/GPU/reader.swift:209-226`);读不到 IOClass/PerformanceStatistics 就 `continue` 跳过该设备(`stats-ref Modules/GPU/reader.swift:109-117`);AMD/Intel 独显温度回退 SMC `TGDD`/`TCGC` 且排除 128 这个哨兵值(`stats-ref Modules/GPU/reader.swift:154-167`);`AGCInfo["poweredOffByAGC"]` 判断 GPU 是否被电源管理关掉——关掉时利用率归 0 是正常态不是故障(`stats-ref Modules/GPU/reader.swift:205-207`)。
- 静态信息(型号/核心数/显区)**只在 setup 一次性取**:`SystemKit.shared.device.info.gpu` + `IOPCIDevice` 过滤 display(`stats-ref Modules/GPU/reader.swift:59-99`)。设计文档 §12 提到的"GPU 静态信息缓存 10min"在代码里没有对应物——实际是**进程生命周期级**的 setup 缓存,本文据此修正该表述。
- 加分项:帧率走 IOReport `DCP*` 组 `"swap"` 子组的计数差分/elapsed(`stats-ref Modules/GPU/reader.swift:257-309`),属于同文件免费送的思路,Vitals 面板没有,不做。

**vs 我们 §4**:一致,无需修订;把钳位、AGCInfo、128 哨兵三个防御点补进 P2 实现清单。

### 2.5 神经网络引擎(ANE)

- 建订阅:`IOReportCopyChannelsInGroup("Energy Model")` → 可变拷贝 → `IOReportCreateSubscription`(`stats-ref Modules/GPU/reader.swift:314-325`),GPU 模块与 Sensors 模块各建一份(后者还合并出 CPU/GPU/RAM/PCI 通道,`stats-ref Modules/Sensors/readers.swift:533-555`)。
- 读数:`IOReportCreateSamples` 遍历通道,只认 group == "Energy Model" 且通道名 `ANE` 前缀;**原始值是无量纲整数,必须按 `IOReportChannelGetUnitLabel` 的单位(mJ/µJ/nJ/pJ,默认 nJ)换算成焦耳**(`stats-ref Modules/GPU/reader.swift:340-362`)——这是 §4 没写的关键细节,不做单位换算功率会差几个数量级。
- 功率 = ΔE/Δs,差分对上一轮采样;**首次读返回 0**(没有基线,`stats-ref Modules/GPU/reader.swift:367-376`)。Sensors 模块同款五路功率(CPU/GPU/ANE/RAM/PCI)首读也返回全零(`stats-ref Modules/Sensors/readers.swift:612-615`)。
- 归一化:按芯片最大功耗表,stats 已含 M1→M6 全系(M1 2.0W … M6 16W,未知芯片兜底 8W,`stats-ref Modules/GPU/reader.swift:27-41`)。§4 说"自带 M1–M6 最大功耗表",与代码一致。
- 采样条件:整套 ANE/帧率路径包在 `#if arch(arm64)`(`stats-ref Modules/GPU/reader.swift:69-73`、`:241-249`)。

**vs 我们 §4**:一致;修订点 = 单位换算 + 首读返回 0 两条必须进实现清单。

### 2.6 温度 / 风扇(SMC)

- SMC 连接:`IOServiceMatching("AppleSMC")` → `IOServiceOpen`(用户态,无权限门槛,`stats-ref SMC/smc.swift:170-192`);注意设计文档 §12 写的文件路径 `SMC/smec.swift` 实际是 `SMC/smc.swift`,本文按实际路径引用。
- 解码:同一 key 的字节流按 dataType 解释,`sp78` ÷256(温度)、`fpe2`(风扇转速)、`flt` 等 18 种(`stats-ref SMC/smc.swift:208-278`);全零字节返回 nil 但 `FS! `/`F?Md` 等风扇模式键例外(`stats-ref SMC/smc.swift:220`);键枚举靠 `#KEY` 计数 + `readIndex`(`stats-ref SMC/smc.swift:321-329`)。
- 传感器发现:SMC 全键里按首字母 T/V/P/I 过滤(`stats-ref Modules/Sensors/readers.swift:77-82`),与内置命名表匹配,支持 `Ps%N` 式通配展开成每核传感器(`stats-ref Modules/Sensors/readers.swift:90-104`);不在表里的进"未知"组,默认折叠(`stats-ref Modules/Sensors/readers.swift:105-117`)。
- 风扇:数量 `FNum`,命名 `F?ID`,转速/上下限 `F?Ac/F?Mn/F?Mx`(`stats-ref Modules/Sensors/readers.swift:350-386`);模式 ARM 读 `F?Md`(0=自动 1=手动 3=系统按自动处理),Intel 走 `FS! ` 位掩码(`stats-ref Modules/Sensors/readers.swift:388-412`)。
- 踩坑记录(照单全收):M2 有坏传感器,CPU 温度 <10 或 >120 时沿用旧值(`stats-ref Modules/Sensors/readers.swift:155-159`);温度 0 或 >110 丢弃、电流 >100 丢弃(`stats-ref Modules/Sensors/readers.swift:128-135`);`VD0R` <0.4V、`ID0R` <0.05A 钳零(`stats-ref Modules/Sensors/readers.swift:266-272`)。
- 派生传感器:Average/Hottest CPU/GPU/SOC、Fastest fan 都是算出来的(`stats-ref Modules/Sensors/readers.swift:288-340`、`:217-248`);整机能耗把 `PSTR` 对时间积分(`+= PSTR×Δt/3600`,可与 §5 累计卷同表,`stats-ref Modules/Sensors/readers.swift:250-263`)。
- 附加通道(可选):Apple Silicon 各子系统功率来自 IOReport "Energy Model"(§2.5);隐藏 HID 传感器走 `IOHIDEventSystemClientCreate` + page/usage 匹配(温度 0xff00/0x0005 等,`stats-ref Modules/Sensors/reader.m:38-81`、`stats-ref Modules/Sensors/readers.swift:418-453`),私有度高、stats 默认关闭——P2 不做,留作探针。

**vs 我们 §4**:一致("社区文档完备"说的就是这套键名);修订点 = m2 坏传感器钳位和 110/120 过滤线必须带上,否则 UI 会出现 -1°C 或 200°C。

### 2.7 声音

- stats **没有独立 Sound 模块**(Modules/ 下无此目录);音量/静音只作为遥控部件实现在 Kit 里:`kAudioHardwarePropertyDefaultOutputDevice` 拿默认输出设备,`kAudioDevicePropertyMute`、`kAudioDevicePropertyVolumeScalar` 读写(`stats-ref Kit/plugins/SystemStats.swift:485-554`)。这印证 §4 的 CoreAudio 路径,但只覆盖系统输出音量这一层。
- §4 里的"macOS 14+ 进程音频 API(每 App 音量/输入电平)"在三个参考库里都**没有实现可参照**(stats/petal/mole 均无),P2 声音卡是三库里唯一的空白区,只能对齐 Vitals 行为 + 官方文档自行探索(见 §5)。

**vs 我们 §4**:路径一致但无参考实现;建议 P2 声音卡先做系统输出音量/静音/设备列表(CoreAudio,低风险),每 App 音量单独探针验证后再排。

### 2.8 蓝牙

stats 的蓝牙电量是**五源合并**,单一 IOBluetooth 路径覆盖不了大多数设备:

1. IORegistry `AppleDeviceManagementHIDEventService`(Apple 外设:键鼠/耳机),`BatteryPercent` + `Product`,地址从 `DeviceAddress`/`SerialNumber`/`BD_ADDR` 逐级回退(`stats-ref Modules/Bluetooth/readers.swift:288-315`);
2. UserDefaults `/Library/Preferences/com.apple.Bluetooth` 的 `DeviceCache`/`PairedDevices`/`CoreBluetoothCache`(免权限读缓存,`stats-ref Modules/Bluetooth/readers.swift:319-364`);注意坑:缓存里的电量 `1` 要当 `100` 解释(`stats-ref Modules/Bluetooth/readers.swift:339-341`);
3. `system_profiler SPBluetoothDataType -json`,**TTL 30s** 缓存(`stats-ref Modules/Bluetooth/readers.swift:44-47`、`:368-375`、`:386-433`);
4. `pmset -g accps -xml` 的配件电量(耳机盒/双耳分列),**TTL 10s** 缓存(`stats-ref Modules/Bluetooth/readers.swift:500-621`);
5. CoreBluetooth GATT 电池服务 `0x180F`/特征 `0x2A19`,按需 `connect` + `discoverServices`(`stats-ref Modules/Bluetooth/readers.swift:49-50`、`:181-202`、`:486-497`)。

合并规则:`IOBluetoothDevice.pairedDevices()` 提供已配对/连接态与 RSSI(`stats-ref Modules/Bluetooth/readers.swift:132-143`);RSSI 127 表示未知(已知 HID 则填 100,`stats-ref Modules/Bluetooth/readers.swift:156`);多源按"规整地址(`:`→`-` 小写)→ 唯一名称 → 唯一 vendorId+productId"三级匹配,名称有歧义直接放弃(`stats-ref Modules/Bluetooth/readers.swift:256-284`);睡眠停扫/唤醒重启(`stats-ref Modules/Bluetooth/readers.swift:101-109`)。

**vs 我们 §4**:需要修订。§4 只写"IOBluetooth 已连设备 service 数据"——单靠它拿不到 BLE 外设电量(stats 才演化出五源)。P2 建议按"1 IORegistry → 2 蓝牙 plist 缓存 → 5 CoreBluetooth GATT"的顺序实现(全 API 化、无子进程),3/4(system_profiler/pmset)作为兜底再评估——它们是子进程,但有 TTL 缓存、频率极低,不算反模式(stats 自己也是这么控制的)。

### 2.9 容器

- stats **没有容器模块**(Kit/Modules 全文无 docker 引用);petal 是磁盘工具也不涉及。三个参考库对"容器面板"零覆盖。
- mole 有两条相关点子(只取点子):数据落点——`~/Library/Containers/com.docker.docker/Data` 与 `~/Library/Group Containers/*dev.orbstack/data`(glob 匹配,`mole-ref cmd/analyze/insights.go:63`、`:69-79`),可作为我们"磁盘卡把容器数据当一个大目录单独列一行"的素材;以及它的 `mo status` 仪表盘根本没有容器页——说明社区也还没把这一块做顺。
- §4 的方案(docker.sock HTTP API 或 `docker ps`)维持原判,但要点名:这是 P2 里唯一**完全没有参考实现背书**的传感器,socket 路径(OrbStack 是否暴露 `/var/run/docker.sock`)、权限、响应结构都要先探针(见 §5)。

### 2.10 mole 数据层的反模式证据(为什么"只拿点子")

- 数据获取以子进程为主:thermal/GPU/bluetooth 全靠起 `system_profiler`/`df`/`ps` 等外部进程并发跑(`mole-ref cmd/status/metrics.go:426-429` 注释自证:"the concurrent collectors below spawn their subprocesses (system_profiler, df, ps, ...)")。为此它甚至要把 CPU 采样**挪到子进程风暴之前**,否则自己的采集负载会污染 100ms 窗口的读数(issues #1237,`mole-ref cmd/status/metrics.go:426-431`)——常驻监视器每秒干这事不可持续;Pulse 的 libproc/sysctl 直调路径天然没有这个问题。
- 但它的**分层缓存节奏值得抄**:静态硬件缓存进程级、蓝牙 30s、GPU 利用率独立缓存(`mole-ref cmd/status/metrics.go:235-259`、`:489-497`),与 §1 的"不同传感器不同心跳"结论互相印证。
- 产品点子(§8.1 已立项):隐藏空间洞察清单(iOS 备份、90 天未动的下载、DerivedData/Simulator/Homebrew/pip/uv 缓存、Docker/OrbStack 数据),带"父子去重防双计"注释(`mole-ref cmd/analyze/insights.go:45-48`、`:49-79`);`DiskStatus.Purgeable` 字段注释与 petal 口径一致(`mole-ref cmd/status/metrics.go:169-173`)。

## 3. stats 的 Reader/Portal/Widget 架构:偷什么、不偷什么

**stats 的组织方式**:`Module`(Kit 基类,由 config.plist 声明名/图标/默认开关)持有一组 `Reader_p`(`stats-ref Kit/module/module.swift:104`、`:238-240`);Reader 泛型基类 `Reader<T: Codable>` 负责:线程安全值槽(`stats-ref Kit/module/reader.swift:46-51`)→ `callback()` 依次打通 UI 回调、远程面板、DB(写库节流为 interval×10,`stats-ref Kit/module/reader.swift:113-127`)→ Repeater 定时(`:209-238`)。生命周期:模块 enable/disable 决定 readers start/stop(`stats-ref Kit/module/module.swift:206-236`),弹窗可见性回调里再调 `updateReaderVisibility`(`:262-265`),系统睡眠统一 pause(`stats-ref Kit/module/reader.swift:241-254`);秒边界对齐的可选节拍器(`:201-207`)。Portal(popup 抽屉)与 Widget(菜单栏小部件)都是 callback 的被动消费者,不碰采集。

**对照我们的 ADR-0003**(编译期模块 + MetricProvider,进程外插件明确不做):stats 的模块边界与 ADR 同构,但它多背了三样我们不需要的东西——DB 持久化耦合进基类(我们已有 §5 的 rollup 计划)、远程面板上报、Widget 体系。**结论:P1 值得引入一个薄 Reader 抽象,但不抄基类的全家桶。** 具体形态建议:

- 定义 `SensorProvider`(编译期协议,ADR-0003:5 说的"P1 第一个功能模块落地时定义扩展点"正是时机):`var cadence: Cadence`(heartbeat / seconds(N) / onEvent)、`func snapshot() async -> T?`、`var lastGood: T?`(读失败时保留上次值供 UI 显示)。
- 归属:CPU/内存/网络吞吐等心跳型指标继续住在 `Sampler` actor 的单一循环节拍里(`Pulse/Sampler.swift:102-130`),不拆;磁盘容量对账、SMART、电池、容器这类**低频/事件型**的作为独立 provider,由一个轻量调度器(actor)按各自 cadence 驱动——对应 stats"每 Reader 自己的 interval"而避免把 30s 的活塞进 1s 心跳。
- 读失败降级照 §10 的既定方针"空白卡不崩主程序",stats 的逐设备 `continue`(`stats-ref Modules/GPU/reader.swift:109-117`)与哨兵值过滤是同一精神的实现细节。
- 接入点:沿用现有"呈现层喂纯逻辑管线"的形状——`GroupingPipeline` 是值类型状态机,SystemMonitor 每轮 `update(snapshot:processCPU:)` 推进(`Pulse/GroupingPipeline.swift:48-62`),配置可热更新(`:36-38`)。低频 provider 走同一模式:SystemMonitor 持有各 provider 的最近快照字段,`apply` 里统一粘合(`Pulse/SystemMonitor.swift:128-151`),卡片 builder(`Pulse/OverviewCards.swift:91-160`)只做取数与格式化——不需要 stats 那条 callback → DB → 远程 → Widget 的链路。
- 不引入:stats 的 DB-in-Reader、远程上报、config.plist 动态模块声明(我们是编译期注册,ADR-0003:3 的"模块即插件"指设置开关,不是运行时装卸)。

## 4. P1 落地注意事项清单

**磁盘卡(petal 容器级口径,MIT 可翻译):**

| 要点 | 出处 | 备注 |
|---|---|---|
| `container_of` 设备名归约 | `petal-ref src/disk.rs:188-194` | `/dev/disk3s1s1` → `disk3`;`map auto_home` 之类返回 None 要容错 |
| 容器已用 = `(f_blocks−f_bfree)×f_bsize` | `petal-ref src/disk.rs:208` | 这是"与 Finder 一致"的已用口径 |
| `getmntinfo(MNT_NOWAIT)` + apfs + 同容器过滤 | `petal-ref src/disk.rs:210-224` | `MNT_NOWAIT` 不阻塞 |
| 每卷 `getattrlist(ATTR_VOL_SPACEUSED)` | `petal-ref src/disk.rs:165-186` | packed struct 回包,别用 statfs 的卷内值 |
| Data 卷识别 + 已知卷标签 | `petal-ref src/disk.rs:226-237` | `/System/Volumes/Data` 是扫描/明细锚点 |
| "Other volumes" 对账兜底 | `petal-ref src/disk.rs:241-245` | 必做,否则与容器总数对不上 |
| purgeable 两 key 差值 | `petal-ref src/disk.rs:129-163` | important − free,`max(0)`;与 stats 的 `CSDiskSpaceGetRecoveryEstimate`(`stats-ref Modules/Disk/readers.swift:129-140`,60s 缓存)二选一或对照 |
| `fs_snapshot_list` 快照列表 | `petal-ref src/disk.rs:75-123` | attrlist 必须含 RETURNED_ATTRS/NAME/CRTIME 否则 EINVAL(`:84-87`);TM 前缀识别 `:55-57` |
| 刷新时机 | §1.3 | 容量对账 30–60s 或卷事件触发,不进 1s 心跳 |

陷阱:petal 的测试明确断言"data_used + extras 之和 == container_used"(`petal-ref src/disk.rs:305-311`),翻译成 Swift 后建议把这条不变式直接做成单测;快照与 purgeable 语义有交叠(TM 本地快照既占 used 又计入可清除,petal 注释 `petal-ref src/disk.rs:43-57`、`:126-128`),UI 文案要区分"已用"与"实际可用"。

**网络卡(NET_RT_IFLIST2 差分,stats 同款):**

| 要点 | 出处 |
|---|---|
| mib `[CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, index]` 两段式调用 | `stats-ref Modules/Net/readers.swift:704-712` |
| `RTM_IFINFO2` + `ifm_index` 校验 + `ifi_ibytes/obytes` | `stats-ref Modules/Net/readers.swift:714-736` |
| 首读置零 / 负值钳 0 / 重连跳变丢弃 | `stats-ref Modules/Net/readers.swift:304-323` |
| 主接口选择 + 虚拟前缀降级 + getifaddrs 回退 | `stats-ref Modules/Net/readers.swift:113-165` |
| 唤醒/接口切换时清差分基线 | `stats-ref Modules/Net/readers.swift:286-291`、`:176`(类比) |
| Today/7 天累计 | 落 SQLite(设计文档 §5);stats 的内存累计+定期重置(`:325-326`、`:755-791`)不抄 |

**电池卡(IOPowerSources,stats 同款):**

| 要点 | 出处 |
|---|---|
| 事件驱动 `IOPSNotificationCreateRunLoopSource` | `stats-ref Modules/Battery/readers.swift:34-48` |
| IOPS 三连 + 内建电池筛选 + 电量/剩余时间 | `stats-ref Modules/Battery/readers.swift:61-94` |
| 健康/循环容量键与回退链 | `stats-ref Modules/Battery/readers.swift:100-123` |
| 功率(电流×电压;SMC `PPBR` 是 P2 增强) | `stats-ref Modules/Battery/readers.swift:125-140` |
| 温度回退链 | `stats-ref Modules/Battery/readers.swift:198-221` |
| 除零防护 + NotChargingReason 语义 | `stats-ref Modules/Battery/readers.swift:106-108`、`:148-158` |

通用陷阱(P1 三卡共用):① 所有差分/速率卡都要处理系统唤醒后的第一轮(§1.4);② 采样 actor 的交付是 MainActor 粘合(`Pulse/SystemMonitor.swift:80-87`),新卡数据模型保持 `Sendable` 值类型,与 `SamplingUpdate`(`Pulse/Sampler.swift:46-55`)同风格;③ UI 空态沿用"读缺失显示占位不伪造"的既定原则(`Pulse/OverviewCards.swift:121-127`)。

## 5. 开放问题(需本机探针验证)

1. **IOReport "Energy Model" 通道在 macOS 26 的可用性与单位标签**:stats 正常运行说明通道活着,但通道名/单位(mJ–pJ)无兼容承诺。验证:swift 单文件调 `IOReportCopyChannelsInGroup("Energy Model")` 打印通道名+unit label(参照 `stats-ref Modules/GPU/reader.swift:315`、`:348-359`)。
2. **`PerformanceStatistics` 键名在当前芯片(M 系列)的实际值**:M5/M6 上是否仍是 "Device Utilization %";`"GPU Activity(%)"` 回退是否需要。验证:IORegistryExplorer 或 `ioreg -l` dump kIOAcceleratorClassName 条目(`stats-ref Modules/GPU/reader.swift:139`)。
3. **purgeable 两口径差异**:`CSDiskSpaceGetRecoveryEstimate`(stats)与 CFURL 两 key 差值(petal)在 macOS 26 数值是否一致、哪个与 Finder"可用"一致。验证:两者同刻输出对比(`stats-ref Modules/Disk/readers.swift:134`、`petal-ref src/disk.rs:158-161`)。
   ✅ **结论(2026-10-16 探针①,`docs/probes/01-purgeable-two-sources.swift` + `.output.txt`)**:两口径在 macOS 26 **数值完全一致**(同刻 6.61 GB,Δ=0.00 GB);与 Finder「可用」一致的是 **CFURL `volumeAvailableCapacityForImportantUsageKey`**——osascript 同刻问 Finder 返回 209.55 GB,与 importantUsage 分毫不差(裸 statfs f_bavail=202.9 GB 是另一档)。05 磁盘卡照 §4 既定走 petal 两 key 差值,stats 的 CSDiskSpace 路径不需要了。
4. **`fs_snapshot_list` 在 macOS 26 仍免 root 可列**:petal 依赖它,签名无变化的话应当可用。验证:照 `petal-ref src/disk.rs:75-107` 翻译 20 行探针跑一次。
   ✅ **结论(2026-10-16 探针②,`docs/probes/02-fs-snapshot-list.swift` + `.output.txt`)**:**免 root 可列成立**(uid=501,Data 卷 rc=0 空列表——tmutil 交叉确认本机当时确无 TM 快照;根卷额外列到 1 个 `com.apple.os.update-*` 密封系统卷快照)。负对照成立:attrlist 缺 `ATTR_CMN_RETURNED_ATTRS` 时 rc=-1 EINVAL,petal 的 attrlist 三件套要求原样照搬。注意:成功空列表时 errno 是残留值不可信,判成败要看返回值。
5. **AppleSMC user client 在 macOS 26 无弹窗/无权限门槛**:stats 依赖它读温度。验证:调 `SMC getValue("FNum")`/`"TB1T"`(`stats-ref SMC/smc.swift:172-186`、`stats-ref Modules/Sensors/readers.swift:73`)。
6. **ANE 最大功耗表对 M5/M6 的数值**(stats 已有 16W 行但来源未注明,`stats-ref Modules/GPU/reader.swift:36-38`):归一化上限错只会影响进度条比例,不崩;可先用 stats 值,发现饱和/常年低估再调。
7. **OrbStack 的 docker.sock 路径**:容器 tab 无参考实现(§2.9)。验证:`ls /var/run/docker.sock` + OrbStack 设置页;若只有 `~/.orbstack/run/docker.sock`,HTTP 客户端要支持可配置 socket。
8. **macOS 14+ 进程音频 API 的公开面**(每 App 音量/输入电平):三库无实现(§2.7)。验证:查 CoreAudio 头文件 `AudioHardware.h` 的 process tap 相关常量在 macOS 26 SDK 的可见性,再做最小 demo;麦克风权限弹窗时机要单列。
9. **`nettop -P -L` JSON 流的输出稳定性**(P3 每 App 网络才需要):stats 已在防列变化(`stats-ref Modules/Net/readers.swift:436-441` 显式 `-k` 裁剪列)。暂不验证,排到 P3。
10. **IORegistry 块驱动统计对 NVMe 的覆盖**(工单 01 追加,§2.1/§4 吞吐源备选的实证):✅ **结论(2026-10-16 探针③,`docs/probes/03-ioreg-block-driver.swift` + `.output.txt`)**:**覆盖成立**。本机(Apple Silicon NVMe)枚举到 4 个 `IOBlockStorageDriver` 实例;NVMe 驱动(disk0,父节点 NS_01)的 `Statistics` 里 `Bytes (Read)`=3747 GB、`Bytes (Write)`=1888 GB,**2 秒差分有增量**(计数器在走)——系统级内核账,含内核 IO,免 root,不受 rusage 只算用户进程的口径限制。键名照 SDK 是 `"Bytes (Write)"` 不是 "Written"。stats 同款"卷 IOMedia 向上找驱动"遍历(带环检测)从启动卷 `disk3s1s1` 命中同一驱动,映射链可用。回退条件:目标卷向上遍历失败(非典型栈,如某些 RAID/外置盒)或 `Statistics` 缺两键 → 该卷回退 rusage 求和 + 30s 低频档。

## 6. 证据清单(本次读过)

**本仓库**:docs/vitals-clone-tech-design.md(全文,重点 §4/§10/§12);docs/adr/0003-compile-time-modules-not-runtime-plugins.md(全文);docs/GLOSSARY.md(全文,术语对齐:采样/快照/组/出生登记);Pulse/SystemMonitor.swift、Pulse/Sampler.swift、Pulse/GroupingPipeline.swift、Pulse/MetricTabModel.swift、Pulse/OverviewCards.swift(全文)。

**stats-ref(MIT)**:Modules/Net/readers.swift(全文 1336 行)、Modules/Net/main.swift(80-170);Modules/GPU/reader.swift(全文)、Modules/GPU/main.swift(100-230);Modules/Disk/readers.swift(全文 832 行)、Modules/Disk/main.swift(130-340);Modules/Battery/readers.swift(全文);Modules/Sensors/readers.swift(全文)、Modules/Sensors/values.swift(头 60 行)、Modules/Sensors/reader.m(全文);Modules/Bluetooth/readers.swift(全文 622 行);Kit/module/reader.swift、Kit/module/module.swift、Kit/module/module 清单(ls)、Kit/plugins/Repeater.swift、Kit/plugins/SystemStats.swift(480-560 音量段)、Kit/helpers.swift(头 60 行);SMC/smc.swift(1-330)。

**petal-ref(MIT)**:src/disk.rs(全文 322 行)、src/scan.rs(1-130、300-449)、src/dirlist.rs(1-90)、src/watch.rs(1-80)、src/live.rs(1-40)、src 文件清单与行数(wc -l)。

**mole-ref(GPL-3.0,只读思路)**:cmd/status/main.go(1-100)、cmd/status/collection.go(全文)、cmd/status/metrics.go(1-500)、cmd/analyze/insights.go(1-120)、目录结构。

**说明**:调研收尾阶段仓库目录被重命名(`vitals` → `pulse`,本会话中途发生),导致一段时间内仓库路径读写不可用;文档最终落在更名后的仓库,仓库侧文件(GroupingPipeline/GLOSSARY 等)已在恢复访问后复核并补入引用。另一处与设计文档 §12 的出入已在上文修正:stats 的 SMC 实现文件是 `SMC/smc.swift`(§12 写作 `smec.swift`),GPU 静态信息是进程级 setup 缓存(§12 写作"缓存 10min")。
