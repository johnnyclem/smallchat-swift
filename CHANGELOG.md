# Changelog

All notable changes to the Swift port of smallchat are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

See [`MIGRATION.md`](MIGRATION.md) for how to update.

- **Swift 6.1 is the toolchain floor.** The manifest is now
  `swift-tools-version: 6.1`; Swift 6.0 was never tested and is no longer
  accepted.
- **Linux no longer exports `OSAllocatedUnfairLock`.** The Linux shim in
  `SmallChatCore/Compat` was a public type named after Apple's lock, so any
  module importing SmallChatCore saw it shadow the platform name. It is now
  the package-scoped `PlatformLock` (a typealias for `OSAllocatedUnfairLock`
  on Apple platforms), `Sendable` only when its state is, with Apple's
  `@Sendable` requirements on `withLock`.
- **Subprocess APIs are macOS/Linux only.** `MCPStdioTransport`,
  `LoomMCPClient`, `ContainerSandbox.spawnProcess(...)` and
  `ContainerSandbox.isDockerAvailable()` are no longer compiled for iOS (iOS
  has no `Foundation.Process`, so these never built there). On iOS the
  `rtk filter` subprocess is skipped and `RtkTransport` passes bodies through.
- **`SmallChatUI` and `SmallChatApp` are declared only on Apple hosts**, and
  the `SmallChat` umbrella re-exports `SmallChatUI` only on macOS and iOS.
- **Every version string is `SmallChatVersion.current` (`1.0.0`).** MCP
  `serverInfo.version` was `0.6.0`, the channel server's was `0.3.0`, and the
  MCP clients sent `clientInfo.version` `0.1.0`, the REPL banner said `0.5.0`,
  and `smallchat --version` and the `version` field of generated configs,
  toolkit files and knowledge bases said `0.6.0`. The compiled-artifact format version (`ARTIFACT_FORMAT_VERSION`)
  is unchanged.
- **Linux uses real SHA-256 for audit-log HMACs and Dream artifact hashes.**
  Without CryptoKit, `AuditLog` fell back to an FNV hash and Dream's artifact
  versioning to djb2. Both now use swift-crypto's `HMAC<SHA256>`/`SHA256`, the
  same values Apple platforms produce, so Linux chain heads and recorded artifact
  hashes differ from those of earlier Linux builds.
- **`TLSConfig`, `CertificatePinningMode`, `TLSVersion` and `TLSError` are
  removed.** No transport, `TransportConfig` or `URLSession` delegate ever read
  them, so the certificate pinning and minimum TLS version they described were
  never enforced. The README's "TLS Configuration" claim is gone with them.
- **`HTTPTransport` builds requests from the route.** `{name}` placeholders in a
  route path are filled with the argument of that name, percent-encoded as one
  path segment (they used to be sent literally, as `%7Bname%7D`); a placeholder
  without an argument fails the call with the new `TransportError.invalidRequest`
  and sends nothing. Declared `queryParams` go in the query string. GET and HEAD
  calls without declared query params, and DELETE calls without a route, put their
  arguments in the query string (GET arguments used to be dropped). Other methods send the arguments not used in
  the path or query as the JSON body (path params used to be duplicated there).
  `TransportSerialization.serializeInput` throws, and percent-encodes everything
  but RFC 3986 unreserved characters.
- **`TransportError` has a new case, `invalidRequest(message:)`.** Exhaustive
  `switch`es over `TransportError` need to handle it.
- **`MCPStdioTransport` negotiates the protocol version.** It asks for
  `2025-11-25` (it sent `2024-11-05`) and accepts a server that answers
  `2025-11-25`, `2025-06-18`, `2025-03-26` or `2024-11-05`; any other answer
  fails `connect()`. The agreed version is `negotiatedProtocolVersion`.
- **The MCP server speaks Streamable HTTP on one endpoint, `/mcp`.** `POST /`,
  `POST /rpc`, `GET /sse`, `GET /.well-known/mcp.json` and `POST /oauth/token`
  are gone (`/sse` sent one event and closed; the discovery document advertised
  capabilities the server did not have). `initialize` returns the session id in
  the `Mcp-Session-Id` header only (no longer in the result); every other request
  must send it (`400` without, `404` for an unknown or expired session), and
  `DELETE /mcp` ends a session. Notifications get `202 Accepted`. Batches,
  non-JSON bodies, unsupported `MCP-Protocol-Version` headers, non-loopback
  `Host` names (on a loopback server) and foreign `Origin`s are refused.
- **Protocol versions are negotiated honestly.** The server offers `2025-11-25`
  and `2025-06-18` (`mcpSupportedProtocolVersions`), echoes a supported requested
  version and otherwise answers with the newest. It no longer claims 2024-11-05,
  whose HTTP+SSE transport it never implemented. `mcpProtocolVersion` is now
  `2025-11-25`. `initialize` advertises only `tools`, `resources` and `prompts`
  (no `listChanged`, `subscribe` or `logging`); `resources/subscribe` and the
  non-standard `shutdown` method (`MCPMethod.shutdown`) are removed; `ping`
  returns `{}`.
