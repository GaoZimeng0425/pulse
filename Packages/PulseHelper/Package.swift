// swift-tools-version: 6.0
import PackageDescription

// PulseHelper(p3-root-mcp/03):Pulse 的特权助手 daemon。
// 纯系统框架(零第三方依赖):60s 循环 powermetrics 单发采 per-process
// Energy Impact,XPC 拉模式供 app 查询(app 不在跑 = 不拉 = 丢弃,空段诚实)。
// 解析/采集进库 target(单测);executable 只留 XPC 服务与对端校验。
// scripts/build.sh 拷进 Pulse.app/Contents/Library/LaunchDaemons/ 随 app 签名。
let package = Package(
    name: "PulseHelper",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "PulseHelperCore"),
        .executableTarget(
            name: "pulse-helper",
            dependencies: ["PulseHelperCore"]
        ),
        .testTarget(name: "PulseHelperCoreTests", dependencies: ["PulseHelperCore"]),
    ]
)
