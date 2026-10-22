# P2 kickoff:GPU / ANE / SMC / 声音 / 蓝牙 / 容器——口径提案(供 /grill-with-docs 收口)

> 2026-10-22 写。输入:handoff($TMPDIR/pulse-handoff-p2.md)+ 传感实现研究
> `docs/research/sensor-impl-comparison.md`(已落库,不重做)+ 本日六项本机探针
> (见 §1,来源命令与输出在文内或 `docs/probes/04-*`)。
> **本文件是口径提案,不是 spec**:范围/优先级/cadence/门控的拍板走 grill,
> 之后 `/to-spec` → `/to-tickets` 出票(三技能均用户敲)。

## 0. 阶段与边界(既定,不重议)

- P2 = 全量复刻范围的第三阶段:GPU、Neural(ANE)、SMC(温度/风扇)、声音、
  蓝牙、容器,全部免 root(设计文档 §10/§11;研究档案逐一实证)。
- P3(root helper + MCP + 每 App 网络归因)不在本阶段。
- 架构插槽既定:**ADR-0004**(薄 SensorProvider + SensorScheduler cadence,
  `Packages/PulseCore/Sources/PulseCore/SensorProvider.swift` 已就位)+
  **ADR-0003**(编译期 MonitorFeature,`MonitorFeatures` 注册表)+
  **ADR-0006**(新 UI 一律过可见性门控;弹窗/主窗口关树不得逐轮重算)。
- 每家族形状 = PulseCore 纯值模型(`XxxModel`)+ app `XxxSensor` Live 适配器
  + `XxxFeature` 挂 MonitorFeatures + Views 只读功能模块状态(ADR-0003 补记)。
- 常驻成本纪律:每张新卡给出 cadence + 门控理由;稳态测量协议不变(干净重启
  配方 + 15s 指纹 ≥ 三视图名 + 150s 窗)。当前诚实口径 ~1%。

## 1. 本机实证快照(2026-10-22 探针,MacBook Pro 14" M4 / Mac16,1 / 32GB / macOS 26)

| # | 探针 | 命令/出处 | 结果 |
|---|---|---|---|
| 1 | 芯片/机型 | `sysctl machdep.cpu.brand_string hw.model` + `system_profiler SPHardwareDataType` | Apple M4,MacBook Pro(Mac16,1),10 核(4P+6E)。有内建电池、有风扇、有合盖睡眠(唤醒清基线纪律适用) |
| 2 | GPU PerformanceStatistics 键名 | `ioreg -r -c IOAccelerator -l` | **`Device Utilization %` / `Renderer Utilization %` / `Tiler Utilization %` 全在场**(研究档案 §5.2 ✅);"GPU Activity(%)" 回退键未见也不需要;**M4 字典里没有 Temperature(C)/Fan Speed(%)/Core Clock(MHz)** ——GPU 温度只能走 SMC 家族,显存 = `Alloc system memory` / `In use system memory` |
| 3 | IOReport "Energy Model" | `docs/probes/04-ioreport-energy-model.swift` + `.output.txt` | **通道组活着:175 通道,驱动 AppleT8132PMGR;`ANE`/`GPU`/`CPU Energy`/`DRAM`/`DCS`/`SOC_*` 全齐**。单位逐通道不同(`GPU Energy`=nJ,其余=mJ)→ 单位换算纪律实锤(研究档案 :92)。★ **API 形状已变**:返回 `{QueryOpts, IOReportChannels}` 响应字典而非裸数组,stats 旧解包路径在本机会崩,Live 适配器按新形状写 |
| 4 | AppleSMC 服务树 | `ioreg -l \| grep class AppleSMC` | AppleSMCKeysEndpoint / AppleSMCInterface / AppleSMCPMU 在场;**真读数(FNum/温度键/风扇键)未验**,随实施首票探针(研究档案 §5.5 开放) |
| 5 | docker.sock 路径 | `ls -la /var/run/docker.sock ~/.orbstack/run/docker.sock` | **OrbStack 已装**(Group Containers HUAQ24HBR6.dev.orbstack),`/var/run/docker.sock` → `~/.orbstack/run/docker.sock`(符号链接;OrbStack 当前未运行故目标暂缺);Docker Desktop 无。结论:默认打 `/var/run/docker.sock` 即可,socket 缺席 = 空态(研究档案 §5.7 ✅) |
| 6 | 进程音频 API SDK 面 | `grep -l ProcessTap …/CoreAudio.framework/Headers/` | **`AudioHardwareTapping.h` 是 SDK 公开头**(macOS 14+ 进程 tap API 面在场);麦克风权限时机与 Vitals 行为对齐仍需最小 demo(研究档案 §5.8 半开) |
| 7 | 蓝牙设备盘点 | `system_profiler SPBluetoothDataType -json`(一次性探针) | 6 台已配对/已知设备:妙控板、Bose QC35 II、GameSir 手柄、MOONDROP PILL、小米平板、Hack59-2 键盘。**system_profiler 路电量列全空(`-`)** → 电量必须走 IORegistry/GATT 路(研究档案 §2.8 五源结论实证) |

