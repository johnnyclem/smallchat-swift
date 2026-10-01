// SmallChat — umbrella module
@_exported import SmallChatCore
@_exported import SmallChatRuntime
@_exported import SmallChatCompiler
@_exported import SmallChatEmbedding
@_exported import SmallChatTransport
@_exported import SmallChatMCP
@_exported import SmallChatChannel
@_exported import SmallChatDream
@_exported import SmallChatShorthand
@_exported import SmallChatImportance
@_exported import SmallChatCRDT
@_exported import SmallChatCompaction
@_exported import SmallChatTruth
@_exported import SmallChatMemex
// SmallChatUI (SwiftUI + WKWebView) is part of the umbrella on Apple platforms
// only; see the platform notes in Package.swift.
#if os(macOS) || os(iOS)
@_exported import SmallChatUI
#endif
