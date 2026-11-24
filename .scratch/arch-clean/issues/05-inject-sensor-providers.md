# arch-clean/05 传感器适配器由组装点注入

Status: ready-for-agent
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

- [ ] 豁免清单第一组清空,`sh scripts/check-layers.sh` 通过
- [ ] 各传感器卡片读数照常;`sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票(arch-clean/01 落地门禁时发现,存量 10 处入豁免清单)。
