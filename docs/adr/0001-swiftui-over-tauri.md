# 用 SwiftUI MenuBarExtra,不用 Tauri 2

技术方案(vitals-clone-tech-design.md §7)原本推荐 Tauri 2 + Rust + React,理由是 UI 开发速度;SwiftUI 列为备选。我们选定 SwiftUI:Darwin 采集 API(proc_pidinfo / sysctl)零 FFI 直接调、常驻内存 <30MB(WebView 约 50–100MB)、Swift Charts 与系统通知原生可用。产品真正的壁垒是三层归组引擎,与栈无关;UI 规模(卡片+列表+下钻)在 SwiftUI 属常规工作量。关键 API 已在本机探针验证(docs/probe.swift)。

## Considered Options

- Tauri 2 + Rust + React:UI 迭代快,但多一层 FFI 桥、WebView 常驻开销、双工具链。
- 纯 Swift + SwiftUI:选定。代价:UI 手写速度较慢。