- **`tools/call` runs exactly the named tool, or fails.** Tools are listed as
  `<providerId>__<toolName>` (`MCPToolNaming.aggregate`) or, with
  `MCPServerConfig.toolNaming = .provider(id)` / `serve --provider`, one provider's
  tools under their upstream names. An unlisted name is a JSON-RPC `-32602` error;
  without a wired runtime a call is a JSON-RPC error (it used to answer
  `status: ok` with a "runtime dispatch pending" note); a tool that throws is an
  `isError` result. Results are MCP `CallToolResult`s (`content`,
  `structuredContent` for JSON objects, `isError`, `_meta["dev.smallchat/toolId"]`)
  instead of `{invocationId, status, result}`. Tool names no longer go through
  semantic resolution: that is the opt-in `smallchat_dispatch` meta-tool
  (`MCPServerConfig.semanticDispatch`, `serve --semantic-dispatch`).
  `MCPRouter.setRefinementHandler` is replaced by `setToolExecutor(_:)` and
  `setSemanticDispatchHandler(_:)`; `MCPRouter.init` no longer takes an
  `SSEBroker`.
- **OAuth is removed; `--auth` means a bearer token.** `OAuthManager`, `OAuthToken`,
  `OAuthClient`, `MCPScope`, `PermissionsConfig` and `MCPServerConfig.enableAuth`
  are gone. Nothing could register a client from the CLI, so `serve --auth`
  rejected every request; scopes were never enforced; client secrets were stored
  as unsalted SHA-256 (the README said PBKDF2). `MCPServerConfig.authToken`
  requires `Authorization: Bearer <token>` on every request except `GET /health`.
  `serve --auth` reads the token from `SMALLCHAT_MCP_TOKEN` or `--auth-token-file`
  (default `~/.smallchat/serve-token`, created with a random token, mode 0600).
- **`AuditLog` requires a key and hashes every field.** `AuditLog(hmacKey:)` takes
  a non-empty key (the built-in default key was public, so anyone could forge a
  valid chain); `MCPServer` uses `MCPServerConfig.auditKey` or a random key. The
  chain now covers `clientId` and `error` too, so chain heads differ from 0.6.x.
- **`ToolProxy.execute` throws `ToolNotExecutableError`** unless the proxy was
  created with an `executor`. It used to return `{"status": "executed"}` without
  running anything. Compiler-built proxies have no executor.
- **`MCPClientTransport.execute` returns the upstream `CallToolResult`** for MCP
  tools (content is the whole result object, flagged with
  `mcpCallToolResultMetadataKey`), not just its `content` array.
- **`SmallChatMCP` depends on `SmallChatCompiler` and `SmallChatEmbedding`**, so it
  can compile manifests into a runnable toolkit (`MCPToolkit`).
- **The channel bridge moved to `SmallChatChannel`.** `ChannelBridgeServer`,
  `ChannelBridgeProtocol`, `ChannelBridgeResponse` and `ChannelInboundEvent` were in
  `SmallChatAgents`; `SmallChatAgents` now depends on `SmallChatChannel`, so code
  that imports either module (or the `SmallChat` umbrella) still sees them.
  `ChannelBridgeProtocol.constantTimeEqual` is public.
- **`serializeChannelTag` XML-escapes `&`, `<` and `>` in the content.** It used to
  escape only a blocklist of tag names, so content could close `</channel>` and open
  a forged `<channel source="trusted-admin">`. Content containing those characters
  now renders as entities (`&lt;b&gt;`, not `<b>` or a blocklist-escaped tag).
- **`ChannelServer.shutdown()` is `async`** (it also stops the HTTP bridge).
- **`smallchat channel --http-bridge` requires `SMALLCHAT_CHANNEL_SECRET`**, and the
  channel server negotiates its protocol version (it always answered `2024-11-05`):
  it echoes `2025-11-25`, `2025-06-18` or `2024-11-05` and offers `2025-11-25`
  otherwise.
- **The messenger's switchboard protocol is nonce-framed.**
  `SwitchboardProtocol.systemPrompt(name:nonce:)`,
  `relayCommand(ticket:to:cwd:body:nonce:)` and `parse(_:nonce:)` replace the
  versions without a nonce; `makeNonce()` and `listCommand(nonce:)` are new, and
  `Switchboard.init` takes an optional `nonce` (for tests). `parse` ignores every
  line that doesn't carry the nonce.
- **`claude` launches keep text off the command line and need a current Claude
  Code CLI.** `ClaudeCommand` invocations use `--input-format stream-json` and carry
  the prompt in the new `ClaudeInvocation.prompt` (written to stdin) and system
  prompts in `ClaudeInvocation.appendSystemPrompt` (passed with
  `--append-system-prompt-file`); `arguments` no longer contain either. The
  switchboard and stenographer sessions add `--tools`, `--strict-mcp-config` and
  `--setting-sources user`, so the `claude` binary must support those flags.
- **`AgentTransport` requires `shutdown()`.** Conforming types must implement it
  (stop any process they keep running); `MessengerModel.setTransport(_:)` calls it
  on the transport it replaces.
- **A running session is never resumed.** `ClaudeCodeTransport.send` to a live
  session whose Claude Code name isn't known fails with the new
  `AgentTransportError.liveSessionUnnamed` instead of starting `claude -p --resume`
  on it.
- **The switchboard runs in its own directory**,
  `<Application Support>/SmallChat/switchboard`
  (`ClaudeCodeTransport.Configuration.switchboardDirectory`), not your home
  directory.