## 2. 六家族口径提案

### 2.1 GPU 利用率/显存(信心:高,今天实证)

- **读**:IORegistry `IOAccelerator` → `PerformanceStatistics`:利用率三键
  (Device/Renderer/Tiler)+ 显存(Alloc / In use system memory)。**不读温度**
  (M4 键不在,§1.2),温度归 SMC 家族。
- **防御点**(研究档案 §2.4,实现清单照抄):值 >100 钳 100;读不到字典
  `continue` 跳过;`AGCInfo["poweredOffByAGC"]` 关电时利用率归 0 是正常态;
  静态信息(型号/核心数)进程级 setup 一次。
- **cadence 提案**:`.every(5)` 挂 anyWindow 门控(弹窗/排行页可见才读);
  若拍板进历史(§3.4),加不可见 `.every(30)` 档。单次读 ~1ms 级,预算可忽略。
- **UI 提案**:主窗口 GPU 页(利用率大数 + Renderer/Tiler 细分 + 显存条);
  弹窗是否加 GPU 组 → grill(弹窗组已全量展示,加组=弹窗变高)。

### 2.2 ANE / 功率(信心:高,今天实证;实现量比预期大——形状改写)

- **读**:IOReport "Energy Model" 订阅,能量差分 → 功率 W;ANE 按芯片最大
  功耗表归一化 %(stats 已含 M1–M6 全系,`Modules/GPU/reader.swift:27-41`,
  M4 行直接抄值)。
- **防御点**(研究档案 §2.5):**单位逐通道换算**(本机实证 GPU Energy=nJ
  其余 mJ,§1.3);差分首读返回 0(无基线);订阅内通道按名过滤(`ANE`/
  `GPU`/`CPU Energy`/`DRAM` 前缀);唤醒后丢首轮(能量差分跨睡眠 = 巨刺)。
- **同订阅读五路功率的顺势机会(决策点 §3.2)**:同一订阅免费送
  CPU/GPU/ANE/RAM/SOC 五路功率(stats Sensors 模块同款,研究档案 §2.5/
  §2.6);Vitals 没把整机功耗做深——这是"复刻之外做深"候选。
- **cadence 提案**:与 GPU 同档同门控(差分窗口 = 采样间隔,须固定节拍,
  不能纯事件驱动)。

### 2.3 SMC 温度/风扇(信心:中;移植量大头)

- **读**:AppleSMC user client(免 root,研究档案 §2.6;`SMC/smc.swift`
  MIT 可移植,smec/sp78/fpe2 18 种解码);传感器发现 = `#KEY` 枚举 × 命名表
  × `Ps%N` 通配;风扇 `FNum`/`F?Ac`/`F?Mn`/`F?Mx`;派生 Average/Hottest
  CPU/GPU/SoC、Fastest fan;GPU 温度也在这条路(M4 无 IORegistry 键,§1.2)。
- **防御点**:M2 坏传感器先例 → 温度 <10 或 >120 沿用旧值、0 或 >110 丢弃;
  电池功率增强键 `PPBR`/`PDTR`(P1 电池卡的 V×A 可升级,顺手活候选)。
- **发现一次缓存进程级**;读数 cadence 提案:可见 `.every(5)` / 不可见停或
  30s(随历史决策 §3.4);单 key 读亚毫秒。
- **UI 提案**:主窗口「传感器」页(温度分组表 + 风扇转速条 + 命名表外折叠
  进"未知"组);键表为空(未来芯片)→ 空态卡不崩。

### 2.4 声音(信心:系统层中 / 每 App 层低——唯一无参照区)

