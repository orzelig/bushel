// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "bushel",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-format.git", branch: ("release/5.10")),
        .package(url: "https://github.com/apple/swift-atomics.git", .upToNextMajor(from: "1.2.0")),
        .package(url: "https://github.com/mhdhejazi/Dynamic", branch: "master"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0")
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib"
        ),
        .executableTarget(
            name: "bushel",
            dependencies: [
                "CZlib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Dynamic", package: "Dynamic"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ],
            path: "src",
            exclude: ["Bar"],
            resources: [
                .copy("Resources/unattended-presets"),
                .copy("Resources/dashboard.html"),
                .copy("Resources/novnc")
            ]),
        .executableTarget(
            name: "bushel-bar",
            dependencies: [],
            path: "src/Bar"
        ),
        .testTarget(
            name: "bushelTests",
            dependencies: [
                "bushel",
                // EmbeddedChannel + WebSocketFrame are used to unit-test
                // NoVNCBridge.wireBridge without spinning up a real socket.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                // For pattern-matching CallTool.Result.content in tests.
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "tests")
    ]
)
