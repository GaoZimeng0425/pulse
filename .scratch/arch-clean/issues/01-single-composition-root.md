# arch-clean/01 唯一组装点 + 越界构造拦截

Status: ready-for-agent
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

- [ ] ast-grep 规则在旧代码上报出全部越界位置,改完后归零
- [ ] `Pulse/Views/`、`Pulse/Features/` 中无 Live 构造;组装点只在 `Pulse/App`
- [ ] 行为不变:清理页扫描 / 缓存落盘 / 卸载 / MCP 清理照常;`sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票(用户拍板按极简口径整理分层,取代 arch-review-2026-11-24/05)。