- **读(系统层,先行)**:CoreAudio 默认输出设备 + 音量/静音
  (`kAudioHardwarePropertyDefaultOutputDevice` /
  `kAudioDevicePropertyVolumeScalar` / `Mute`,stats Kit 有参照,研究档案 §2.7)。
- **读(每 App 层,探针后定)**:macOS 14+ 进程 tap(`AudioHardwareTapping.h`
  公开在场,§1.6)——每 App 音量/输入电平;三库零参照,行为对齐 Vitals 自行
  探索;麦克风权限弹窗时机单列。**默认缓,探针票过了再定进不进 v1**。
- **cadence 提案**:`.onEvent`(CoreAudio 属性变更通知),零轮询;设备列表
  低频/onEvent。差分型电平指标同样唤醒清基线。

### 2.5 蓝牙电量(信心:中;五源合并是复杂度大头)

- **读(v1 三源)**:① IORegistry `AppleDeviceManagementHIDEventService`
  (Apple 外设:妙控板直接覆盖)→ ② 蓝牙 plist 缓存(免权限;坑:缓存电量
  `1` 当 `100` 解)→ ③ CoreBluetooth GATT 电池服务 `0x180F`(QC35/MOONDROP
  这类);`IOBluetoothDevice.pairedDevices()` 供连接态/RSSI(RSSI 127=未知)。
  system_profiler / pmset 兜底源 **v1 不进**(子进程;实证 system_profiler
  路电量全空,§1.7,收益本来就低)。
- **合并规则**:地址规整(→`-` 小写)→ 唯一名称 → vendorId+productId 三级
  匹配,歧义即弃(研究档案 §2.8)。
- **cadence 提案**:`.every(30)` + 卡可见门控;睡眠停扫/唤醒重启;GATT
  connect 只在设备需要读时按需建连。
- **UI 提案**:设备列表卡(名称/连接态/电量/RSSI);六台真实设备是收益面。

### 2.6 容器(信心:路径明确;唯一零参照实现)

- **读**:docker.sock HTTP API(`/var/run/docker.sock`,OrbStack 已证 §1.5):
  容器列表/状态/镜像;资源占用(CPU%/内存)是 `docker stats` 流式 API——
  **进不进 v1 是决策点 §3.6**(流式连接常开 vs 低频快照)。
- **空态**:OrbStack 未跑/无 socket → 空白卡 + 提示;不轮询重试风暴
  (30s 档安静探)。
- **cadence 提案**:`.every(30)` 挂卡可见门控;容器页/弹窗组可见才打 socket。
- **UI 提案**:主窗口容器页(列表:名称/状态/CPU/内存);数据卷占用一行
  (mole 点子:`~/Library/Group Containers/*dev.orbstack` 大小)挂磁盘页或
  容器页 → grill。

## 3. 待收口决策点(grill 问题清单)

1. **范围**:六家族全进,还是裁?(研究全证免 root;工作量排序 =
  SMC 移植 > 蓝牙三源 > 声音每App探矿 > 容器 > GPU > ANE。全进预计
  2-3 个周末档,与研究档案同口径。)
2. **五路功率卡**:Energy Model 订阅一鱼五吃(CPU/GPU/ANE/RAM/SOC 功率),
  要不要顺势做整机功耗视图(Vitals 没做深的部分)?或只做 ANE 单卡?
3. **UI 落点**:新 tab 数量——GPU / 传感器 / 蓝牙 / 声音 / 容器全开
  (tab 7→12,toolbar 搜索兜底)vs 合页(GPU+传感器合「硬件」页等);
  弹窗要不要加新组。
4. **历史落库**:温度/GPU/功率哪些进 30 天历史库(进历史 = 不可见也要
  30s 低频档,常驻成本 +小);不进 = 纯可见驱动。
5. **声音每 App 层**:v1 进 / 探针票后再定 / 缓到 P3。
6. **容器 stats 流**:`docker stats` 流式常开 vs 30s 快照 vs 只列容器不算资源。
7. **徽章**:四槽已拍板(CPU/RAM/磁盘+网络);新传感不进徽章(提案:维持,
  不重开徽章配置面)。
8. **电池功率增强(SMC PPBR/PDTR 替 V×A)**:v1 顺手 / 不动。
9. **票组粒度**:§4 的八票形状认不认;探针补全票(SMC 真读数 + CoreAudio
  tap demo + GATT 电池 + docker.sock HTTP)要不要先行单独一票。

## 4. 建议票组形状(to-tickets 输入草案)

