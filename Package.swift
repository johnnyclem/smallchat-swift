// swift-tools-version: 6.1
import PackageDescription

// Platform support (see README "Platforms"):
//   - Every library product builds on macOS 14+. All of them except SmallChatUI,
//     and the `smallchat` CLI, also build on Linux (Swift 6.1+).
//   - Every library product except SmallChatAgents (which spawns the `claude` CLI)
//     builds on iOS 17+. On iOS the subprocess-backed APIs (MCPStdioTransport,
//     LoomMCPClient, ContainerSandbox.spawnProcess/isDockerAvailable, the rtk filter
//     subprocess) are compiled out, because Foundation.Process does not exist there.
//   - SmallChatUI (SwiftUI + WebKit) and the SmallChatApp messenger (also AppKit)
//     are declared only when the manifest is evaluated on a Mac, because Linux
//     toolchains ship no SwiftUI, AppKit or WebKit. On Linux the SmallChat umbrella
//     builds without SmallChatUI.

#if os(macOS)
let includeAppleUI = true
#else
let includeAppleUI = false
#endif

// CryptoKit on Apple platforms, swift-crypto (same API) everywhere else.
let crypto: Target.Dependency = .product(
    name: "Crypto",
    package: "swift-crypto",
    condition: .when(platforms: [.linux])
)

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
        .library(name: "SmallChatTruth", targets: ["SmallChatTruth"]),
        .library(name: "SmallChatMemex", targets: ["SmallChatMemex"]),
        .library(name: "SmallChatAgents", targets: ["SmallChatAgents"]),
        .library(name: "SmallChat", targets: ["SmallChat"]),
        .executable(name: "smallchat", targets: ["SmallChatCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
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
                "SmallChatCompiler",
                "SmallChatEmbedding",
                crypto,
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // ---- Channel ----
        .target(
            name: "SmallChatChannel",
            dependencies: [
                "SmallChatCore",
                "SmallChatMCP",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // ---- Dream ----
        .target(
            name: "SmallChatDream",
            dependencies: ["SmallChatCore", "SmallChatCompiler", "SmallChatEmbedding", crypto]
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
        // ---- Truth (truth-ledger interop: stenographer TB/UV v2 JSONL seam) ----
        .target(
            name: "SmallChatTruth",
            dependencies: ["SmallChatCore", "SmallChatCompaction"]
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
        // ---- Agents (messenger: Claude Code sessions, groups, switchboard, stenographer) ----
        .target(
            name: "SmallChatAgents",
            dependencies: [
                "SmallChatTruth",
                "SmallChatChannel",
                "SmallChatTransport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
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
                "SmallChatTruth",
                "SmallChatMemex",
            ] + (includeAppleUI
                ? [.target(name: "SmallChatUI", condition: .when(platforms: [.macOS, .iOS]))]
                : [])
        ),
        // ---- CLI ----
        .executableTarget(
            name: "SmallChatCLI",
            dependencies: [
                "SmallChat",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // ---- Tests ----
        .testTarget(name: "SmallChatCoreTests", dependencies: ["SmallChatCore", "SmallChatEmbedding"]),
        .testTarget(name: "SmallChatRuntimeTests", dependencies: ["SmallChatRuntime", "SmallChatCore", "SmallChatEmbedding"]),
        .testTarget(name: "SmallChatCompilerTests", dependencies: ["SmallChatCompiler", "SmallChatCore", "SmallChatEmbedding"]),
        .testTarget(name: "SmallChatEmbeddingTests", dependencies: ["SmallChatEmbedding"]),
        .testTarget(
            name: "SmallChatTransportTests",
            dependencies: [
                "SmallChatTransport",
                "SmallChatCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "SmallChatMCPTests",
            dependencies: [
                "SmallChatMCP",
                "SmallChatRuntime",
                "SmallChatEmbedding",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "SmallChatChannelTests",
            dependencies: [
                "SmallChatChannel",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "SmallChatDreamTests", dependencies: ["SmallChatDream"]),
        .testTarget(name: "SmallChatShorthandTests", dependencies: ["SmallChatShorthand"]),
        .testTarget(name: "SmallChatImportanceTests", dependencies: ["SmallChatImportance"]),
        .testTarget(name: "SmallChatCRDTTests", dependencies: ["SmallChatCRDT"]),
        .testTarget(name: "SmallChatCompactionTests", dependencies: ["SmallChatCompaction"]),
        .testTarget(name: "SmallChatTruthTests", dependencies: ["SmallChatTruth", "SmallChatCompaction"]),
        .testTarget(name: "SmallChatMemexTests", dependencies: ["SmallChatMemex", "SmallChatCore"]),
        .testTarget(name: "SmallChatAgentsTests", dependencies: ["SmallChatAgents", "SmallChatTruth", "SmallChatChannel"]),
    ]
)

if includeAppleUI {
    package.products += [
        .library(name: "SmallChatUI", targets: ["SmallChatUI"]),
        .executable(name: "SmallChatApp", targets: ["SmallChatApp"]),
    ]
    package.targets += [
        // ---- UI (App/UI layer — SwiftUI + WKWebView wrapper) ----
        .target(
            name: "SmallChatUI",
            dependencies: []
        ),
        // ---- macOS GUI App ----
        .executableTarget(
            name: "SmallChatApp",
            dependencies: ["SmallChat", "SmallChatUI", "SmallChatAgents"]
        ),
        .testTarget(name: "SmallChatUITests", dependencies: ["SmallChatUI"]),
    ]
}