- **The messenger keeps two secrets, outside `messenger.json`.**
  `MessengerSettings.objectionChannelSecret` is removed. `MessengerModel.channelSecret`
  authenticates stenographer to the objection-channel bridge
  (`SMALLCHAT_CHANNEL_SECRET`) and the new `MessengerModel.notarySecret` authenticates
  the messenger's notarize and dismiss calls (`X-Notary-Secret`,
  `STENOGRAPHER_NOTARY_SECRET`). Both live in `MessengerStore.secrets`, a
  `MessengerSecretStore`: the Keychain on macOS (`KeychainSecretStore`), 0600 files
  in a 0700 directory elsewhere (`FileSecretStore`), or `InMemorySecretStore` for a
  store without a file. `MessengerStore.init(url:secrets:)` picks the platform's
  store when `secrets` is nil. Both secrets are generated anew on the first 1.0
  launch, and the old one is removed from `messenger.json`.
- **`MessengerModel` saves in the background.** Changes are written within
  `persistDelay` (500 ms) of the first one, and when the app quits, instead of
  before each mutating call returns. Call `await model.flushPersistence()` before
  reading `messenger.json` or loading a second model from the same store.
  `messenger.json` is written without pretty-printing.
- **Notarize URLs come only from the messenger's settings.**
  `PendingProposal.notarizeURL` is removed and `NotaryClient.parseInbox(_:)` no
  longer takes `restBase`. `NotaryClient.notarizeURL(restBase:proposalId:)` returns
  nil for an id other than letters, digits, `-` and `_`
  (`NotaryClient.isValidProposalId(_:)`); such proposals are not queued.

### Fixed

- **Builds with Swift 6.2+ (Xcode 26, and Swift 6.3/6.4 on Linux).** `HTTPTransport`,
  `LocalTransport`, `MCPSSETransport`, `MCPStdioTransport` and `RtkTransport`
  each bumped a nonisolated `static var counter` to mint their ids, which newer
  compilers reject as global mutable state. It was also a data race: transports
  created concurrently could get the same id (which names their circuit
  breaker). Ids now come from a lock-protected `TransportIDSequence`.
- **Transport, MCP, Channel, the `SmallChat` umbrella and the CLI build and
  pass their tests on Linux.** `FoundationNetworking` is imported where
  `URLSession` is used; `URLSession.streamingBytes(for:)` replaces
  `bytes(for:)`, which swift-corelibs-foundation lacks, with a delegate that
  yields body chunks as they arrive (SSE and NDJSON keep streaming); OAuth
  tokens come from `SystemRandomNumberGenerator` instead of `SecRandomCopyBytes`
  (whose failure was ignored), and SHA-256/HMAC come from swift-crypto.
- **Library products compile for iOS** (checked by the new iOS CI job).
  Besides the subprocess guards above, Dream reads `NSHomeDirectory()`
  instead of the macOS-only `FileManager.homeDirectoryForCurrentUser`.
  `SmallChatAgents` stays macOS/Linux only, and the README's platform table
  now says so.
- **Added the MIT `LICENSE` file** the README badge has always linked to.
- **Timeouts fire on time.** `TimeoutMiddleware` raced the operation in a task
  group, so when the deadline passed it still waited for an operation that
  ignored cancellation (every continuation-based transport call did): stdio MCP
  calls and the rtk filter hung past their timeouts. The new
  `withTimeout(seconds:_:)`, which `TimeoutMiddleware` now uses, resumes exactly
  once, cancels the operation and returns at once.
- **`MCPStdioTransport` no longer corrupts or loses output, and never hangs on a
  dead server.** stdout is read as bytes on its own thread and split into lines
  before UTF-8 decoding, in order; each pipe read used to be decoded on its own,
  so a read ending inside a multibyte character was dropped (a 210 KB result of
  "€" arrived as 4,464 characters) and chunks were handed on through unordered
  tasks. A call that times out or whose task is cancelled is removed and the
  server is sent `notifications/cancelled`. A server that exits, closes stdout
  or stops reading stdin fails every pending call with its stderr tail (calls
  used to wait forever). stderr is drained, so a chatty server cannot block.
  Writes no longer crash the process on a broken pipe (Linux `FileHandle.write`
  traps on `EPIPE`, and SIGPIPE killed the process); concurrent first calls
  start one server, not two; the server's `ping` requests are answered.
- **The MCP server no longer crashes on every request.** Request handling ran in a
  Swift task and wrote to `ChannelHandlerContext` from there, off its event loop:
  NIO's precondition killed debug builds (`smallchat serve`, the app's Server
  panel) on the first request, and release builds raced on the pipeline. Work
  still runs in tasks; every write hops back to the connection's event loop.
  Tests now send real HTTP requests.
- **`smallchat serve` runs tools.** It never wired a runtime, and the compiler's
  `ToolProxy` faked execution anyway. `serve` (and `MCPServer.start()` with a
  `sourcePath`) now loads manifests or an artifact with `MCPToolkit`, whose
  `EndpointToolIMP`s call each provider's manifest `endpoint`: MCP servers over
  Streamable HTTP, REST APIs as `POST <endpoint>/<tool>`. `compile` and
  `buildArtifact` record each tool's description, input schema and provider
  endpoint (schemas used to be looked up by tool name alone, so two providers
  sharing a tool name got the same schema).
- **The MCP perimeter matches TypeScript #85.** Rate limiting is keyed by the
  client's address (it used the client-chosen `Mcp-Session-Id`, so a fresh id per
  request was never throttled); sessions are validated; `maxConnections` is
  enforced (it was never read).