| # | 票 | 内容 | 依赖 |
|---|---|---|---|
| 01 | probes 补全 | SMC 真读数(FNum/温度/风扇键表 dump)、CoreAudio 进程 tap 最小 demo、GATT 电池读、docker.sock HTTP 一发 | — |
| 02 | GPU 卡 | Live + 模型 + feature + 门控 + UI | — |
| 03 | Energy Model 功率 | ANE 卡(+§3.2 拍板后的功率视图) | 01(单位换算实证已备) |
| 04 | SMC 温度/风扇 | smc.swift 移植 + 发现 + 派生 + UI | 01 |
| 05 | 声音系统层 | CoreAudio onEvent + 设备/音量 UI | 01(tap 部分视 §3.5) |
| 06 | 蓝牙 | 三源合并 + 设备卡 | 01 |
| 07 | 容器 | docker.sock + 容器页 | 01 |
| 08 | 收口 | 历史/空态/常驻成本复测(指纹协议)+ walkthrough | 02–07 |

每票按既定形状:PulseCore 纯值模型(`swift test` 可测)+ app Live 适配器
(PulseTests)+ MonitorFeature 注册 + SensorScheduler cadence + 可见性门控
(ADR-0006 验收指纹)+ 新数值进 DESIGN.md 令牌表后再写视图。

## 5. 纪律备忘(实施期逐票适用)

- 改 SystemMonitor 挂点前 ripwire 查影响面;机械改写走 ast-grep。
- `ForEach` 不得以 `.indices` 为数据源(lint error 级门禁已装)。
- 视图文件只放视图;`Color`/AppKit 折叠进 app 单独文件(ADR-0003 补记)。
- 所有差分型指标(能量/电平/容器 CPU%):唤醒后清基线/丢首轮。
- 读失败 = lastGood/空态卡,不崩不伪造(ADR-0004 + §10 既定)。

---

## 6. 拍板记录(2026-10-22 /grill-with-docs 三轮收口)

| # | 决策 | 拍板 |
|---|---|---|
| 1 | 范围 | **六家族全进 v1**(§3.1) |
| 2 | 徽章 | **不进**,维持四槽,不重开徽章配置面(§3.7) |
| 3 | 票组 | **探针票先行 + 八票形状认下**(§4) |
| 4 | 五路功率 | **做整机功耗视图**(Energy Model 一鱼五吃;Vitals 没做深的部分) |
| 5 | 历史落库 | **温度派生值 + GPU 利用率 + 五路功率进 30 天历史(不可见 30s 档);蓝牙/声音/容器不进**(趋势量/状态量之分,见 GLOSSARY) |
| 6 | 声音每 App 层 | **探针(01 票)绿则进输出音量;输入电平/麦克风权限缓** |
| 7 | 容器资源 | **30s 单发 stats 快照(stream=false),流式常开否决** |
| 8 | 电池功率 | **04 SMC 票顺手换 SMC PPBR/PDTR,读不到回退 V×A** |
| 9 | 主窗口 IA | **新开四页:GPU / 传感器 / 外设 / 容器 → 11 tab**;主窗口最小宽度上调(~900)或 pill 微收窄,随 02 GPU 票落地 |
| 10 | 弹窗 | **五族全进弹窗组(全组展示原则延续),组内紧凑形态**(温度组=派生值置顶+明细折叠) |
| 11 | 节奏矩阵 | **§2 各家族 cadence+门控提案定稿**:GPU/功率/温度=可见 5s / 不可见 30s 历史档;声音=事件驱动;蓝牙/容器=可见 30s / 不可见停;差分 Δt 用实测时间戳;唤醒丢首轮 |

新 GLOSSARY 词条已落:五路功率 / 派生传感器 / 传感器命名表 / 趋势量。
下一步:用户敲 `/to-spec`(输入=本文档 §2 家族口径 + §6 拍板)→ `/to-tickets` 出八票。

**修订(2026-10-22 spec 阶段,用户)**:声音降级为非重点——每 App 音量层整体出 v1(推翻 §6 拍板 6),声音只做系统层纯展示(设备/音量/静音,事件驱动);01 探针票裁撤 CoreAudio tap demo 项。若未来做每 App 音量,参考 BackgroundMusic(GPLv2+,**只取点子不碰代码**,同 mole 待遇):其虚拟声卡驱动劫持默认输出的路线与监视器定位不符,读侧公开进程 tap API 才是合适方向。
