# Migrating to smallchat-swift 1.0

1.0 is the first tagged release. Pin it with:

```swift
.package(url: "https://github.com/johnnyclem/smallchat-swift", from: "1.0.0"),
```

The sections below cover each breaking change from 0.6.x and what to do about it.
[`CHANGELOG.md`](CHANGELOG.md) has the full list of changes.

## Toolchains and platforms

### Swift 6.1 or newer is required

The manifest is `swift-tools-version: 6.1`. Use Xcode 16.3 or newer on macOS, or a
Swift 6.1+ toolchain on Linux. CI covers Xcode 16.4, the newest Xcode, and Swift 6.1,
6.3 and 6.4 on Linux.

### `OSAllocatedUnfairLock` is no longer exported on Linux

Before 1.0, `import SmallChatCore` (or `import SmallChat`) on Linux brought in a
public `OSAllocatedUnfairLock` shim. It is now the package-scoped `PlatformLock`,
which you cannot use from outside the package. On Apple platforms nothing changes:
`OSAllocatedUnfairLock` comes from the `os` module as before.

If Linux code relied on the shim, use a lock of your own, for example
`Mutex` from the `Synchronization` module (Swift 6.0+, macOS 15+/iOS 18+ on Apple
platforms), `NIOLockedValueBox` from swift-nio's `NIOConcurrencyHelpers`, or an
`NSLock`-protected value.

### Subprocess APIs are macOS/Linux only

`MCPStdioTransport`, `LoomMCPClient`, `ContainerSandbox.spawnProcess(...)` and
`ContainerSandbox.isDockerAvailable()` are compiled only on macOS and Linux. They
never built for iOS (iOS has no `Foundation.Process`), so iOS code could not have
used them; code that targets several platforms should wrap its uses in
`#if os(macOS) || os(Linux)`. On iOS, reach MCP servers over HTTP with
`MCPSSETransport` or `MCPClientTransport` instead.

`SmallChatAgents` (which spawns the `claude` CLI) is not an iOS library.

### `SmallChatUI` exists only on Apple platforms

`SmallChatUI` and `SmallChatApp` are declared only when the package is resolved on a
Mac, and `import SmallChat` re-exports `SmallChatUI` only on macOS and iOS. A Linux
target that names the `SmallChatUI` product must drop it (it never compiled there).
Code shared with Linux that uses `AppWebView` should import `SmallChatUI` under
`#if os(macOS) || os(iOS)`.

## Reported versions

`SmallChatVersion.current` (in `SmallChatCore`) is now the only version string, and
it is `1.0.0`. These values change:

| Where | 0.6.x | 1.0 |
|---|---|---|
| MCP server `serverInfo.version`, `mcpServerVersion`, `RouterOptions.serverVersion` default | `0.6.0` | `1.0.0` |
| Channel server `serverInfo.version` | `0.3.0` | `1.0.0` |
| `MCPStdioTransport` and `MCPClientTransport.initialize` `clientInfo.version` | `0.1.0` | `1.0.0` |
| `smallchat --version`, `version` in generated configs, toolkit files and knowledge bases | `0.6.0` | `1.0.0` |

If you matched on any of these strings (in an allowlist, a test, or a log query),
match on `SmallChatVersion.current` or the new value. `ARTIFACT_FORMAT_VERSION` is a
separate value and did not change.

## Linux hashes

On Linux, audit-log HMACs (`AuditLog`) and Dream artifact hashes
(`ArtifactVersioning`) used non-cryptographic fallbacks (FNV and djb2) because
CryptoKit is Apple-only. They now use swift-crypto's `HMAC<SHA256>` and `SHA256`, the
same values Apple platforms produce.

- `AuditLog` is in memory, so nothing on disk changes. Chain heads (`chainHead()`)
  that you recorded elsewhere from a 0.6.x Linux process will not match 1.0 values.
- Dream artifact manifests written by a 0.6.x Linux build hold 16-hex-digit djb2
  values in `hash`; new entries hold 64-hex-digit SHA-256. SmallChat only records
  these values, but tools that compare them should treat the short ones as legacy.
