# 05: 纯逻辑层抽本地 SPM 包 PulseCore

**What to build:** 把只依赖 Foundation / GRDB 的纯逻辑(归组引擎、CPU/tick/网络差分、告警引擎、历史卷积与查询、排行账本、格式化等)从 app target 移进本地 Swift Package `PulseCore`;app target 只留 Live 适配器(Darwin / IOKit / 子进程)与 SwiftUI。

**Status:** ready-for-agent

**Blocked by:** 01(高1 拆 SystemMonitor 时顺手按新形状移文件,避免移两遍)

背景(2026-10-19 架构讨论,用户拍板立票):

- 70 个文件平铺在单一 target,分层全靠自觉——ADR-0003 写的「每个服务以独立 Swift 模块组织」实际是同模块文件、全部 internal 互见;现在视图层基本不直调 Darwin/Live 源,但编译器不守门
- 单测托管在 app 内(TEST_HOST):`0c892c1` 前宿主走完整装配读写生产历史库;现靠 @main 空壳入口规避,根治是核心测试不需要宿主

范围:

- [ ] `project.yml` 加本地 package 依赖;`xcodegen generate`(绝不手改 pbxproj)
- [ ] 按「只 import Foundation/GRDB、不碰 AppKit/SwiftUI/Darwin 采集调用」为准入线移文件;需要 `public` 的面最小化
- [ ] 核心测试移到 package 测试 target,`swift test` 不起宿主可跑;Live 冒烟与 SwiftUI 相关测试留在 PulseTests
- [ ] `scripts/test.sh` / `check.sh` / pre-commit 闸门覆盖两套测试
- [ ] ADR-0003 补记:「模块」从此指 SPM 模块边界

约束与验收:

- 运行期行为零变化;`sh scripts/test.sh` 全绿且用例总数不减
- ripwire 查影响面、ast-grep 做机械改写(AGENTS.md 工具策略)
