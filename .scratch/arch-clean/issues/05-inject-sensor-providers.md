# arch-clean/05 传感器适配器由组装点注入

Status: done
Type: task
Blocked by: 01

## 背景

arch-clean/01 落地分层门禁时发现:9 个功能模块在自己 init 里构造传感器适配器
(`BatterySensorProvider(source:)`、`DiskCapacityProvider(source:)` 等 10 处,见
`scripts/layer-baseline.txt` 第一组)。适配器住在 `Pulse/Live`,且部分默认参数还会建
系统事件监听(如 `BatterySensorProvider` 默认 `IOPSWakeupStream.make()`)——功能模块
借构造参数间接拿到了 Live 实现。这是 ADR-0003 早期的统一写法,不是个别疏漏。

## 要做

1. 功能模块 init 改为接收适配器(或 `SensorProvider` 协议值),不再接收裸 source 再自己包;
   `MonitorAssembly.live` 与 `InertSources` 负责构造。
2. 适配器去掉构造系统监听的默认参数,由组装点显式传入。
3. 从 `scripts/layer-baseline.txt` 删掉第一组 10 行(检查会逼着删)。
4. `LaunchdManifestFeature` 的注入参数是具体类型 `LaunchdManifestProvider`(Live),一并改为协议(06 盘点出的同族项)。

## 验收

- [x] 豁免清单第一组清空,`sh scripts/check-layers.sh` 通过
- [x] 各传感器卡片读数照常;`sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票(arch-clean/01 落地门禁时发现,存量 10 处入豁免清单)。
- 2026-11-24 落地,**改法偏离票面(更彻底)**:没有把适配器改成由组装点构造后注入,而是发现 10 个适配器
  本身都是纯包装(只套注入的数据源 + Core 已有的闸门/累加器),碰 Live 的只有默认参数——于是整段挪进
  PulseCore 各自的模型文件(连同蓝牙用的 `GattBatteryBuffer` / `GattBatteryProbing`),去掉构造 Live 源
  与系统监听的默认参数。功能模块照旧自己包适配器,但包的已是 Core 类型,分层上不再越界;
  电池 / 声音的系统事件唤醒流改由组装点传入。豁免清单 10 → 0。
  顺带:惰性装配(预览 / 测试宿主)的电池模块原先默认会挂真 IOPS 电源通知,现在传 nil,不再碰系统。
  未做:`LaunchdManifestProvider` 内部用 app 的 LogService,挪不进 Core,留给 06。
