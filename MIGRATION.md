# Migrating to smallchat-swift 1.0

1.0 is the first tagged release. Pin it with:

```swift
.package(url: "https://github.com/johnnyclem/smallchat-swift", from: "1.0.0"),
```

The `1.0.0` tag is created when the release is published. Until then (and for any
earlier version, none of which was tagged) pin a commit with `revision:`.

The sections below cover each breaking change from 0.6.x and what to do about it.
[`CHANGELOG.md`](CHANGELOG.md) has the full list of changes.

## Toolchains and platforms

### Swift 6.1 or newer is required

The manifest is `swift-tools-version: 6.1`. Use Xcode 16.3 or newer on macOS, or a
Swift 6.1+ toolchain on Linux. CI covers Xcode 16.4, the newest Xcode, and Swift 6.1,
6.3 and 6.4 on Linux.

On Linux with Swift 6.1, an executable that links `SmallChatAgents` (which uses
`@Observable`) fails to link: 6.1's `libswiftObservation.so` references
`swift::threading::fatal`, which its `libswiftCore.so` does not export. Link with
`-Xlinker --allow-shlib-undefined` (`swift build -Xlinker --allow-shlib-undefined`,
and the same for `swift test`), or use Swift 6.2 or newer. Other products, and
macOS, are not affected.

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

### swift-crypto on Linux

