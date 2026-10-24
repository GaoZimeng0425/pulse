# 06: 蓝牙设备表——三源电量合并

**What to build:** 蓝牙三源合并打穿:① IORegistry 的 Apple HID 事件服务(Apple 外设)② 蓝牙偏好缓存(免权限;缓存电量 1 当 100 解释)③ CoreBluetooth GATT 电池服务(按需连接,01 票已验证);IOBluetooth 设备列表供已配对/连接态与 RSSI(127=未知)。合并规则 = 地址规整(统一分隔小写)→ 唯一名称 → 厂商/产品 ID 三级匹配,歧义即弃,核心包纯值模型承载合并逻辑;外设页加蓝牙区(设备表:名称/连接态/电量/RSSI),弹窗蓝牙紧凑组(设备电量行)。可见 30s 节奏(组/页可见才扫),睡眠停扫/唤醒重启;GATT 只在需要读某设备时建连。system_profiler/pmset 兜底源不做。

**Blocked by:** 01(GATT 验证)、05(外设页在场)

**Status:** done

- [x] 三源合并单测:地址规整、三级匹配、歧义即弃、缓存电量 1→100(13 例)
- [x] 组/页不可见时零扫描(gate 关 = 一个源都不碰,provider 单测钉死);睡眠停扫
  天然成立(进程随睡眠挂起,30s tick 不跑),唤醒后下一可见 tick 自动重启
- [x] check.sh 全绿(719 例:核心 384 + app 335);关两窗指纹全零
- [ ] 外设页蓝牙区列出本机真实设备(妙控板/QC35 等 6 台),Apple 外设电量直读成功 —— **待用户目验**
- [ ] 弹窗蓝牙紧凑组出现 —— **待用户目验**

## Comments

**执行记录(2026-10-22 晚)**:
- 核心包 `BluetoothModel`:三源原始条目(HID/缓存/GATT)+ 配对锚
  (PairedDeviceStatus)+ `BluetoothMerge` 纯值合并器——锚按规整地址去重
  (实探小米平板在 pairedDevices() 出现两次)、三级匹配(规整地址 → 唯一名 →
  唯一厂商/产品 ID)歧义即弃、缓存电量 1 当 100 解、RSSI 哨兵(0/127)归
  未知、hid > cache > gatt 优先级、挂不上锚的样本单独成行。13 例单测。
- Live `BluetoothSensor`:LiveBluetoothSource(IOBluetooth 锚 + IORegistry HID
  电量 [实探妙控板 41% 开箱即用] + 系统 plist DeviceCache [本机 macOS 26 无
  该键 = 空态常态])+ GattBatteryProbe(有界扫描 12s/连接 8s,名字命中才建连,
  读完即断;探针交付进缓冲**下一轮**收账)+ BluetoothSensorProvider(30s 档,
  不可见一个源都不碰)。
- IOBluetooth 的 vendorID/productID 选择子原语返回在 Swift 侧不可见——锚侧
  ID 置 nil,级③匹配留给合成载荷单测(单测覆盖,Live 走级①②)。
- BluetoothDevicesCardView(名称/连接点/电量 meter/RSSI,已连接置顶);
  InertBluetoothSource 预览源(三台设备含电量未知形态)。
- **真崩溃隐患修复**:IOBluetooth 首访触发 TCC 隐私检查,app Info.plist 缺
  `NSBluetoothAlwaysUsageDescription` 即被系统杀(测试宿主崩溃 .ips 实证);
  project.yml 补键。无此修复合并后正式 app 打开外设页当场崩。

**睡眠停扫口径**:不做显式 NSWorkspace 睡眠监听——进程随睡眠挂起,tick 天然
停;唤醒后下一个可见 tick 自动扫描。与 stats 的显式停扫(paused API 复杂度)
效果等价,记档备查。

**待用户目验**:
- 外设页蓝牙区:6 台真实设备、妙控板电量直读(IORegistry 44%±,随电量走)、
  已连接两台置顶(妙控板 + Hack59-2 键盘)。
- GATT 路真机验证:QC35/MOONDROP 在场且可连时 30s 内出电量;不在场安静
  显示"电量未知"。
- 弹窗(外设 tab 紧凑档)同形状(前 6 台)。

## Comments(2026-10-24 补记:权限原则纠偏——默认关 + 用户动作处才弹)

用户目验反馈「一直提示蓝牙连接,不符合权限原则」(原则出处 NemoNotch AGENTS.md /
experience-playbook:「只有用户真正需要并且触发了,才弹」)。本票上线时闸只看可见性
(弹窗 ∨ 外设页)——点开菜单栏就碰 IOBluetooth/CoreBluetooth,且 ad-hoc 签名每次
build.sh 装机换 cdhash、TCC 视为陌生 app 重新弹窗,双因叠加成"一直提示"。

纠偏(NemoNotch 2026-10-17 同方案):蓝牙监控**默认关**(settings.bluetoothEnabled
持久),设置页「外设」开关 + 蓝牙卡按钮是唯一触发源;采集闸 = 可见 ∧ 已开启 ∧ 系统已
授权;静默预检走 CBCentralManager.authorization 类属性(不初始化协调器、不弹窗),
启动 / 进场 / 回前台只静默读;被拒只给系统设置深链(Privacy_Bluetooth),绝不自动重试。
重装后开关仍开而授权未决 → 卡片显示「授权蓝牙」按钮等用户点,启动路径零弹窗。
8 例 BluetoothFeatureAccessTests 钉死四条路径;原则全文落 CODING_STANDARDS.md
「权限 / TCC 纪律」。遗留:ad-hoc 签名问题待稳定自签身份(NemoNotch
make-signing-cert.sh 方案)解决——落地前每次重装后需重新点一次授权。
