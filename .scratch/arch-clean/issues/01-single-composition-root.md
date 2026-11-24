# arch-clean/01 唯一组装点 + 越界构造拦截

Status: done
Type: task

## 背景

ADR-0003 补记 06 约定「视图只读功能模块状态、不直调 Live 层」,但只靠评审守。现状(develop @ 3b85930):

- `Pulse/Views/MainWindowView.swift:59-95` 在视图 init 里构造 `CleanerModel` / `UninstallModel`,
  直接 new `LiveCleanTrashExecutor`、`LiveCleanActivitySource`、`LiveCleanVolumeSummaries`、
  `LiveCleanPermanentDeleter`,还在闭包里写落库逻辑;
- `Pulse/App/PulseApp.swift:97-108` 给 MCP 影子模型再组装一份 `CleanerModel`(今天两份参数逐个同源,无现存 bug);
- 功能层用默认参数构造 Live:`UninstallModel.swift:82-111`(6 处)、`CleanerModel.swift:189,192,453`、
  `BluetoothFeature.swift:72`。

核实记录见 `.scratch/arch-review-2026-11-24/issues/05`(原票「已因两份装配出过事故」与 git 历史不符:
scanCache 漏传修于 8ceff7c,早于影子模型 6d3b4ae)。

## 要做

1. 清理 / 卸载的组装收进 `Pulse/App`(并入 `MonitorAssembly` 或同目录新文件),窗口模型与 MCP 影子模型
   从同一处取依赖;`MainWindowView.init` 只剩赋值。
2. 功能层构造函数去掉构造 Live 的默认参数,改由组装点显式传入;测试本来就传替身,调用点随之更新。
3. 新增 ast-grep 规则 `.ast-grep/no-live-outside-app.yml`(error 级):`Pulse/Views/`、`Pulse/Features/` 下
   出现 `Live*` 类型的构造调用即报错;注释里提到不算。lint.sh 已自动扫描 `.ast-grep/`。
4. 规则先在改动前跑一次,确认能报出上面全部位置(反证),再做 1–2 让它归零。

## 不做

- 不改 `CleanerModel` 内部结构(见 `solid-split/02`);
- 不动 `PulseApp` 启动编排(arch-review-2026-11-24/09 已判暂缓)。

## 验收

- [x] ast-grep 规则在旧代码上报出全部越界位置,改完后归零
- [x] `Pulse/Views/`、`Pulse/Features/` 中无 Live 构造;组装点只在 `Pulse/App`
- [x] 行为不变:清理页扫描 / 缓存落盘 / 卸载 / MCP 清理照常;`sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票(用户拍板按极简口径整理分层,取代 arch-review-2026-11-24/05)。
- 2026-11-24 落地。实施偏差:
  ①门禁不用 ast-grep 规则,改 `scripts/check-layers.sh`——按 `Pulse/Live` 里**声明的类型**判定
  (79 个类型中 44 个不带 Live 前缀,按前缀会漏 `EnergyHelperClient`、`GattBatteryProbe` 等),
  接入 lint.sh;存量用只许变短的豁免清单 `scripts/layer-baseline.txt`。反证:在改动前的 develop 上
  跑,报出本票清掉的 12 处。
  ②范围比票面广:除清理/卸载外,`EnergyImpactFeature` 拉取、`BluetoothFeature` 授权与 GATT 探针
  的 Live 默认也收进组装点;`CleanerModel` 的目录枚举器改为构造注入(`startScan(using:)` 保留给测试单次覆盖)。
  ③顺带消除一个隐患:`UninstallModel.brewUninstall` 曾默认 Live,而测试 `makeModel()` 把 Bitwarden
  标成 brew 应用又没传它——任何走执行路径的新测试都会在本机真跑 `brew uninstall`。去默认后编译器当场报出。
  ④`CleanerModel` 测试 44 处改走 `CleanerModel.testing(...)`(同名同序参数,原 Live 默认的三个 IO
  参数默认给惰性替身),测试不再读本机真 /Applications、真废纸篓。
  ⑤门禁存量 14 条:传感器适配器 10 条另开 arch-clean/05;预览件 4 条并入 arch-clean/02。