On Linux the package now depends on
[swift-crypto](https://github.com/apple/swift-crypto) (`3.0.0..<6.0.0`) for SHA-256 and
HMAC; Apple platforms keep using CryptoKit. If your Linux package pins swift-crypto
outside that range, widen one of the two. [Linux hashes](#linux-hashes) covers the
values that change.

### `SmallChatUI` exists only on Apple platforms

`SmallChatUI` and `SmallChatApp` are declared only when the package is resolved on a
Mac, and `import SmallChat` re-exports `SmallChatUI` only on macOS and iOS. A Linux
target that names the `SmallChatUI` product must drop it (it never compiled there).
Code shared with Linux that uses `AppWebView` should import `SmallChatUI` under
`#if os(macOS) || os(iOS)`.

### `AppWebViewSandbox` is main-actor isolated

Create `AppWebViewSandbox` on the main actor (SwiftUI's `make*View` and
`AppWebViewConfiguration.make(for:)` already run there). If you wrapped its
`webView(_:decidePolicyFor:decisionHandler:)` in your own navigation delegate,
declare the handler as `@escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void`,
or WebKit won't call your method either. Navigations to other origins are now
really cancelled; the initial `about:blank` document is allowed.

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
separate value; it is now `1.0` (see [Artifacts and the compiler](#artifacts-and-the-compiler)).

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

## Dispatch

smallchat-swift 1.0 follows @smallchat/core 1.0's resolution rules and runs its
conformance vectors (`Tests/Fixtures/spec`: canonical JSON, call digests, tool ids,
ranking, resolve outcomes, artifacts). Those vectors are the parity that is tested;
where the two runtimes disagree on a case the vectors do not cover, the TypeScript
runtime is the reference. Not ported yet: argument coercion, the semantic map
(learned choices), observer feedback, the decision log, replay and explain.

### Resolve, then run by id

`tieredDispatch`, `TieredDispatchResult`, `StrictAmbiguityError`,
`DispatchContext.forward` and the fallback chain types are gone. Use:

```swift
// What would run? Nothing executes.
let resolution = try await runtime.resolve("open an issue about the crash")
switch resolution.outcome {
case .resolved:
    print(resolution.chosen!, resolution.tier)            // "github/create_issue", .high
case .needsDisambiguation, .unresolved:
    print(resolution.refinement?.nearMatches.map(\.toolId) ?? [])
case .throttled:
    print("retry in \(resolution.retryAfterMs ?? 0) ms")
}

// Run exactly one tool, named by its canonical id.
let result = try await runtime.dispatchById("github/create_issue", args: ["title": "Crash on launch"])

// Or both in one call: resolve (with the cache), then dispatchById the chosen tool.
let result2 = try await runtime.dispatch("open an issue about the crash", args: ["title": "Crash"])
```

An intent dispatch that does not settle on one tool runs nothing. Its result has
`isError == true`, and `result.metadata?[DispatchMetadataKey.outcome]` is one of the
`DispatchOutcomeCode` raw values (`needs-disambiguation`, `unresolved`, `throttled`,
`invalid-arguments`, `aborted`, `not-dispatched`) with a `ToolRefinement` under
`DispatchMetadataKey.refinement`. Show the near matches to the user and call
`dispatchById` with the tool id they pick. Code that matched on
`TieredDispatchResult.dispatched` should check `outcome == "resolved"`. A tool that ran
and failed is also `isError`, with outcome `resolved`.

`DispatchBuilder.execContent()` now throws `DispatchError` (with the result and its
`outcome`) for an `isError` result instead of returning the error payload as content.

### Below HIGH, a tool runs only with an LLM verifier

`DispatchConfig.requireLLMForSubHighDispatch` (default `true`) lets a MEDIUM or LOW
match run only after an `LLMClient` approves it for the intent. `NoOpLLMClient`
(the default) does not verify (`providesVerification == false`), so without a real
client such matches come back as needs-disambiguation. Either supply an `LLMClient`
(`RuntimeOptions(llmClient:)`), call `dispatchById` once the user has chosen, or set
`requireLLMForSubHighDispatch = false` to let schema and keyword verification alone
pass them. A custom `LLMClient` that cannot verify should return `false` from
`providesVerification`.

### Destructive tools need an exact match

Give tools MCP annotations (`ToolIMP.annotations`, `ToolProxy(…, annotations:)`, or
`annotations` in a manifest). A destructive tool (`destructiveHint: true`, or
`readOnlyHint: false` without `destructiveHint`) runs by intent only from a pinned
phrase or an EXACT similarity (>= 0.95) of the intent's own embedding; otherwise call
it by id. Set `DispatchConfig.treatUnannotatedAsDestructive` to treat tools with no
annotations the same way.

### `DispatchConfig`

| 0.6 | 1.0 |
|---|---|
| `exactThreshold` 0.98, `highThreshold` 0.85, `mediumThreshold` 0.70, `lowThreshold` 0.55 | `thresholds: TierThresholds` 0.95 / 0.85 / 0.75 / 0.60 (the `…Threshold` properties are read-only views of it) |
| `vectorSearchThreshold` | the LOW threshold (MEDIUM in strict mode) |
| `ambiguityGap`, `tier(for:runnerUp:)` | removed: a close runner-up no longer lowers the tier |
| `enableVerification`, `enableDecomposition`, `enableRefinement` | removed: verification below HIGH always runs; decomposition needs an `LLMClient` |
| `strict` (MEDIUM ran after keyword checks) | verifies below EXACT and considers nothing below MEDIUM |
| — | `requireLLMForSubHighDispatch`, `treatUnannotatedAsDestructive`, `maxDecompositionDepth`, `maxSubDispatches` |

Scores are quantized to 1e-4 before tiers are computed. `DispatchConfig.miniLM` keeps
its own thresholds. Recalibrate any custom thresholds against your embedder.

### Canonical forms, cache keys and pins

- `canonicalize` is for display only. It now deletes punctuation inside words
  (`"search_code"` → `searchcode`) and has no 32-token cap (`maxCanonicalTokens` is
  gone). Do not use it as a key: use `intentKey(_:)`.
- `ResolutionCache` is keyed by `intentKey(_:)` and only used by intent dispatch;
  `resolve` reads it only with `ResolveOptions(learn: true)`. Pinned and destructive
  tools are never cached, and every hit is judged by the policy again.
- Dispatch uses only cache entries it stored itself under the current
  `DispatchContext.registryGeneration`, for tools that are still registered.
  Entries you `store` into the cache yourself are misses; let dispatch fill it.
- A dispatch whose tool is unregistered or replaced (`unregisterClass`,
  `registerClass` with the same name, `reindex`, `swizzle`, `addOverload`,
  `loadCategory`) while the call is being resolved or validated runs nothing and
  returns outcome `unresolved`. Dispatch again to resolve against the new registry.
- `SelectorTable.resolve` returns a selector carrying the intent's own vector and keeps
  no intent cache (`cachedIntentCount` is gone).
- `IntentPinRegistry.checkExact` takes the raw intent and compares whole phrases with
  `normalizePinPhrase(_:)`, so an `exact` pin's alias no longer matches a longer or
  negated sentence. Add every phrasing you want accepted as an alias.

### Rate limiting is opt-in, per principal

`SemanticRateLimiter` runs only when you set `RuntimeOptions.rateLimiter`. Pass
`principal:` in `ResolveOptions`, `DispatchOptions` or `DispatchByIdOptions` to give
each caller its own window. A refusal is the `throttled` outcome with `retryAfterMs`
instead of a thrown `VectorFloodError`. `ResolutionCache.rateLimiter` and the
`rateLimiter:` parameter of `SelectorTable.init` are removed.

If you call the limiter yourself, use `admit(_:principal:)` before embedding, then
`record(_:vector:)` or, if embedding failed, `release(_:)`: `admit` reserves the
window slot in the same step as the check, so concurrent intents can't all pass it.
`evaluate` and `check` only look and reserve nothing.

### Proofs and verification

`ResolutionProof` has the 1.0 shape (`outcome`, `decision`, `tier`, `chosen`, `ran`,
`candidates`, `steps`, `callDigest`, `proofDigest`, …); `ResolutionStep` is gone and
`finalTier` is deprecated in favour of `tier`. `verifyCandidate(…)` is replaced by
`verify(_:intent:args:llm:options:)`, which returns a `VerificationResult` (`pass`,
`schemaMatch`, `descriptionOverlap`, `llmConfirmed`, `reason`).

### Arguments are validated

Every call (`dispatchById`, intent dispatch, MCP `tools/call`) is checked against the
tool's `inputSchema` first; a failing call runs nothing and returns outcome
`invalid-arguments` with the `ValidationError`s. Fix the caller, or the schema if it
is wrong. A schema the validator cannot evaluate (`unevaluatedProperties`,
`unevaluatedItems`, `$dynamicRef`, `$recursiveRef`, a remote `$ref`, an unknown
`$schema`, an invalid `pattern`) makes the tool uncallable rather than unchecked;
simplify such schemas.

## Artifacts and the compiler

### Recompile your toolkits

Artifacts are format 1.0, the @smallchat/core 1.0 format, and a 0.x artifact is
refused with `ArtifactVersionError`. Run `smallchat compile` again (or serve the
manifest directory). The toolkit records the embedder that compiled it, and loading
it with a different embedder throws `EmbedderMismatchError`: smallchat-swift ships
only the hash embedder (`LocalEmbedder`, any dimensions), so an artifact compiled by
@smallchat/core with its default ONNX embedder needs an `Embedder` of yours that
declares the same `fingerprint`. To share one artifact between both runtimes, compile
it with the hash embedder at the same dimensions (`smallchat compile --embedder hash`
in TypeScript; the hash embedder is the only one here, 384 dimensions by default in
both).

In code, `SerializedArtifact`, `ArtifactIO`, `buildArtifact` and their nested types
are replaced by `ArtifactV1`:

```swift
let result = try await ToolCompiler(embedder: embedder, vectorIndex: MemoryVectorIndex()).compile(manifests)
let artifact = try ArtifactV1.build(result: result, manifests: manifests, embedder: embedder.fingerprint!)
try artifact.write(to: URL(fileURLWithPath: "tools.toolkit.json"))

let loaded = try ArtifactV1.read(contentsOf: URL(fileURLWithPath: "tools.toolkit.json"))
let toolkit = try await MCPToolkit.make(artifact: loaded)   // asserts the embedder
```

`ARTIFACT_FORMAT_VERSION` moved from `SmallChatMCP` to `SmallChatCore` (both are
re-exported by `SmallChat`).

### Duplicates are errors, aliases are selectors

The compiler no longer merges tools whose embeddings are close. Two distinct tools at
or above the duplicate threshold (0.95) fail with `DuplicateToolError`, which names
the pairs: give them distinct descriptions or a `selectorHint`, exclude one, or pass
`CompilerOptions(allowDuplicates: true)` / `compile --allow-duplicates` to keep both
(intents near them then resolve to needs-disambiguation). `deduplicationThreshold`
(and `--deduplication-threshold`) is now `duplicateThreshold`
(`--duplicate-threshold`). Two tools pinned to one selector, sharing one alias
phrase, or one tool name declared twice by a provider fail with
`SelectorConflictError`.

Each alias is its own selector (`<canonical>~alias~<alias_with_underscores>`), and a
tool's embedding text is `<name>: <description>` plus its selector hint, so vectors
and `uniqueSelectorCount` differ from 0.6 artifacts.

### Embedders and indexes

`Embedder` has a `fingerprint` requirement (default `nil`). Declare one in a custom
embedder that compiles artifacts; an embedder without one cannot load an artifact.

`LocalEmbedder` now computes @smallchat/core's hash-embedder vectors: it hashes UTF-16
code units instead of UTF-8 bytes, keeps only ASCII letters, digits and whitespace
when it tokenizes (as the TypeScript embedder does), and normalizes in double
precision. `MemoryVectorIndex` scores in double precision and orders ties by id. Text
with non-ASCII characters embeds differently from 0.6, and other vectors and scores
can differ in the last float32 bit, so re-embed any vectors you stored yourself
(compiled artifacts have to be recompiled anyway).

### CLI

- `smallchat resolve` prints the outcome, tool id, candidates and proof digest
  (`--json` for the proof); `--top-k` and `--threshold` are removed.
- `smallchat compile` writes format 1.0 and adds `--allow-duplicates`, `--dims` and
  `--duplicate-threshold`.
- `smallchat serve` lists `smallchat_resolve` unless `--no-resolve-tool`;
  `--semantic-dispatch` is removed.

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
- On a server bound to a loopback address, the `Host` and `Origin` names must be
  `localhost`, `::1` or a dotted-decimal IPv4 address in 127.0.0.0/8. Other names
  that resolve to loopback (`127.0.0.1.nip.io`, a hosts-file alias) are refused with
  `403`; list an `Origin` you need in `MCPServerConfig.allowedOrigins`, or bind to a
  non-loopback address and use `--auth`.
- Requests are read like `JSON.parse` reads them. An object whose member names are
  canonically equivalent but spelled with different code points (`"\u00e9"` and
  `"e\u0301"`) is a parse error (`-32700`).

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
`result`. Semantic intent dispatch is no longer reachable through tool names, and no
meta-tool runs a tool from an intent. Call the read-only `smallchat_resolve` meta-tool
with `{"intent": "..."}` (and `"args"` when you know them): it returns the proposed
tool's `name`, `toolId`, `tier`, candidates and `proofDigest`, and runs nothing. Then
call the proposed tool by name. `serve --no-resolve-tool` leaves the meta-tool out.
Arguments that fail a tool's `inputSchema` come back as an `isError` result and the
tool does not run.

### Running tools

`serve` executes tools at their provider manifest's `endpoint`. Give each provider
manifest an `endpoint` (an MCP Streamable HTTP URL for `transportType: "mcp"`, a base
URL for `"rest"`), and recompile artifacts with 1.0 (`smallchat compile`) or serve the
manifest directory directly. Tools without an endpoint are listed but fail when called.

In code, replace `MCPRouter.setRefinementHandler` with `setToolExecutor(_:)` (exact
calls) and, for the meta-tool, `setResolveHandler(_:)`; or call
`MCPServer.setRuntime(_:resolveTool:)`, which runs each call through
`ToolRuntime.dispatchById`. Drop the `sseBroker:` argument from `MCPRouter.init`.
`MCPServerConfig.semanticDispatch` is now `resolveTool` (default `true`).

`ToolProxy.execute` now throws `ToolNotExecutableError` unless you pass an
`executor:` when creating the proxy.

`MCPClientTransport.execute(toolName:args:)` for an MCP tool returns the upstream
`CallToolResult` as the result's content (an `AnyCodableValue` object with
`content`, `structuredContent` and `isError`), flagged with
`metadata[mcpCallToolResultMetadataKey] == true`, instead of only its `content`
array. Read `content` from that object, or pass the result to `mcpCallToolResult(_:)`.

### Authentication

`MCPServerConfig.enableAuth` and the OAuth types are removed. Pass
`authToken: "<secret>"` (or `serve --auth`, which reads `SMALLCHAT_MCP_TOKEN` or a
0600 token file) and configure clients to send `Authorization: Bearer <secret>`.
`serve --auth` refuses a token file that group or other users can access; if you
wrote one yourself, `chmod 600` it:

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
`ChannelInboundEvent` moved from `SmallChatAgents` to `SmallChatChannel`.
`SmallChatAgents` re-exports `SmallChatChannel`, so code that imports
`SmallChatAgents` or `SmallChat` keeps compiling unchanged.

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

## Truth (`SmallChatTruth`)

SmallChatTruth reads Stenographer's truth format v2 (`Tests/Fixtures/truth-format/README.md`
is the spec). Stenographer 1.0 writes it; Stenographer 0.x wrote version 1 lines,
which are still read.

### Statuses are open strings, and fold

`TbStatus`, `UvStatus`, `TruthEvidence.Kind` and `TruthVerifyBy.Kind` are structs
wrapping the string a line carries. `.active`, `.open`, `.commit` and the other known
values still work, including in `==` and `switch`; `.struck` (TB and UV) and
`.claimedCommand` are new. A `switch` over one now needs a `default:`. `rawValue` is
the string as written, and a value this version doesn't know is kept, never turned
into a known one.

`TruthTbEntry.status` and `TruthUvEntry.status` are optional (`nil` when the line has
no status) and hold the folded status: the last `TRANSITION` that targets the entry,
else the line's own (`source?.lineStatus`). Don't decide what counts as truth by
comparing statuses yourself: call `TruthWiki.classify(_:)` or
`TruthWiki.selectCurrentTruth(_:)`, which also leave out struck, unsigned and
inadmissible entries and any unknown or missing status.

`TruthTbEntry`/`TruthUvEntry` initializers take `status:` as an optional and gain
`extra:`, `source:` and `inadmissible:` parameters with defaults, so existing calls
compile.

### Reading

- `TruthWiki.parse` returns `TruthReadError`s (`line`, `error`, `id`, `file`). A v2
  stream with any refused line or a broken chain is refused whole:
  `result.refused` is true and `result.entries` is empty. A version 1 file is still
  read line by line.
- Read several files with `TruthWiki.parseFiles([(name, text)])`, not by
  concatenating their lines: each file is one writer's stream with its own chain.
  `TruthLedgerSnapshot.load(paths:)` does this.
- Version 1 TBs are not current truth (they carry no hash). To read a 0.x export as
  before, pass `TruthReadOptions(admitV1Tbs: true)`; better, have Stenographer 1.0
  export a new file of its own.
- Version 1 lines need what Stenographer's import needs: an RFC 3339 `ts`, at least
  one piece of evidence on a TB, and accountable identities.

### Identities and literals

`assertAccountableAuthor` and `isAnonymousIdentity` compare identities by a folded key
(width, case and invisible characters), so `ａｓｓｉｓｔａｎｔ` is anonymous like
`assistant`. `assertAccountableAuthor` also refuses identities with control characters
and the reserved `migration` and `detector:*` (pass `allowDetector: true` for a
detector's own proposals).

Tombstoned literals follow Stenographer's rule: without a `subject`, the dead value
needs at least 4 UTF-16 code units and an ASCII letter (so `日本語版` now needs a
subject), values are trimmed, and an explicit `"subject": null` is refused. Check
drafts with `TombstoneDraft.problems()` or `TruthTombstonedLiteral.validationError()`.

### Agents settle claims only together

Truth format v2 lets agents settle a claim only as a quorum: two or more agent sessions
agreeing from different angles (settling evidence of two kinds, no item shared) within
15 minutes (spec: "Agent quorum"). `TruthFormat.decode` refuses a line whose `quorum`
breaks those rules, or that carries one anywhere but a v2 TB or ADDENDUM
(`TruthQuorum.issues(in:)` lists the broken rules). A TB an agent signs is truth only
with a quorum whose members are all agents and cite settling evidence this version
knows; otherwise `inadmissible?.reason` is the new `.agentWithoutQuorum`
(`agent-without-quorum`). An agent is an identity the signer registry lists with role
`agent`, or, without a registry, one whose key starts with `agent:`
(`TruthQuorum.isAgent(_:signers:)`). A person still signs alone. A `switch` over
`TruthInadmissible.Reason` needs the new case.

`TruthTbEntry` has `quorum: [TruthQuorumMember]?`, and its initializer takes
`quorum:` (default `nil`). `quorum` is no longer one of the `extra` fields.

`TruthEvidence.Kind` knows `chat`, `ticket` and `doc`, and every kind has a class:
`kind.evidenceClass` is `.settling` for `commit`, `file`, `test`, `claimed-command`
and `wiki` (`TruthEvidence.Kind.settling`), and `.question` for every other kind,
including one this version doesn't know. The classes bind agents only: a person may
sign on any evidence.

`consumptionRules` (shipped verbatim from Stenographer) now tells an agent to file its
verdict with `resolve_uv`, which settles only when another session agrees.

A `signers.json` entry may carry `keys` (public keys, reserved for 1.x); 1.0 ignores
them.

### Writing back

`TruthWiki.serialize` returns each entry's original line. If you changed an entry
and want a new line, set its `source` to `nil` first (you get the version 1 shape),
but don't write it into a file Stenographer exports: each truth file has one writer.

### Proposals

`TruthProposals.serialize` writes PROPOSAL envelopes (truth format v2, hash-chained).
To append to an existing proposals file, continue its chain:
`TruthProposals.serialize(new, after: TruthProposals.head(of: existingLines))`. The
default `signal.source` is `compaction-candidate`. `InvariantProposal` is no longer
`Codable`; encode `proposal.envelope.line(after:)` instead.

### Renderings

Rendered sections, compaction items, invariant records and objection summaries
escape markers inside ledger text (`[TB]` becomes `\[TB]`). Code that searched the
rendered text for a claim containing `[` should search for the escaped form, or use
the entries themselves.

## Messenger (`SmallChatAgents`)

### Switchboard protocol

The switchboard's commands and output lines now carry a framing nonce. If you call
`SwitchboardProtocol` directly, pass the nonce: `systemPrompt(name:nonce:)`,
`relayCommand(ticket:to:cwd:body:nonce:)`, `listCommand(nonce:)` and
`parse(_:nonce:)`, with one value from `SwitchboardProtocol.makeNonce()` per
switchboard session. `Switchboard` and `ClaudeCodeTransport` do this for you. A
`Switchboard.relay` that times out now throws `SwitchboardError`.

### `claude` invocations and the CLI version

`ClaudeCommand` no longer puts prompts or system prompts in `arguments`. If you
build a `ClaudeInvocation` yourself and run it with `ClaudeProcess`, set
`prompt` (sent on stdin as one stream-json user message, then stdin closes) and
`appendSystemPrompt` (passed as a private `--append-system-prompt-file`), and use
`--input-format stream-json`. If you inspected `arguments` for the prompt, read
`invocation.prompt` instead.

The messenger now launches its switchboard and stenographer with `--tools`,
`--strict-mcp-config`, `--setting-sources user` and `--append-system-prompt-file`.
Update Claude Code if a launch fails with an unknown option. The switchboard runs in
`<Application Support>/SmallChat/switchboard`
(`ClaudeCodeTransport.Configuration.switchboardDirectory`) instead of your home
directory, and the stenographer gets only `Read`, `Grep` and `Glob`; tools your
settings used to let them run are no longer available to them.

### `AgentTransport.shutdown()`

Custom transports must implement `func shutdown() async` (an empty body is fine
when nothing keeps running).

### Two secrets, kept out of `messenger.json`

The objection channel secret and the new notary secret are generated on the first
1.0 launch and kept in the Keychain on macOS (0600 files beside `messenger.json`
elsewhere); the secret older builds stored in `messenger.json` is removed. To
reconnect stenographer, stop it and start it again with **Settings → Objection
channel → Copy stenographer command**. The command reads both secrets when it runs
(`SMALLCHAT_CHANNEL_SECRET="$(security find-generic-password …)"`), so the first
run asks you to let `security` read them. If an older command with a secret in it
is in your shell history, delete that line. A locally built app is signed anew by
each build, so macOS may also ask once per build before the app can read its own
Keychain items.

In code:

- `settings.objectionChannelSecret` is gone: read `model.channelSecret`, and
  `model.notarySecret` for stenographer's `STENOGRAPHER_NOTARY_SECRET`.
- `MessengerStore(url:)` with a file uses the Keychain on macOS. Pass
  `MessengerStore(url: url, secrets: InMemorySecretStore())` (or a
  `FileSecretStore`) in tests and previews to keep them out of the Keychain.
- `PendingProposal.notarizeURL` is gone. Build the URL with
  `NotaryClient.notarizeURL(restBase:proposalId:)`, which now returns an optional,
  and call `NotaryClient.parseInbox(_:)` without `restBase`.

### Tombstones go to Stenographer, not to a wiki file

Signing a tombstone no longer appends to a wiki file: the app submits a PROPOSAL
envelope to Stenographer (`POST /proposals`) and notarizes it in your name
(`POST /proposals/:id/notarize`). This needs Stenographer 1.0 running with its REST
API (`--rest-port`, default 8787) and the messenger's notary secret and REST token
(restart it with **Copy stenographer command**).

- `try model.assertTombstone(draft)` is now `try await model.assertTombstone(draft)`.
- `model.tombstoneTarget` is gone, and `settings.tombstoneFile` is ignored.
- `TombstoneDraft.sign()` and `TruthWiki.append(_:toFileAt:)` are gone. Build the
  envelope with `draft.proposal(author:)` and send it with
  `NotaryClient.submitAndNotarize(_:notary:restBase:secret:restToken:)`.
- Tombstones an older build wrote (by default to `smallchat-tombstones.jsonl` in your
  wiki folder) are version 1 lines, which no longer count as truth. Sign them again
  in the app, or have Stenographer `import_wiki_entries` that file, which files each
  one as a proposal for you to notarize; then remove the file.

### A third secret: Stenographer's REST token

Stenographer 1.0 requires `Authorization: Bearer <token>` on every REST route
(unless started with `--rest-insecure`). The messenger generates the token like its
other secrets (`model.restToken`, `MessengerSecret.restToken`, kept in the Keychain)
and the copied launch command passes it as `STENOGRAPHER_REST_TOKEN`. Restart
Stenographer with the new command. `NotaryClient.request(for:notarizeURL:secret:restToken:)`
and `NotaryClient.openDrafts(restBase:restToken:session:)` take it; `ensureSecrets`
returns it too.

### Saving is asynchronous

`MessengerModel` writes `messenger.json` in the background, within half a second
of a change and when the app quits. Code (or a test) that reads the file, or
creates a second model on the same store, right after changing something should
first `await model.flushPersistence()`.

### Live sessions without a known name

Sending to a live session whose Claude Code name isn't known now fails with
`AgentTransportError.liveSessionUnnamed` instead of resuming it. The message says
to retry once the session's name shows or after it stops.

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
