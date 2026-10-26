// swift-tools-version: 6.0
import PackageDescription

// PulseMCP(p3-root-mcp/02):Pulse 的 MCP stdio server。
// 独立 SPM 包不进 app 构建图(app 不引 swift-sdk 依赖);可执行全静态
// (PulseCoreStatic),单一产物零 dylib 随行,由 scripts/build.sh 拷进
// Pulse.app/Contents/MacOS/ 随 app 分发。
let package = Package(
    name: "PulseMCP",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../PulseCore"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    ],
    targets: [
        .executableTarget(
            name: "pulse-mcp",
            dependencies: [
                .product(name: "PulseCoreStatic", package: "PulseCore"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
