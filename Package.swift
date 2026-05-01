// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmallChat",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SmallChatCore", targets: ["SmallChatCore"]),
        .library(name: "SmallChatRuntime", targets: ["SmallChatRuntime"]),
        .library(name: "SmallChatCompiler", targets: ["SmallChatCompiler"]),
        .library(name: "SmallChatEmbedding", targets: ["SmallChatEmbedding"]),
        .library(name: "SmallChatTransport", targets: ["SmallChatTransport"]),
        .library(name: "SmallChatMCP", targets: ["SmallChatMCP"]),
        .library(name: "SmallChatChannel", targets: ["SmallChatChannel"]),
        .library(name: "SmallChatDream", targets: ["SmallChatDream"]),
        .library(name: "SmallChatShorthand", targets: ["SmallChatShorthand"]),
        .library(name: "SmallChatImportance", targets: ["SmallChatImportance"]),
        .library(name: "SmallChatCRDT", targets: ["SmallChatCRDT"]),
        .library(name: "SmallChatCompaction", targets: ["SmallChatCompaction"]),
        .library(name: "SmallChatMemex", targets: ["SmallChatMemex"]),
        .library(name: "SmallChat", targets: ["SmallChat"]),
        .executable(name: "smallchat", targets: ["SmallChatCLI"]),
        .executable(name: "SmallChatApp", targets: ["SmallChatApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
    ],
    targets: [
        // ---- Core ----
        .target(
            name: "SmallChatCore",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        // ---- Runtime ----
        .target(
            name: "SmallChatRuntime",
            dependencies: ["SmallChatCore"]
        ),
        // ---- Compiler ----
        .target(
            name: "SmallChatCompiler",
            dependencies: ["SmallChatCore"]
        ),
        // ---- Embedding ----
        .target(
            name: "SmallChatEmbedding",
            dependencies: ["SmallChatCore"]
        ),
        // ---- Transport ----
        .target(
            name: "SmallChatTransport",
            dependencies: [
                "SmallChatCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        // ---- MCP ----
        .target(
            name: "SmallChatMCP",
            dependencies: [
                "SmallChatCore",
                "SmallChatRuntime",
                "SmallChatTransport",
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        // ---- Channel ----
        .target(
            name: "SmallChatChannel",
            dependencies: ["SmallChatCore", "SmallChatMCP"]
        ),
        // ---- Dream ----
        .target(
            name: "SmallChatDream",
            dependencies: ["SmallChatCore", "SmallChatCompiler", "SmallChatEmbedding"]
        ),
        // ---- Shorthand (TS PR #58: extracted from compaction/CRDT/importance) ----
        .target(
            name: "SmallChatShorthand",
            dependencies: ["SmallChatCore"]
        ),
        // ---- Importance (TS PR #55: three-signal importance detection) ----
        .target(
            name: "SmallChatImportance",
            dependencies: ["SmallChatCore", "SmallChatShorthand"]
        ),
        // ---- CRDT (TS PR #56: multi-agent shared memory) ----
        .target(
            name: "SmallChatCRDT",
            dependencies: ["SmallChatCore", "SmallChatShorthand"]
        ),
        // ---- Compaction (TS PR #57: three-strategy verification) ----
        .target(
            name: "SmallChatCompaction",
            dependencies: ["SmallChatCore", "SmallChatShorthand"]
        ),
        // ---- Memex (TS PR #60: knowledge-base compiler) ----
        .target(
            name: "SmallChatMemex",
            dependencies: [
                "SmallChatCore",
                "SmallChatShorthand",
                "SmallChatEmbedding",
                "SmallChatImportance",
            ]
        ),
        // ---- Umbrella ----
        .target(
            name: "SmallChat",
            dependencies: [
                "SmallChatCore",
                "SmallChatRuntime",
                "SmallChatCompiler",
                "SmallChatEmbedding",
                "SmallChatTransport",
                "SmallChatMCP",
                "SmallChatChannel",
                "SmallChatDream",
                "SmallChatShorthand",
                "SmallChatImportance",
                "SmallChatCRDT",
                "SmallChatCompaction",
                "SmallChatMemex",
            ]
        ),
        // ---- CLI ----
        .executableTarget(
            name: "SmallChatCLI",
            dependencies: [
                "SmallChat",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // ---- macOS GUI App ----
        .executableTarget(
            name: "SmallChatApp",
            dependencies: ["SmallChat"]
        ),
        // ---- Tests ----
        .testTarget(name: "SmallChatCoreTests", dependencies: ["SmallChatCore"]),
        .testTarget(name: "SmallChatRuntimeTests", dependencies: ["SmallChatRuntime", "SmallChatCore", "SmallChatEmbedding"]),
        .testTarget(name: "SmallChatCompilerTests", dependencies: ["SmallChatCompiler", "SmallChatCore", "SmallChatEmbedding"]),
        .testTarget(name: "SmallChatEmbeddingTests", dependencies: ["SmallChatEmbedding"]),
        .testTarget(name: "SmallChatTransportTests", dependencies: ["SmallChatTransport"]),
        .testTarget(name: "SmallChatMCPTests", dependencies: ["SmallChatMCP", "SmallChatEmbedding"]),
        .testTarget(name: "SmallChatChannelTests", dependencies: ["SmallChatChannel"]),
        .testTarget(name: "SmallChatDreamTests", dependencies: ["SmallChatDream"]),
        .testTarget(name: "SmallChatShorthandTests", dependencies: ["SmallChatShorthand"]),
        .testTarget(name: "SmallChatImportanceTests", dependencies: ["SmallChatImportance"]),
        .testTarget(name: "SmallChatCRDTTests", dependencies: ["SmallChatCRDT"]),
        .testTarget(name: "SmallChatCompactionTests", dependencies: ["SmallChatCompaction"]),
        .testTarget(name: "SmallChatMemexTests", dependencies: ["SmallChatMemex", "SmallChatCore"]),
    ]
)
