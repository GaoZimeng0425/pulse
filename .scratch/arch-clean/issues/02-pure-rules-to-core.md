# arch-clean/02 纯规则与纯数据类型挪回 Core

Status: done
Type: task
Blocked by: 01

## 背景

有几样东西不碰系统调用,却住在 `Pulse/Live`,导致功能层不得不引用 Live 类型,也进不了 `swift test`:

- `LiveCleanDirectoryEnumerator.isUserDomain(_:)`(`Pulse/Live/LiveCleanDirectoryEnumerator.swift:100`):
  纯路径前缀判断,决定「哪些路径的权限错误要提示用户」,是领域规则;`CleanerModel.swift:408` 直接调用;
- `LiveAppCatalogFacts`(`Pulse/Live/LiveAppCatalogSource.swift:19`):纯值 struct,`UninstallModel` 的参数类型;
- `CleanActivityBoard`(`Pulse/Live/LiveCleanActivitySource.swift:12`):不带 IO 的锁盒子。

核实记录见 `.scratch/arch-review-2026-11-24/issues/10`(原票说「注入假枚举器覆盖不到」不成立——
纯函数没有漏测问题;真实代价只是进不了包内测试 + 功能层引用 Live 类型)。

## 要做

1. `isUserDomain` 挪到 PulseCore 成纯函数(如 `CleanPathDomain.isUserDomain`),补正反例测试;Live 枚举器改调它。
2. `LiveAppCatalogFacts` 去掉 Live 前缀挪到 PulseCore;`UninstallModel` 不再引用 Live 类型。
3. 预览里构造的放错目录件(arch-clean/01 门禁豁免清单第二组):`HostInfo`(纯数据)挪 PulseCore;
   `InertNemoNotchToastSender` 挪 `Pulse/App/InertSources.swift`;删清单对应 4 行。
4. `UninstallModel` 补一条带假 `CleanActivityBoard` 的「应用正在运行」测试(现三处测试都传 nil,该分支没测到)。
   不为它新开 Core 接口。

## 验收

- [x] `Pulse/Features/` 不再引用任何 `Live*` 类型名
- [x] 挪过去的规则有包内测试;新增运行中分支测试
- [x] `sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票,取代 arch-review-2026-11-24/10(收窄:不新开活动数据接口)。
- 2026-11-24 落地:`CleanPathDomain.isUserDomain`、`AppCatalogFacts`(去 Live 前缀)、`CleanActivityBoard`、
  `HostInfo`(数据类型;sysctl 读取留 Live 作扩展)挪入 PulseCore;`InertNemoNotchToastSender` 挪
  `Pulse/App/InertSources.swift`;门禁豁免清单删 4 行(14 → 10)。新增测试:用户域判定 2 例(包内);
  卸载「运行中」两道关各 1 例——实施时发现列清单时已有一道(灰行不受理),执行前重查是第二道,
  此前两道都无覆盖。
  验收第一条按「Live 前缀」口径达成;不带前缀的剩余引用(通知内容 / 音量扫描 / 蓝牙授权等,与系统
  框架代码同文件)盘点后另开 arch-clean/06,未在本票扩张。