- **The audit log verifies after eviction.** `verifyChain()` started from the zero
  hash, so it reported tampering on every log that had evicted an entry.
- **`MCPClientTransport` works with Streamable HTTP servers**: it initializes
  lazily, sends `Accept`, `Mcp-Session-Id` and `MCP-Protocol-Version`, reads
  responses sent as SSE, re-initializes once when the server drops the session,
  and ends sessions with `terminateSession()`.
- Tool content that is not a string is rendered as JSON (`formatContent` used
  Swift's `String(describing:)`).
- **`smallchat channel --http-bridge` listens.** The flag and the startup banner
  promised an HTTP bridge that was never started, so webhooks and stenographer's
  `--objection-channel` got connection refused. `ChannelServer.startHTTPBridge()`
  now serves `POST /event` (403 when sender gating or the size limit rejects the
  event) and `GET /health`.
- **`smallchat channel` exits when stdin closes.** It waited only for SIGINT, so it
  outlived the Claude Code session that started it. stdin is read on its own
  thread instead of blocking a cooperative-pool thread, and replies already queued
  are written before it exits.
- **`ChannelBridgeProtocol.constantTimeEqual` compares full lengths.** It folded the
  length difference into 8 bits, so a secret followed by 256 NUL bytes matched.
- **The rtk filter no longer deadlocks on large output.** It wrote the whole body
  to stdin before reading stdout, so a filter whose output filled the pipe
  buffer (about 64 KB) blocked forever. stdin is now written while stdout and
  stderr are read, and on `timeoutMs` the process is stopped.
- **A switchboard relay that times out fails.** `Switchboard.relay` raced the
  receipt against a timer whose task returned normally, so when the switchboard
  never answered (rate limit, expired login, crashed turn) the relay returned as if
  delivered and the chat waited for a reply that could not come. It now throws
  `SwitchboardError` ("switchboard timed out"), and a cancelled relay throws too
  instead of leaving its ticket pending.
- **Relayed and inbound text can't forge switchboard protocol.** The switchboard
  copies message bodies verbatim, and the parser trusted any line starting with
  `DELIVERED`, `FAILED`, `AGENT` or `INBOUND`, so a message from another session
  could end its own envelope, open one attributed to a trusted agent, or confirm a
  pending ticket; a relayed body could hold extra `RELAY` commands. Commands,
  receipts, listings and envelopes now carry a random per-switchboard nonce, bodies
  sit between nonce markers, and a message from another session is always passed on
  as inbound text, never run as a command. A body that contains the nonce is not
  relayed. The switchboard is still a model, so this keeps the parser honest; it
  does not make the model immune to instructions in what it relays.
- **Inbound replies are attributed by Claude Code session name only.** A reply
  whose sender matched no session name fell back to the smallchat handle, so a
  session that named itself after an agent's handle was shown as that agent. The
  handle now counts only for a live session whose Claude Code name isn't known yet,
  and a name two sessions share matches nobody (the reply shows as from an unknown
  session).
- **The messenger's own headless sessions are least-privilege.** `--allowedTools`
  only pre-approves tools; it never removed any, so under `dontAsk` the switchboard
  could still use whatever the user's settings allowed (shell patterns, `WebFetch`,
  MCP servers), and the stenographer, which reads untrusted chat transcripts, had
  everything but a short denylist. The switchboard now has exactly `SendMessage` and
  `ListAgents` and runs in an empty directory of its own; the stenographer has
  `Read`, `Grep` and `Glob`, none pre-approved, so it can read the chat's working
  directory and nothing else. Neither loads MCP servers or the working directory's
  project and local settings.
- **Prompts and the ledger brief no longer go through argv.** A first prompt
  starting with `-` (`--help`) was parsed as a flag, a ledger brief over 128 KB
  failed to launch on Linux (`E2BIG`; about 1 MB on macOS), and both were visible to
  every local process in `ps`. Prompts go to stdin as stream-json, and system prompts
  through a 0600 file in a private directory that is removed when `claude` exits.
- **A session is resumed one turn at a time.** Messaging a live session that the
  registry hadn't named started `claude -p --resume` on it next to the running
  process, and two quick messages to a stopped session started two resumes; either
  appended a divergent branch to the same transcript. Live sessions are only ever
  messaged, and headless turns of one session (agent or stenographer) now wait for
  each other.
- **Notarization no longer rides on the channel secret.** The messenger signed its
  notarize and dismiss calls with the objection-channel secret, so anything given
  that secret to post events could also mint tombstones. The secret sat in
  plaintext in `messenger.json`, where an agent's Read tool could reach it, and the
  copyable stenographer command set it inline, so it also landed in shell history.
  The notary secret is now separate, both are kept in the Keychain, and the copied
  command (`npx -y @stenographer/core start …`) reads them with
  `security find-generic-password` when it runs instead of containing them.
- **A channel event can't redirect the notary secret.** The messenger posted
  approvals to whatever `meta.notarize_url` a proposal event named, sending the
  secret along. It now always posts to `http://127.0.0.1:<stenographer REST port>`
  from its settings, and ignores proposal ids that could change the path.
- **The messenger no longer rewrites its store on the main actor for every
  change.** Each message, receipt and stenographer note re-encoded every
  conversation (pretty-printed) and wrote the file synchronously: with a 20,000
  message history one send took about 390 ms and rewrote 13 MB. A burst of changes
  is now one compact write, encoded and written on a background queue.
