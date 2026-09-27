// swift-tools-version:5.8
import PackageDescription

// 三个 target：
//   yaCore   —— 全部业务逻辑（library，才能被单元测试 import）
//   ya       —— 只剩一个 main.swift 的可执行文件
//   yaTests  —— XCTest
//
// 为什么不直接测可执行文件：Swift 里 executable target 不能被 `import`，
// 想跑 XCTest 就必须把逻辑放进 library。main.swift 留在 Sources/yaApp 里，
// 只负责 `import yaCore` 后启动 NSApplication。
let package = Package(
    name: "ya",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "yaCore",
            path: "Sources/ya",
            resources: [.copy("Web")]
        ),
        .executableTarget(
            name: "ya",
            dependencies: ["yaCore"],
            path: "Sources/yaApp"
        ),
        .testTarget(
            name: "yaTests",
            dependencies: ["yaCore"],
            path: "Tests/yaTests"
        ),
    ]
)
