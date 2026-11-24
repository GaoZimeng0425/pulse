# arch-clean/06 功能层不再引用 Live 层类型名(门禁收紧到「任何引用」)

Status: ready-for-agent
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

- [ ] 功能层不引用任何 `Pulse/Live` 声明的类型名;门禁按「引用」口径通过
- [ ] `sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票(arch-clean/02 收尾时盘点出的剩余引用)。
