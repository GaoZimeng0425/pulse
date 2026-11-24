# arch-clean:app 内分层收口(极简口径)

## 背景

2026-11-24 架构审查(`.scratch/arch-review-2026-11-24/`)逐票核实后,用户要求按「架构极简、
代码整洁」的角度重看分层与 SOLID。结论:

- 骨架是对的,是端口与适配器:PulseCore 定义接口、`Pulse/Live` 实现、`Pulse/App` 组装;
  Core ↔ app 的边界有编译器守门,功能模块互不引用,接口只为测试注入而建(ADR-0003)。
- 不干净的是 app 内四个目录之间的边界:**只有约定、没有机制**,且已被打破——
  功能层 / 视图层里有 14 处直接构造 Live 具体实现,组装点有三处
  (`MonitorAssembly`、`MainWindowView.init`、`PulseApp.init`)。
- 违反最明显的 SOLID 条目:依赖倒置(app 内)、接口隔离(9 个视图拿整个 `SystemMonitor`)、
  单一职责(`CleanerModel` / `SystemMonitor` / `MainWindowView`)。

## 原则(本组票的取舍口径)

- **只删和挪,不加层、不加抽象**。符合 SOLID 字面但让代码变多的做法不做:每视图专属投影接口、
  拆 PulseCore 为多包、为单实现补接口、IPC 全面 actor 化。
- **约定变机制**:能用 lint / 编译器拦的边界,就不靠评审记。
- 每票纯重构,行为逐位不变,`sh scripts/check.sh` 全绿为闸。

## 票

| 票 | 内容 | 取代 |
|---|---|---|
| 01 | 唯一组装点 + ast-grep 规则拦截越界构造 | arch-review-2026-11-24/05 |
| 02 | 纯规则与纯数据类型从 Live 挪回 Core | arch-review-2026-11-24/10 |
| 03 | 视图按类型取模块,删 SystemMonitor 转发属性 | arch-review-2026-11-24/06(收窄) |
| 04 | 纯核心测试挪回包内 `swift test` | arch-review-2026-11-24/08 |
| 05 | 传感器适配器由组装点注入(01 落地时发现) | — |

`CleanerModel` 拆分不另开票:已有 `solid-split/02`(2026-11-22 实读定谳——扫描编排与缓存装载
编织十几处私有状态,须先做状态分组设计,复活条件是清理域下次功能票触及或用户点名)。

建议顺序:01 → 02 → 05 → 04 → 03。
