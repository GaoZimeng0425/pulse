# 05: 纯逻辑层抽本地 SPM 包 PulseCore

**What to build:** 把只依赖 Foundation / GRDB 的纯逻辑(归组引擎、CPU/tick/网络差分、告警引擎、历史卷积与查询、排行账本、格式化等)从 app target 移进本地 Swift Package `PulseCore`;app target 只留 Live 适配器(Darwin / IOKit / 子进程)与 SwiftUI。

**Status:** done

**Blocked by:** ~~01~~(已解除;高1 拆 SystemMonitor 时顺手按新形状移文件,避免移两遍)

背景(2026-10-19 架构讨论,用户拍板立票):

- 70 个文件平铺在单一 target,分层全靠自觉——ADR-0003 写的「每个服务以独立 Swift 模块组织」实际是同模块文件、全部 internal 互见;现在视图层基本不直调 Darwin/Live 源,但编译器不守门
- 单测托管在 app 内(TEST_HOST):`0c892c1` 前宿主走完整装配读写生产历史库;现靠 @main 空壳入口规避,根治是核心测试不需要宿主

范围:

- [x] `project.yml` 加本地 package 依赖;`xcodegen generate`(绝不手改 pbxproj)
- [x] 按「只 import Foundation/GRDB、不碰 AppKit/SwiftUI/Darwin 采集调用」为准入线移文件;需要 `public` 的面最小化
- [x] 核心测试移到 package 测试 target,`swift test` 不起宿主可跑;Live 冒烟与 SwiftUI 相关测试留在 PulseTests
- [x] `scripts/test.sh` / `check.sh` / pre-commit 闸门覆盖两套测试
- [x] ADR-0003 补记:「模块」从此指 SPM 模块边界

约束与验收:

- 运行期行为零变化;`sh scripts/test.sh` 全绿且用例总数不减
- ripwire 查影响面、ast-grep 做机械改写(AGENTS.md 工具策略)

## Comments

- 2026-10-20 落地(分支 feat/pulsecore):
  - 37 个纯逻辑文件进包;八个混合文件(磁盘 / 网络 / 电池 / nettop / 每核 tick / 内存 / dev server / 结束进程 / 出生扫描)按顶层声明拆开,Live 适配器留 app。`Metric` 枚举与色值令牌进包,`accentColor`(SwiftUI Color)留 app;`MeterNormalization` 进包。
  - 核心层日志经 `CoreLog` 出口,app 启动时(LogService 初始化)接到 LogService;测试宿主与 `swift test` 下静默。
  - PulseCore 为**动态库**:静态库会在 app 与宿主内测试包里各链一份,同名类型两套元数据,测试进程实测崩溃;GRDB 只静态链在 PulseCore 里。不重新导出 GRDB(GRDB 的 `Configuration` 与 SwiftUI 样式的 `Configuration` 撞名)。
  - 采样器 / 出生扫描去掉 Live 默认参数;采样器单测改注入合成内存 / 网络源(此前经 Live 默认值读本机真实计数)。
  - 测试:核心包 28 个文件 222 例(`swift test` 0.24s,不起宿主),app 侧 376 例;合计 598 例,与迁移前一致。
  - **偏离票面**:「public 面最小化」没做到——跨模块时 internal 类型对 app 直接不可见、编译器不给声明位置,逐项开放不可行,改为脚本给包内全部非私有声明加 `public` 并补公开逐成员初始化方法。收窄可作后续小票(按 app 实际引用反查,去掉不需要的 public)。
