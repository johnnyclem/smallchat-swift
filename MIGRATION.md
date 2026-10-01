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

## Transports

### `TLSConfig` and its types are removed

`TLSConfig`, `CertificatePinningMode`, `TLSVersion` and `TLSError` were never
consumed by any transport, so pinning and minimum TLS versions configured with them
were not enforced. Delete the values. To pin certificates today, give
`HTTPTransport` traffic a `URLSession` you control (for example behind your own
`Transport` implementation) whose delegate checks the server trust.

### `HTTPTransport` follows the route

Requests are now built from the route the way OpenAPI and Postman importers
describe it:

| Call | 0.6.x | 1.0 |
|---|---|---|
| `GET /pets/{petId}` with `petId: 42` | `GET /pets/%7BpetId%7D` | `GET /pets/42` |
| `queryParams: ["verbose"]` with `verbose: true` | dropped | `?verbose=true` |
| `GET` without declared query params, args `limit: 5` | dropped | `?limit=5` |
| `POST /pets/{petId}/name` with `petId`, `name` | both in the body | `petId` in the path, `name` in the body |
| placeholder with no argument | sent literally | `TransportError.invalidRequest`, nothing sent |

If a server relied on the old body (for example reading a path parameter from
the JSON body), declare `bodyParams` on the route. `TransportSerialization.serializeInput`
now `throws`; add `try`.

### `TransportError.invalidRequest`

Add a case for `.invalidRequest(message:)` to exhaustive `switch`es over
`TransportError`. It is not retryable.

### `MCPStdioTransport` protocol versions

The client now asks for MCP `2025-11-25` and accepts `2025-11-25`, `2025-06-18`,
`2025-03-26` or `2024-11-05` from the server. A server that answers anything else
fails `connect()` with `TransportError.connectionFailed`. Servers built on an
official MCP SDK negotiate one of these.

## MCP server

### One endpoint: `/mcp`

The server is a Streamable HTTP MCP server. Point clients at
`http://<host>:<port>/mcp` (it was `/` or `/rpc`). For Claude Code:

```bash
claude mcp add --transport http smallchat http://127.0.0.1:3001/mcp
```

- Read the session id from the `Mcp-Session-Id` response header of `initialize`
  (it is no longer in the result) and send it on every later request; send
  `DELETE /mcp` to end the session instead of calling `shutdown`.
- `GET /sse`, `GET /.well-known/mcp.json` and `POST /oauth/token` are gone. Use
  `GET /health` for liveness.
- The server negotiates `2025-11-25` or `2025-06-18`. Clients that only speak
  2024-11-05 (HTTP+SSE) cannot connect; every current official SDK can.

### Tool names and results

`tools/list` names tools `<providerId>__<toolName>`, and `tools/call` accepts only
those names. To keep upstream names (for example for policies keyed on them), serve
one provider: `smallchat serve --provider github` or
`MCPServerConfig(toolNaming: .provider("github"))`.

`tools/call` results are MCP `CallToolResult`s:

```json
{"content": [{"type": "text", "text": "{\"id\":7}"}], "structuredContent": {"id": 7},
 "isError": false, "_meta": {"dev.smallchat/toolId": "github/create_issue"}}
```

Read `isError` instead of `status`, and `structuredContent` (or the text) instead of
`result`. Semantic intent dispatch is no longer reachable through tool names; enable
the `smallchat_dispatch` meta-tool with `--semantic-dispatch` and call it with
`{"intent": "...", "arguments": {...}}`.

### Running tools

`serve` executes tools at their provider manifest's `endpoint`. Give each provider
manifest an `endpoint` (an MCP Streamable HTTP URL for `transportType: "mcp"`, a base
URL for `"rest"`), and recompile artifacts with 1.0 (`smallchat compile`) or serve the
manifest directory directly. Tools without an endpoint are listed but fail when called.

In code, replace `MCPRouter.setRefinementHandler` with `setToolExecutor(_:)` (exact
calls) and, if you want the meta-tool, `setSemanticDispatchHandler(_:)`; or call
`MCPServer.setRuntime(_:semanticDispatch:)`. Drop the `sseBroker:` argument from
`MCPRouter.init`.

`ToolProxy.execute` now throws `ToolNotExecutableError` unless you pass an
`executor:` when creating the proxy.

### Authentication

`MCPServerConfig.enableAuth` and the OAuth types are removed. Pass
`authToken: "<secret>"` (or `serve --auth`, which reads `SMALLCHAT_MCP_TOKEN` or a
0600 token file) and configure clients to send `Authorization: Bearer <secret>`:

```bash
claude mcp add --transport http smallchat http://127.0.0.1:3001/mcp \
  --header "Authorization: Bearer $(cat ~/.smallchat/serve-token)"
```

### Audit log

`AuditLog()` no longer compiles: pass a key, `AuditLog(hmacKey: key)` (for example
`AuditLog.generateKey()`, or a key from your keychain). `MCPServerConfig.auditKey`
sets the server's key; without one each server process uses a random key.

## Channel

### Bridge types live in `SmallChatChannel`

`ChannelBridgeServer`, `ChannelBridgeProtocol`, `ChannelBridgeResponse` and
`ChannelInboundEvent` moved from `SmallChatAgents` to `SmallChatChannel`. Code that
imports `SmallChatAgents` or `SmallChat` keeps compiling; a target that depends only
on `SmallChatAgents` and names these types should add `import SmallChatChannel`.

### `smallchat channel --http-bridge`

The bridge now really listens, and it needs the shared secret in
`SMALLCHAT_CHANNEL_SECRET` (the command refuses to start without it). Post events
with `X-Channel-Secret: $SMALLCHAT_CHANNEL_SECRET` or
`Authorization: Bearer $SMALLCHAT_CHANNEL_SECRET`. Use a different value from
`STENOGRAPHER_NOTARY_SECRET`. The README's `smallchat channel --port 3002` never
worked: use `smallchat channel --name <name>` (`--http-bridge-port` sets the bridge
port).

### `ChannelServer.shutdown()` is async

Add `await` where you call it outside the actor.

### Channel tags escape their content

`serializeChannelTag` now escapes `&`, `<` and `>` in the content, so markup in an
event (including a closing `</channel>`) reaches the model as text. If you parsed
the content back out of the tag, unescape those three entities.

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