- **Session rescans read only the transcripts that changed.** The full rescan
  every minute re-read up to 256 KB of every transcript under
  `~/.claude/projects`, and parsing each timestamp built two `ISO8601DateFormatter`s
  (about 250 µs per call on Linux). Summaries are now cached by path, size and
  modification time (`ClaudeSessionScanner.summaryCache`), and dates parse with
  shared `Date.ISO8601FormatStyle` values (about 1 µs).
- **Live activity shows a tool call bigger than the tail window.** When the newest
  transcript line was longer than the 64 KB window (a Write with a large file
  body), no whole line was left and the card went blank. The window now doubles
  until it holds a line, up to 8 MB.
- **Changing the `claude` path stops the old switchboard.** The replaced transport
  was never shut down, so a second switchboard named `smallchat` kept running, and
  agents' replies could reach the one nobody listened to. A switchboard that ended
  also no longer fails the tickets of the one that replaced it, and writes to a
  `claude` that stopped reading its stdin fail instead of raising `SIGPIPE`.

### Added

- **`MCPToolkit`, `EndpointToolIMP`, `MCPToolCatalog`** and `MCPServer.setRuntime(_:semanticDispatch:)`,
  `setToolExecutor(_:)`, `setArtifact(_:)` and `boundPort` (start on port 0 and read
  the port). `serve` gains `--provider`, `--semantic-dispatch`, `--auth-token-file`
  and `--max-connections`.

- **CI on every supported platform.** Besides macOS 15 (Xcode 16.4, Swift
  6.1), CI now builds and tests on the newest Xcode (`macos-26`), builds the
  `SmallChat` scheme for iOS, and builds and tests in `swift:6.1`, `swift:6.3`
  and `swift:6.4` Linux containers.
- **`SmallChatVersion.current`** in `SmallChatCore`: the one place the package
  version is spelled.
- **Live tool activity on agent cards.** `TranscriptActivity` reads the
  tail of each live session's transcript. It pairs `tool_use` with
  `tool_result` by id, skips sidechains, and keeps the in-flight tool, the
  last 5 steps, and the latest prose. The card and the direct-chat header
  stream it; a transcript is only re-read when its size changes.
- **Objection channel.** `ChannelBridgeServer` is a loopback NIO HTTP
  bridge that receives Stenographer's `--objection-channel` posts. It uses
  the TS channel-bridge contract: `POST /event`, `X-Channel-Secret` or
  Bearer auth, and 401/400/404/413 errors. Objections are routed by
  `meta.session_ids` into each agent's direct and group chats, relayed as
  an interrupt into live sessions (a toggle turns relaying off), and
  deduplicated by objection id. The secret is generated on first launch.
- **Authoring tombstones with literals.** `TombstoneDraft` covers claim,
  evidence, literals, and an accountable signer. It signs into a TB that
  `TruthWiki.append` writes to the wiki JSONL, and the app ledger reloads
  so objections to the new literals start at once.
- **Literal validation** in the Swift wiki codec now matches Stenographer's
  write-time rule. A literal without a subject must be a distinctive
  identifier (at least 4 characters, containing a letter); a TB line with
  an invalid literal is rejected with a per-line error.

### Fixed

- Settings saved by an older build now load: `MessengerSettings` decodes
  leniently. Before, adding a setting would have made the whole saved
  store (conversations included) fail to decode.

- **The macOS app is now a messenger for your Claude Code sessions**
  (`SmallChatApp` + new `SmallChatAgents` library). The sidebar lists live
  and recent non-archived sessions. Live status and kind come from Claude
  Code's session registry; title, branch, and recency come from transcripts.
  Each session gets a durable, renamable handle such as `@instrument-62`.
  - **Direct chats.** A live session receives messages through Claude Code
    inter-agent messaging, via a headless *switchboard* session limited to
    `SendMessage`/`ListAgents`. A stopped session is resumed headlessly.
  - **Group chats.** Messages fan out to every agent, or only to the agents
    you `@mention`. Agent replies land private to you, with **Share with
    group**, which delivers the reply to the other agents as an
    inter-agent interrupt, and **Keep private**.
  - **Stenographer.** Every chat has a stenographer preloaded from the
    wiki's TB/UV ledger. It objects to tombstoned literals and flags
    reliance on open UVs (notes visible only to you), and answers
    `@stenographer` questions through a headless session briefed with the
    ledger.
  - The existing tool panels moved under **Toolkit**.
- **`TruthObjections`** (`SmallChatTruth`): Swift port of Stenographer's
  real-time objection detector (tombstoned-literal matching, §12).
  `TruthTbEntry` now carries `literals`, and the wiki codec round-trips
  them. Previously they were dropped on parse.
- macOS CI workflow (`swift build` + `swift test`).

