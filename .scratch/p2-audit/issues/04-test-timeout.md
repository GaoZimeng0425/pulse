# 04: 单测默认超时——把"挂死 30 分钟"熔断成"60 秒失败"

**What to build:** 2026-10-22 假 AsyncStream 忘 `finish()` 把宿主测试挂死 ~30 分钟才被人工发现(该坑在 agent 记忆里存在但记忆按相关性召回、不保证在写代码那一刻在场——机器面才可靠)。Xcode test plan 支持 default timeout,仓库现未接线:加 .xctestplan(默认单测超时 60s)挂进 Pulse scheme,xcodegen 可声明,验证 scripts/check.sh|test.sh 管线兼容(注意 hosted tests 与 Swift Testing 混跑口径,仓库纯 XCTest)。挂死从"静默等待"变"红色失败"。

**Blocked by:** None

**Status:** needs-triage

- [ ] 超时生效验证:人为写一个 sleep(120) 的用例在 60s 被判失败后删除
- [ ] 既有 745 例无超时误伤(全绿)
- [ ] check.sh 全绿
