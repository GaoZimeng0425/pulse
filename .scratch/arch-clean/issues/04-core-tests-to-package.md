# arch-clean/04 纯核心测试挪回包内

Status: done
Type: task

## 背景

ADR-0003 补记承诺「核心测试用 `swift test` 跑,不起 app 宿主」,但四组纯核心测试留在宿主测试里:
`PulseTests/HistoryEngineTests.swift`(645 行)、`GroupingEngineTests.swift`(891 行)、
`RoundSpineTests.swift`(311 行)、`ParentChainQueryTests.swift`(161 行)。

核实(2026-11-24):四个文件都写了 `@testable import Pulse`,但逐个比对 app 的 391 个类型名,
实际一个都没用到;a29daa6 搬迁时漏掉,无记录理由。代价:改主干 / 写引擎 / 归组时,
`swift test` 抓不到回归,必须跑 xcodebuild 全量。(原票说的「宿主测试挂死」已由 test-hang-cure/01 解决,不再是理由。)

## 要做

1. 四个文件挪到 `Packages/PulseCore/Tests/PulseCoreTests/`,删 `import Pulse`;若有依赖 PulseTests 辅助符号的,
   一并挪进 `PulseCoreTestSupport` 或测试内联。
2. `swift test` 跑通;用例数与挪前一致(核心包 + app 总数不变)。
3. 不加「禁止纯核心测试放 PulseTests」的 lint(收益不抵复杂度)。

## 验收

- [x] 四组测试在 `swift test` 下全绿,app 侧对应减少,总数不变
- [x] `sh scripts/check.sh` 全绿

## Comments

- 2026-11-24 立票,取代 arch-review-2026-11-24/08(去掉 lint 一步)。
- 2026-11-25 完成:四文件 git mv 进 PulseCoreTests,只删 `@testable import Pulse` 一行,零辅助符号依赖、零代码改动。68 个用例挪入;核心包 906→974,app 547→479,check.sh 总数 1457 不变。