- **`SmallChatTruth` — truth-ledger interop (Stenographer TB/UV v2, JSONL seam).**
  Ports the TS `@shorthand/core/truth` module: `TruthWiki.parse`/`serialize`
  read and write the ledger's append-only wiki JSONL losslessly (the
  `x-steno` namespace is preserved opaquely via a `JSONValue` tree; explicit
  `signedBy`/`contests` nulls match the wire format; the round-trip is
  tested), later lines for an id supersede earlier ones, and per-line parse
  errors never poison the rest of the file. `TruthWiki.classify`/
  `selectCurrentTruth` enforce the §7 consumption rules: active TBs are
  ground truth, contested TBs carry their live contesting UVs, open UVs are
  flagged `[UV — UNVERIFIED]` and never render as proven, and
  overridden/refuted history is excluded. `TruthCompaction` projects the
  selection into compaction corpus items and L4-shaped invariant records
  with the confidence type riding along in the value (two axes, not one),
  and `TruthInvariants.preserved(_:)` is a stock `CompactionVerifier`
  invariant that fails any compaction which drops a truth item or strips
  the UNVERIFIED marker. `InvariantProposal`/`TruthProposals` implement the
  proposal-only write path — `PROPOSAL(kind: "uv")` JSONL with
  `targetRef`-based dedup — and reject anonymous/generic identities
  (`system`, `assistant`, …) at init, mirroring stenographer's authorship
  floor. 11 new tests.

### Fixed

- **Linux build: guarded the remaining bare `import os` statements.** Six
  `SmallChatCore` files (`IntentPinRegistry`, `SelectorNamespace`,
  `ToolProxy`, and the `SCObject` family) imported Apple's `os` module
  unconditionally, breaking non-Apple builds even though the package
  already ships a `PlatformLock` shim behind `#if !canImport(os)`. All
  `import os` statements now carry the same `#if canImport(os)` guard the
  rest of the package uses; `SmallChatTruth` and its dependency chain
  (`Core → Shorthand → Compaction`) now build and pass tests on Linux
  (Swift 6.1).

Work toward a 1:1 ABI with the TypeScript `@smallchat/core` reference. ABI is
defined as **semantic interchange**: identical selectors, dispatch tables, and
resolution results, with embedding-vector components equal within Float32 epsilon
(the Swift pipeline is Float32; the TS pipeline is Float64, so low-order JSON
digits of stored vectors may differ — the one documented exception).

### Changed

- **`LocalEmbedder` is now byte/Float32-compatible with the TS reference**
  (`src/embedding/local-embedder.ts`). The previous implementation hashed UTF-8
  bytes with Unicode-aware tokenization and could trap on an `Int32.min` hash;
  it now hashes **UTF-16 code units** (`charCodeAt`), tokenizes with the TS ASCII
  rule `toLowerCase().replace(/[^a-z0-9\s]/g,'')`, and reproduces the reference's
  lossy `(hash * 0x01000193) | 0` fold via an exact double-multiply + ECMAScript
  `ToInt32`. Verified against the verbatim JS algorithm across ASCII, non-ASCII,
  trigram, overflow, and empty inputs (max component diff ~6e-08). Added
  `LocalEmbedderParityTests` with golden vectors.
- **Compiled artifact now emits format version `0.5.0`** (`ARTIFACT_FORMAT_VERSION`)
  to match the TS artifact ABI, replacing the previous hardcoded `0.1.0`. Loading
  remains version-agnostic, so older 0.1.0/0.3.0 artifacts still decode.

### Added (cross-platform build)

- Conditional `#if canImport(os)` / `#if canImport(Accelerate)` guards and a
  portable `OSAllocatedUnfairLock` shim (`Compat/PlatformLock.swift`) plus scalar
  `cosineSimilarity` / `l2Normalize` fallbacks, so the ABI-critical core and
  embedding modules can compile and unit-test off-Apple platforms. macOS/iOS
  behavior is unchanged (the platform `os`/`Accelerate` paths are restored when
  available).

## [0.6.0] - 2026-05-06

This release adds the App/UI layer, matching the TypeScript 0.6.0 feature set.
Apps are first-class dispatch targets that expose HTML UI content via `ui://`
URIs through the MCP `resources/read` endpoint. A new `SmallChatUI` library
wraps `WKWebView` with sandboxed navigation for macOS/iOS app surfaces.

### Added

#### App/UI layer (`SmallChatCore`)

- `ComponentSelector` — selector for UI components; parallel to `ToolSelector` with equality/hashing on `canonical`.
- `AppManifest` + `ComponentDefinition` — manifest type carrying `uiResourceUri` (inline HTML or `file://` path).
- `AppArtifact` + `AppClassData` — serialized compilation output for the App layer (embedded HTML, URI map, per-app dispatch table data).
- `UIDispatchResult` — `resolved(appId:uri:content:)` / `notFound` enum; never thrown, enabling graceful-null dispatch.
- `AppClass` — `@unchecked Sendable` class mirroring `ToolClass` with `OSAllocatedUnfairLock`-protected dispatch table, ISA chain traversal, and `loadExtension(_:)` support.
- `ComponentSelectorTable` actor — interning table for component selectors with deduplication (cosine similarity ≥ threshold) and `resolve(intent:)`.
- `ViewCache` actor — LRU cache for resolved views using `OrderedDictionary`; version-tagged entries auto-expire on `appVersion` or `contentFingerprint` mismatch.
- `CompilationResult.appArtifact: AppArtifact?` — new field with `nil` default; zero impact on existing call sites.

#### App compiler (`SmallChatCompiler`)

- `AppCompiler` struct — 4-phase pipeline (PARSE → EMBED → LINK → EMIT) mirroring `ToolCompiler`; resolves inline HTML from `uiResourceUri`, deduplicates components via `ComponentSelectorTable`, emits `AppArtifact`.

#### App runtime (`SmallChatRuntime`)

