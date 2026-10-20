// swift-tools-version: 6.0
import PackageDescription

// PulseCore:Pulse 的纯逻辑层(arch-review-2026-10-18/05)。准入线 = 只依赖 Foundation / GRDB,
// 不碰 AppKit / SwiftUI / Darwin 采集调用;Live 适配器(Darwin / IOKit / 子进程)与 SwiftUI
// 留在 app target。`swift test` 不起 app 宿主即可跑核心测试。
let package = Package(
    name: "PulseCore",
    platforms: [.macOS("26.0")],
    // 动态库:app 与宿主内单测共用同一份(静态库会在 app 与测试包里各链一份,同名类型
    // 两套元数据,类型判断对不上即崩);GRDB 只静态链进这一个动态库,经 PulseCore 重新导出。
    products: [.library(name: "PulseCore", type: .dynamic, targets: ["PulseCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(
            name: "PulseCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // 两套测试共用的合成夹具:包内测试按 target 依赖;app 的 PulseTests 由 project.yml
        // 把同一目录的源直接编进测试包(不作产品链接,避免 PulseCore 被静态链第二份)。
        .target(name: "PulseCoreTestSupport", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore", "PulseCoreTestSupport"]),
    ]
)
