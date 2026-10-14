// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "asc-mcp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "asc-mcp", targets: ["asc-mcp"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0")
    ],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
        .executableTarget(
            name: "asc-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [
                .copy("Resources/OperationManifest")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ASCMCPTests",
            dependencies: [
                "asc-mcp",
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