- `AppRuntime` actor — parallel to `ToolRuntime`; `uiDispatch(intent:args:) async -> UIDispatchResult` (never throws), `uiDispatchStream` emitting `.resolving → .toolStart → .chunk → .done` `DispatchEvent` sequence.

#### MCP App registration (`SmallChatMCP`)

- `AppResourceHandler` — implements `ResourceHandler`; serves embedded HTML under `ui://` URIs with MIME type `text/html;profile=mcp-app`.
- `MCPServer.registerApp(tool:uiUri:uiContent:)` extension — wires `AppResourceHandler` into the existing `ResourceRegistry` so `resources/read` on a `ui://` URI returns the HTML blob.

#### SmallChatUI library (new SPM target)

- `AppWebView` — SwiftUI view wrapping `WKWebView`; loads HTML content via `loadHTMLString(_:baseURL:)`.
- `AppWebViewConfiguration` — factory producing a sandboxed `WKWebViewConfiguration` + `AppWebViewSandbox`; injects CSP `<meta>` via `WKUserScript`; one `WKProcessPool` per view (process isolation).
- `AppWebViewSandbox` — `WKNavigationDelegate` enforcing same-origin navigation; exposes `static func shouldAllow(url:allowedURI:) -> Bool` for unit testing without `WKWebView`.
- `AppViewState` — `@MainActor @ObservableObject` carrying `isLoading`, `loadError`, `currentURI`.

#### GUI (SmallChatApp)

- `AppsView` — new sidebar panel listing registered apps and previewing their `AppWebView` inline.
- Added `.apps` case to `AppSection`; routed in `ContentView`.
- `AppState.appRuntime`, `.registeredApps`, `.previewedAppURI`, `.previewedAppContent` state properties.

#### Tests

- `SmallChatCoreTests/ComponentSelectorTests.swift` — intern deduplication, resolve by intent.
- `SmallChatCoreTests/AppClassTests.swift` — dispatch table, ISA chain traversal, extension loading.
- `SmallChatCoreTests/ViewCacheTests.swift` — LRU eviction, version tagging, `flushApp`.
- `SmallChatCompilerTests/AppCompilerTests.swift` — parse `uiResourceUri`, embed, link, emit artifact, integration smoke test.
- `SmallChatRuntimeTests/AppRuntimeTests.swift` — `uiDispatch` graceful-null contract, stream event sequence.
- `SmallChatMCPTests/AppResourceHandlerTests.swift` — `registerApp` → `resources/read` round-trip returns `text/html;profile=mcp-app`.
- `SmallChatUITests/AppWebViewTests.swift` — `AppWebViewConfiguration`, `AppWebViewSandbox.shouldAllow`, `AppViewState` initial values.

### Changed

- Version bumped to `0.6.0` across CLI, MCP server, Compiler artifact, Memex, Dream, and GUI emit paths.
- `Package.swift` — added `SmallChatUI` library product + target, `SmallChatUITests` test target; `SmallChatApp` and `SmallChat` umbrella now depend on `SmallChatUI`.

---

## [0.5.0] - 2026-05-01

This release closes the parity gap to the TypeScript main branch
(`@smallchat/core` 0.4.0 plus the post-0.4.0 unreleased work) and adds
the new `muhnehh/loom-mcp` server as a first-class compile target.

The cumulative diff against 0.3.0 is large enough to ship in six phases;
each phase is a self-contained commit on the release branch and has its
own dedicated section in `docs/0.5.0-roadmap.md`.

### Added

#### Confidence-tiered dispatch (mirrors TS PR #54)

- `DispatchTier` (`EXACT / HIGH / MEDIUM / LOW / NONE`) and `DispatchConfig`
  in `SmallChatCore` with tunable per-tier thresholds, ambiguity-gap
  downgrade, and an opt-in `strict` mode.
- `ResolutionProof` + `ResolutionStep` + `ProofTimer` for replayable
  per-step traces with microsecond timing.
- `ToolRefinement` carrying the canonical `tool_refinement_needed`
  MCP wire constant.
- `LLMClient` protocol + `NoOpLLMClient` default in `SmallChatRuntime`.
- `Verification` -- pre-flight `respondsToSelector:` with three
  progressive strategies (schema validation, keyword overlap, optional
  LLM verification).
- `Decomposition` -- rule-based intent splitting on natural conjunctions
  with LLM fallback.
- `Refinement` -- builds the `ToolRefinement` payload from the resolution
  candidates and proof trace.
- `DispatchObserver` -- KVO-style actor that adapts per-tool-class
  thresholds upward after corrections.
- `tieredDispatch` -- new entry point that runs the existing resolver
  and routes through verify / decompose / refine based on tier.

#### loom-mcp integration (mirrors TS PR #61)

- `examples/loom-mcp-manifest.json` -- the full 28-tool catalogue with
  `selectorHint`, `aliases`, and provider `semanticContext`.
- `ProviderManifest` and `ToolDefinition` gain `description` and
  `compilerHints` fields. `parseMCPManifest` honors
  `compilerHints.exclude`.
- `ParsedTool.embeddingText` folds the hints into the embedder input so
  natural-language phrases route to the right tool.
- `LoomMCPClient` (in `SmallChatTransport`) -- thin actor wrapping
  `MCPStdioTransport` pre-configured for `npx -y @loom-mcp/server`.
  Adds `listTools`, `toolNames`, `missingTools`, `call`, and a
  `LoomDetection.probe()` PATH check.

