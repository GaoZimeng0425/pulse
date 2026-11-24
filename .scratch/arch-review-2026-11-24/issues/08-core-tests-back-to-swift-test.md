# 08: 核心测试归位——主干/写引擎/归组用 swift test 覆盖

**What to build:** 修复 REPORT 中8:ADR-0003 承诺"核心测试不起宿主",但最核心的几套测试外迁到 `PulseTests`,`swift test` 覆盖不到主干与写引擎主路径。

**Status:** wontfix

证据见 `../REPORT.md` §中8:`PulseTests/HistoryEngineTests.swift`(645 行)、`GroupingEngineTests.swift`(891 行)、`RoundSpineTests.swift`(311 行)、`ParentChainQueryTests.swift`(161 行)均无 Pulse/AppKit 依赖;`scripts/test.sh:7-11` 分两套执行。

**Agent Brief:**
1. 逐文件检查依赖:把只 import PulseCore + XCTest(及包内测试夹具)的套件搬到 `Packages/PulseCore/Tests/PulseCoreTests/`,去掉 `@testable import Pulse`;确有宿主依赖的用例留在 `PulseTests`。先 `git status` 确认并行工作区状态。
2. 用 `swift test` 跑搬过去的全部用例,确认断言不依赖宿主环境(真 SQLite 内存库可用,真进程/系统 API 不可);若某用例不能脱离宿主,记录原因并留原位,不要为搬家改测试语义。
3. 加一条 lint/静态检查:"只 import PulseCore + XCTest 的测试文件不得位于 PulseTests"(只做检查,不自动搬文件),并入 `scripts/lint.sh` 或 `scripts/check.sh`。

**验收:** 改 `RoundSpine.advance`/`GroupingEngine.groups`/`HistoryEngine.ingest` 时 `swift test` 就能发现回归;宿主机型挂死不再阻塞核心验证;check.sh 全绿。

## 核实(2026-11-24)

真问题:四文件 import Pulse 但实际不用任何 app 类型,a29daa6 搬迁漏掉。「宿主挂死」理由已由 test-hang-cure/01 解决。**由 arch-clean/04 取代**(去掉 lint 一步)。
