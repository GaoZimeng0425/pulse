# arch-clean/06 功能层不再引用 Live 层类型名(门禁收紧到「任何引用」)

Status: done
Type: task
Blocked by: —(05 已完成)

## 背景

01 / 02 之后,功能层已不再**构造** Live 类型,但仍有几处**引用** Live 层的类型名(用作属性类型、
参数类型或调静态方法)。它们多是纯数据 / 纯格式化,却和需要系统框架的代码写在同一文件里:

- `AlertNotificationContent` / `AlertNotificationPayload` / `NotificationAuthorization`
  (`Pulse/Live/AlertNotification.swift`,同文件 import UserNotifications / AppKit)——`AlertCenter` 用;
- `AppVolumeScan`(`Pulse/Live/LiveAppVolumeEngine.swift`,同文件 import CoreAudio)——`AppVolumeFeature` 用;
- `BluetoothAuthorization`(`Pulse/Live/BluetoothSensor.swift`,同文件 import CoreBluetooth)——`BluetoothFeature` 用;
- `LaunchdManifestProvider`——`LaunchdManifestFeature` 的注入参数是具体 Live 类型(与 05 同族,05 一并处理)。

## 要做

1. 逐个拆文件:不碰系统框架的类型挪 PulseCore(或功能层);真依赖框架的部分留 Live,功能层改依赖协议。
2. `scripts/check-layers.sh` 收紧:功能层出现任何 Live 层类型名即报错(不止构造),视图层同理评估。
3. 每个类型单独评估,遇到挪不动的(真绑框架类型)记理由,不硬挪。

## 验收

- [x] 功能层不引用任何 `Pulse/Live` 声明的类型名;门禁按「引用」口径通过
- [x] `sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票(arch-clean/02 收尾时盘点出的剩余引用)。
- 2026-11-24 完成。门禁收集口径加 protocol / typealias,匹配从 `类型名(` 改成任何词边界引用(注释不算),功能层与**视图层**同口径,豁免 0 条;变异验证(功能层写 Live 类型做属性类型、视图层引用 Live 里的 typealias)均报红。逐个处理:
  - 告警:`NotificationAuthorization`(UN 原值映射留 Live 作 extension)/ `AlertNotificationSending` / `AlertNotificationPayload` / `AlertNotificationContent` → PulseCore `AlertNotificationPort.swift`;`NemoNotchToastSending` → PulseCore `NemoNotchToast.swift`。
  - 系统通知设置深链:视图不再调 `SystemNotificationSettings.open()`,改 `AlertCenter.openSystemNotificationSettings()` → 发送缝新增 `openSystemSettings()`(Live 实现调 NSWorkspace)。
  - 点通知路由:落点状态 + 开窗广播拆成功能层 `MainWindowLanding`(无 AppKit / UN);`AlertNotificationRouter` 只剩 UN delegate + 激活 app,持有 landing。视图 / 菜单栏控制器只认 landing。
  - 音量:`AppVolumeScan` 与两个引擎协议 → PulseCore `AppVolumeModel.swift`(`AudioObjectID` 写成同义的 `UInt32`)。
  - 蓝牙:`BluetoothAuthorization` / `BluetoothAccessControl` → PulseCore `BluetoothAccess.swift`。
  - `LaunchdManifestProvider` → PulseCore(同 05 口径:去掉 Live 源默认值,组装点传 `LiveLaunchdPlistSource()`;日志改 CoreLog)。
  - `BundleDisplayNameReader`(只用 Foundation 读 Info.plist)→ PulseCore,视图照用。
  - 没有挪不动的类型。
