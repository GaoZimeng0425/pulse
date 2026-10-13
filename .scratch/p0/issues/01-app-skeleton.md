# 01: 工程骨架跑起来

**What to build:** Pulse 作为一个真菜单栏应用首次运行:Xcode SwiftUI App 项目(macOS 26,bundle id `com.gaozimeng.pulse`),`LSUIElement` 隐藏 Dock 图标,不开 App Sandbox(ADR-0002)。菜单栏出现 Pulse 图标与一个硬编码的假"42%"数字,点击弹出窗口显示静态假数据的三张组卡,证明"菜单栏→弹窗"这条 UI 骨架通、中文文案就位。工程含可运行的测试 target(一条断言 1+1 的占位测试)。

**Blocked by:** 无(可立即开工)。

**Status:** ready-for-agent

- [x] App 启动后不出现在 Dock,仅菜单栏可见
- [x] 菜单栏显示假 CPU 数字,点击弹出窗口
- [x] 弹窗显示 ≥3 张静态组卡(假数据),文案中文
- [x] 工程无 App Sandbox 能力勾选;本地运行无需任何权限弹窗
- [x] 测试 target 存在且 `xcodebuild test` 通过
- [x] P0 零第三方依赖,仅系统框架

## Comments