#### Registry / Bundle / Install (mirrors TS PR #52)

- `Registry.swift` in `SmallChatCore`: `InstallMethod`,
  `RegistryEnvVar`, `RegistryArg`, `RegistryEntry`, `RegistryIndex`,
  `RegistryIndexEntry`, `SmallChatBundle`, `SmallChatBundle.TargetClient`,
  `InstallPlan`, `InstallStep`.
- `examples/registry/` -- four registry entries (GitHub, Slack,
  PostgreSQL, loom), an index, and a code-review bundle stitched with
  Claude Code and Cursor target-client snippets.
- `smallchat install <path> [--json]` -- dry-run install plan renderer.

#### Five new module targets

- `SmallChatShorthand` (PR #58) -- token / sentence primitives, Jaccard,
  cosine, FNV-1a content hash. Dependency-free; pulled in by Importance,
  CRDT, Compaction, and Memex.
- `SmallChatImportance` (PR #55) -- three-signal detector (recency
  exponential decay, centrality via co-mention Jaccard, novelty as
  `1 - max similarity`) with weighted normalised score and `rank()`.
- `SmallChatCRDT` (PR #56) -- `VectorClock`, `LWWMap`, `ORSet`,
  `GCounter`. All four expose deterministic `merge` that is
  commutative, idempotent, and associative.
- `SmallChatCompaction` (PR #57) -- `CompactionVerifier` with three
  strategies (deterministic resampling, conservative literal-negation
  contradiction detection, caller-supplied diff invariants) plus stock
  `minimumRetention` and `noNewIds` invariants.
- `SmallChatMemex` (PR #60) -- knowledge-base compiler with the same
  five-stage pipeline (`READ → EXTRACT → EMBED → LINK → EMIT`) as
  `ToolCompiler`. Includes `KnowledgeSource`, `ExtractedClaim`,
  `ExtractedEntity`, `ExtractedRelationship`, `WikiPage`,
  `KnowledgeBase`, and `MemexResolver`. New CLI suite:
  `smallchat memex {compile, query, lint, inspect, export}`.

#### CLI

- `smallchat compile --strict` -- raise dedup / collision thresholds
  and treat collisions as compile errors (exit code 2).
- `smallchat install <path>` -- render an `InstallPlan` for a registry
  entry or bundle.
- `smallchat memex` subcommand suite.
- `smallchat setup` now probes for the loom-mcp launcher and reports
  the bundled manifest's tool count.

#### GUI (`SmallChatApp`)

- `TierBadge` -- inline tier visualizer (green / mint / yellow / orange
  / red).
- `RefinementView` -- new section showing the latest `ToolRefinement`
  payload: original intent + tier badge, reason, clarifying questions,
  near-match candidates, and the proof trace.
- `LoomStatus` -- compact panel in `DiscoveryView` showing detection
  state, bundled and live tool counts, and the default launch command.
- `AppState` carries `lastResolverTier`, `lastResolverConfidence`,
  `lastRefinement`, `loomDetection`, `loomLiveToolCount`.

### Changed

- Default vector-search threshold lowered from 0.75 to 0.60. Tier
  classification handles the additional candidate noise downstream.
- `DispatchContext` carries a `dispatchConfig: DispatchConfig`.
  `RuntimeOptions.dispatchConfig` is threaded through to the context.
  `resolveToolIMP` now reads its threshold from the context's config.
- `MCPRouter.handleToolsCall` is now `async` and surfaces
  `tool_refinement_needed` results via `setRefinementHandler(_:)`.
- Version reporting bumped to 0.5.0 across all CLI commands, the MCP
  server (`mcpServerVersion`, `RouterOptions.serverVersion`),
  compile / dream / setup / init artifact metadata, and the macOS GUI
  artifact emit.
- README rewritten with a "What's New in 0.5.0" section and updated
  ASCII pipeline diagram.

### Notes

- The `tools/call` MCP placeholder still echoes a placeholder response
  unless a runtime hook is wired via `setRefinementHandler`. Full
  end-to-end runtime dispatch through the router is held for a 0.5.x
  follow-on.
- Several Phase 4 modules carry deliberately conservative algorithms
  (literal-negation contradiction detection, capitalised-noun entity
  surfacing). They match the TS shapes; richer semantic implementations
  can land iteratively without changing the surface.

## [0.3.0] - 2026-04-13

Backfilled. Released as `dcce3df`.

### Added

- Security hardening: intent validation, token sanitization, sender-gate
  identity validation with constant-time pairing-code comparison, MCP
  audit log with HMAC chain-hash entries, OAuth 2.1 + bearer auth,
  semantic rate limiting against vector flooding.
- TLS configuration on transports (`v0.3.0`).
- macOS SwiftUI GUI application (`SmallChatApp`) with sections for
  Compiler, Server, Manifest editor, Inspector, Resolver, Discovery,
  and Doctor.
- Server metrics actor and live monitoring.
- `SmallChatDream` module (artifact versioning, log analysis).

### Changed

- Vector-search threshold raised from earlier values to 0.75.
- MCP protocol version pinned to `2024-11-05`.

## [0.2.0] - 2026-03-26

Initial public release of the Swift port of smallchat. Mirrors the
TypeScript 0.2.0 surface (Claude Code channel protocol, intent pinning,
selector namespacing, worker-thread embeddings, fluent SDK API).
