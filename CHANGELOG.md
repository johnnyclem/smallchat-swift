# Changelog

All notable changes to the Swift port of smallchat are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - Unreleased

The first tagged release. The `1.0.0` tag is created when this release is
published; no earlier version was tagged.

1.0 follows @smallchat/core 1.0's dispatch rules and artifact format and runs its
conformance vectors (`Tests/Fixtures/spec`), reads Stenographer's truth format v2
and runs its golden fixtures (`Tests/Fixtures/truth-format`), and builds and tests
on macOS and Linux (the libraries also build for iOS). It also brings the agent
messenger (`SmallChatApp` + `SmallChatAgents`) and `SmallChatTruth`, which landed
after 0.6.0. Ids in parentheses (SC-SW-*, XSUITE-*) refer to the findings of the
pre-1.0 audit of the smallchat suite.

### Breaking

See [`MIGRATION.md`](MIGRATION.md) for how to update.

#### Toolchains and platforms

- **Swift 6.1 is the toolchain floor.** The manifest is now
  `swift-tools-version: 6.1`; Swift 6.0 was never tested and is no longer
  accepted.
- **Linux no longer exports `OSAllocatedUnfairLock`.** The Linux shim in
  `SmallChatCore/Compat` was a public type named after Apple's lock, so any
  module importing SmallChatCore saw it shadow the platform name. It is now
  the package-scoped `PlatformLock` (a typealias for `OSAllocatedUnfairLock`
  on Apple platforms), `Sendable` only when its state is, with Apple's
  `@Sendable` requirements on `withLock`.
- **Subprocess APIs are macOS/Linux only (SC-SW-12).** `MCPStdioTransport`,
  `LoomMCPClient`, `ContainerSandbox.spawnProcess(...)` and
  `ContainerSandbox.isDockerAvailable()` are no longer compiled for iOS (iOS
  has no `Foundation.Process`, so these never built there). On iOS the
  `rtk filter` subprocess is skipped and `RtkTransport` passes bodies through.
- **`SmallChatUI` and `SmallChatApp` are declared only on Apple hosts
  (SC-SW-26)**, and the `SmallChat` umbrella re-exports `SmallChatUI` only on
  macOS and iOS.
- **New dependency on Linux: [swift-crypto](https://github.com/apple/swift-crypto)**
  (`3.0.0..<6.0.0`), linked only on Linux, where CryptoKit does not exist.
- **Linux uses real SHA-256 for audit-log HMACs and Dream artifact hashes.**
  Without CryptoKit, `AuditLog` fell back to an FNV hash and Dream's artifact
  versioning to djb2. Both now use swift-crypto's `HMAC<SHA256>`/`SHA256`, the
  same values Apple platforms produce, so Linux chain heads and recorded artifact
  hashes differ from those of earlier Linux builds.

#### Versions

- **Every version string is `SmallChatVersion.current` (`1.0.0`) (SC-SW-37).**
  MCP `serverInfo.version` was `0.6.0`, the channel server's was `0.3.0`, the MCP
  clients sent `clientInfo.version` `0.1.0`, the REPL banner said `0.5.0`, and
  `smallchat --version` and the `version` field of generated configs, toolkit
  files and knowledge bases said `0.6.0`. The compiled-artifact format version
  (`ARTIFACT_FORMAT_VERSION`) is separate; it is now `1.0` (see below).

#### Dispatch

- **Dispatch follows @smallchat/core 1.0: resolving and running are separate.**
  `resolve(_:options:)` (on `ToolRuntime` and `DispatchContext`; also
  `resolveIntent(context:intent:options:)`) returns a `Resolution` and runs nothing:
  outcome `resolved`, `needs-disambiguation`, `unresolved` or `throttled`, the tier,
  the chosen canonical tool id (`<providerId>/<toolName>`, see `makeToolId`), the
  ranked candidates and a `ResolutionProof`. `dispatchById(_:args:options:)`
  validates the arguments and runs exactly the named tool.
  `dispatch(_:args:options:)` by intent resolves (with the cache) and then runs the
  chosen tool through `dispatchById`; when resolution does not settle on one tool,
  nothing runs and the result is `isError` with `metadata["outcome"]` and a
  `ToolRefinement` whose near matches carry tool ids (`DispatchOutcomeCode`,
  `DispatchMetadataKey`). `tieredDispatch`, `TieredDispatchResult`,
  `StrictAmbiguityError`, `DispatchContext.forward` and the fallback chain types
  (`FallbackStep`, `FallbackStrategy`, `FallbackResult`, `FallbackChainResult`) are
  removed: no broadened search or forwarding step runs a tool the intent did not
  resolve to. `DispatchBuilder.execContent()` throws the new `DispatchError`
  for an `isError` result instead of returning the error payload.
- **One dispatch policy on every path (SC-SW-04, SC-SW-25)** (`evaluateDispatchPolicy`,
  `DispatchPolicyOptions`): pinned phrases, cache hits, vector and overload matches,
  protocol conformance and decomposed sub-intents are all judged by it, and a denial
  is needs-disambiguation, never a fallback. Below HIGH (MEDIUM, LOW) a tool runs
  only after an LLM verifier approves it (`DispatchConfig.requireLLMForSubHighDispatch`,
  default on; `LLMClient.providesVerification`, false for `NoOpLLMClient`), so with
  no LLM client a MEDIUM or LOW match is never run by intent. A destructive tool
  (`ToolIMP.annotations`, `isDestructive`) runs by intent only from a pinned phrase
  or an EXACT similarity computed from the intent's own embedding.
  `DispatchConfig.strict` verifies below EXACT and raises the candidate floor to
  MEDIUM. `ToolIMP` has a new `annotations` requirement (default `nil`), and
  `ToolProxy.init` takes `annotations:`.
- **Tier thresholds and ranking match @smallchat/core 1.0 (SC-SW-15).** `DispatchConfig`
  holds `thresholds: TierThresholds` (EXACT 0.95, HIGH 0.85, MEDIUM 0.75, LOW 0.60;
  `exactThreshold`… are computed from it), `strict`,
  `requireLLMForSubHighDispatch`, `treatUnannotatedAsDestructive`,
  `maxDecompositionDepth` and `maxSubDispatches`. `vectorSearchThreshold`,
  `ambiguityGap`, `enableVerification`, `enableDecomposition`, `enableRefinement` and
  the `runnerUp:` parameter of `tier(for:)` are removed, and with them the Swift-only
  downgrade of a match whose runner-up was close. Scores are quantized to 1e-4
  (`quantizeScore`) and ties ordered by tool id (`rankedBefore`).
- **Intents are never interned and identity keys are exact (SC-SW-15).**
  `SelectorTable.resolve` returns a selector with the intent's own vector and no
  longer keeps an intent cache (`cachedIntentCount` is gone); `SelectorTable.init`
  no longer takes a rate limiter. `canonicalize` is display-only and follows 1.0
  (punctuation deleted, the 32-token cap `maxCanonicalTokens` removed); the
  resolution cache is keyed by `intentKey(_:)`, and intent pins compare whole
  phrases with `normalizePinPhrase(_:)` (`IntentPinRegistry.checkExact` takes the
  raw intent, so "do not transfer funds" no longer matches a pin on
  "transfer funds").
- **The semantic rate limiter is opt-in and per principal.** It runs only when
  `RuntimeOptions.rateLimiter` is set, keeps a window per principal
  (`ResolveOptions.principal`, `DispatchOptions.principal`), and a refusal is the
  `throttled` outcome with `retryAfterMs` instead of an error.
  `ResolutionCache.rateLimiter` is removed, and `SemanticRateLimiter`'s
  `check`/`record`/`checkSimilarity`/`getMetrics`/`reset` take a principal.
- **`ResolutionProof` is the 1.0 proof** (`version`, `intent`, `outcome`,
  `decision`, `tier`, `chosen`, `confidence`, `ran`, `callDigest`,
  `resolutionDigest`, `candidates`, `thresholds`, `guards`, `embedder`,
  `artifactHash`, `steps`, `timings`, `proofDigest`) instead of a list of
  `ResolutionStep`s; `proofDigest` is a SHA-256 over everything but `timings`.
  `ResolutionStep` is removed and `finalTier` is deprecated (use `tier`).
  `verifyCandidate` is replaced by `verify(_:intent:args:llm:options:)` returning a
  `VerificationResult`, and `LLMClient` has a `providesVerification` requirement
  (default true).
- **Every call is validated against the tool's `inputSchema` before it runs.**
  `dispatchById`, intent dispatch and MCP `tools/call` refuse arguments that fail
  the schema (outcome `invalid-arguments` with `ValidationError`s; nothing runs). The
  validator (`JSONSchemaValidator`) supports drafts 2020-12, 2019-09 and 07 and
  refuses, rather than ignores, a schema it cannot evaluate (`unevaluated*`,
  `$dynamicRef`, remote `$ref`, unknown `$schema`), so a tool with such a schema
  cannot be called. `JSONSchemaType` now keeps every keyword it decodes
  (`keywords`, `init(json:)`, `jsonValue`); a schema without `type` decodes with
  `type == ""`.
- **`ToolProxy.execute` throws `ToolNotExecutableError` (SC-SW-03)** unless the
  proxy was created with an `executor`. It used to return `{"status": "executed"}`
  without running anything. Compiler-built proxies have no executor.
- **Registry changes reach dispatches already in flight (SW-REV-02).** Once
  `registerClass`, `unregisterClass` or `reindex` (and so `swizzle`, `addOverload`
  and `loadCategory`) returns, `dispatch` and `dispatchById` never start a tool the
  index no longer holds: a call whose tool left while it was being resolved or
  validated runs nothing and returns outcome `unresolved`. (The streaming
  variants check from outside the context's actor, so a change that lands in that
  last hop is not seen.) Dispatch uses a cached
  resolution only if it stored it itself under the current
  `DispatchContext.registryGeneration` and the tool is still registered, so an
  entry put in the `ResolutionCache` by other code is a miss.

#### Artifacts, compiler and embedding

- **Artifacts are format 1.0** (`ARTIFACT_FORMAT_VERSION` is `"1.0"` and lives in
  `SmallChatCore`). `compile`, `setup`, the app and Dream write the
  @smallchat/core 1.0 format (`ArtifactV1`: providers with launch specs, tools,
  selectors, collisions, duplicates, the embedder fingerprint and a content hash),
  and every loader reads only 1.0: the file is validated against
  spec/artifact's schema and rules, its content hash is recomputed, and a runtime
  refuses an artifact whose embedder fingerprint differs from its embedder's
  (`EmbedderMismatchError`). A 0.x artifact is refused (`ArtifactVersionError`);
  recompile it. `SerializedArtifact`, `ArtifactStats`, `SelectorData`,
  `DispatchEntry`, `ArtifactIO` and `buildArtifact` are removed; `MCPToolkit`,
  `MCPToolCatalog`, `buildToolList` and `setArtifact` take an `ArtifactV1`.
  `Embedder` has a `fingerprint` requirement (default `nil`; `LocalEmbedder`
  declares `hash`/`smallchat-hash-v1`).
- **The compiler never merges tools.** Each tool keeps its own selector; two
  distinct tools at or above `CompilerOptions.duplicateThreshold` (0.95, was
  `deduplicationThreshold`) are a `DuplicateToolError` unless `allowDuplicates`
  (`compile --allow-duplicates`; `--deduplication-threshold` is now
  `--duplicate-threshold`). Two tools claiming one selector, alias phrase or tool id
  are a `SelectorConflictError`. Aliases are selectors of their own
  (`<canonical>~alias~<alias>`) instead of text appended to the embedding, and a
  tool's embedding text is `<name>: <description>` plus its selector hint, so
  vectors differ from 0.6 artifacts. `mergedCount` is always 0.
- **`LocalEmbedder` computes @smallchat/core's hash-embedder vectors.** It hashes
  UTF-16 code units (`charCodeAt`) instead of UTF-8 bytes, tokenizes with the TS
  ASCII rule `toLowerCase().replace(/[^a-z0-9\s]/g,'')`, reproduces the reference's
  `(hash * 0x01000193) | 0` fold (an exact double multiply plus ECMAScript
  `ToInt32`; the old code could trap on an `Int32.min` hash), and normalizes in
  double precision. `MemoryVectorIndex` computes cosine similarity in double
  precision and orders ties by id. Vectors and scores differ from 0.6's;
  `LocalEmbedderParityTests` and the artifact golden fixture check them.
- **CLI output follows the new runtime.** `resolve` prints the outcome, decision,
  tool id, candidates and proof digest (`--json` prints the proof) and drops
  `--top-k` and `--threshold`; `repl`, `inspect` and `docs` read format 1.0.

#### MCP server and client

- **The MCP server speaks Streamable HTTP on one endpoint, `/mcp` (SC-SW-32).** `POST /`, `POST /rpc`, `GET /sse`, `GET /.well-known/mcp.json` and
  `POST /oauth/token` are gone (`/sse` sent one event and closed; the discovery
  document advertised capabilities the server did not have). `initialize` returns
  the session id in the `Mcp-Session-Id` header only (no longer in the result);
  every other request must send it (`400` without, `404` for an unknown or expired
  session), and `DELETE /mcp` ends a session. Notifications get `202 Accepted`.
  Batches, non-JSON bodies, unsupported `MCP-Protocol-Version` headers,
  non-loopback `Host` names (on a loopback server) and foreign `Origin`s are
  refused.
- **Protocol versions are negotiated honestly (XSUITE-15).** The server offers
  `2025-11-25` and `2025-06-18` (`mcpSupportedProtocolVersions`), echoes a supported
  requested version and otherwise answers with the newest. It no longer claims
  2024-11-05, whose HTTP+SSE transport it never implemented. `mcpProtocolVersion` is
  now `2025-11-25`. `initialize` advertises only `tools`, `resources` and `prompts`
  (no `listChanged`, `subscribe` or `logging`); `resources/subscribe` and the
  non-standard `shutdown` method (`MCPMethod.shutdown`) are removed; `ping`
  returns `{}`.
- **`tools/call` runs exactly the named tool, or fails (SC-SW-03).** Tools are
  listed as `<providerId>__<toolName>` (`MCPToolNaming.aggregate`) or, with
  `MCPServerConfig.toolNaming = .provider(id)` / `serve --provider`, one provider's
  tools under their upstream names. An unlisted name is a JSON-RPC `-32602` error;
  without a wired runtime a call is a JSON-RPC error (it used to answer
  `status: ok` with a "runtime dispatch pending" note); a tool that throws is an
  `isError` result. Results are MCP `CallToolResult`s (`content`,
  `structuredContent` for JSON objects, `isError`, `_meta["dev.smallchat/toolId"]`)
  instead of `{invocationId, status, result}`. Tool names no longer go through
  semantic resolution. `MCPRouter.setRefinementHandler` is replaced by
  `setToolExecutor(_:)` and `setResolveHandler(_:)`; `MCPRouter.init` no longer
  takes an `SSEBroker`.
- **The MCP meta-tool is the read-only `smallchat_resolve`.** It proposes a tool
  (name, tool id, tier, candidates, proof digest) and never runs anything; it is
  listed by default when a runtime is wired. The executing `smallchat_dispatch`,
  `MCPSemanticDispatchTool`, `MCPSemanticDispatchHandler`,
  `MCPRouter.setSemanticDispatchHandler(_:)`, `MCPServerConfig.semanticDispatch` and
  `serve --semantic-dispatch` are removed; use `MCPResolveTool`,
  `setResolveHandler(_:)`, `MCPServerConfig.resolveTool`,
  `MCPServer.setRuntime(_:resolveTool:)` and `serve --no-resolve-tool`. `tools/call`
  runs tools through `ToolRuntime.dispatchById`, and its results carry
  `_meta["dev.smallchat/resolution"]`. Aggregate names `<providerId>__<toolName>`
  are used only for provider ids made of `[A-Za-z0-9_-]` without `__` or a trailing
  `_` and names of at most 128 characters (`mcpAggregateName`).
- **OAuth is removed; `--auth` means a bearer token (SC-SW-17).** `OAuthManager`,
  `OAuthToken`, `OAuthClient`, `MCPScope`, `PermissionsConfig` and
  `MCPServerConfig.enableAuth` are gone. `MCPServerConfig.authToken` requires
  `Authorization: Bearer <token>` on every request except `GET /health`.
  `serve --auth` reads the token from `SMALLCHAT_MCP_TOKEN` or `--auth-token-file`
  (default `~/.smallchat/serve-token`; see `MCPAuthTokenFile`): a missing file is
  created with a random token, mode 0600 from the start, in a 0700 directory, and
  an existing file that group or other users can access is refused (SW-REV-07).
- **The MCP server reads requests with `parseJSON` (JCS-CANONICAL-EQUIV-KEYS).**
  Numbers are read as `JSON.parse` reads them (an integer beyond 2^53 is a double,
  as in @smallchat/core), and an object whose member names differ in code points
  but are canonically equivalent (`"\u00e9"` and `"e\u0301"`) is a `-32700` parse
  error instead of being merged into one member. An integral `id` written `1.0`
  is still the integer 1. A string that starts with U+FEFF keeps it, as in
  `JSON.parse` (SW-QUORUM-3).
- **`AuditLog` requires a key and hashes every field (SC-SW-16).**
  `AuditLog(hmacKey:)` takes a non-empty key; `MCPServer` uses
  `MCPServerConfig.auditKey` or a random key. The chain now covers `clientId` and
  `error` too, so chain heads differ from 0.6.x.
- **`MCPClientTransport.execute` returns the upstream `CallToolResult`** for MCP
  tools (content is the whole result object, flagged with
  `mcpCallToolResultMetadataKey`), not just its `content` array.
- **`SmallChatMCP` depends on `SmallChatCompiler` and `SmallChatEmbedding`**, so it
  can compile manifests into a runnable toolkit (`MCPToolkit`).

#### Transports

- **`TLSConfig`, `CertificatePinningMode`, `TLSVersion` and `TLSError` are
  removed (SC-SW-19).** No transport, `TransportConfig` or `URLSession` delegate
  ever read them, so the certificate pinning and minimum TLS version they described
  were never enforced.
- **`HTTPTransport` builds requests from the route (SC-SW-09).** `{name}`
  placeholders in a route path are filled with the argument of that name,
  percent-encoded as one path segment (they used to be sent literally, as
  `%7Bname%7D`); a placeholder without an argument fails the call with the new
  `TransportError.invalidRequest` and sends nothing. Declared `queryParams` go in
  the query string. GET and HEAD calls without declared query params, and DELETE
  calls without a route, put their arguments in the query string (GET arguments
  used to be dropped). Other methods send the arguments not used in the path or
  query as the JSON body (path params used to be duplicated there).
  `TransportSerialization.serializeInput` throws, and percent-encodes everything
  but RFC 3986 unreserved characters.
- **`TransportError` has a new case, `invalidRequest(message:)`.** Exhaustive
  `switch`es over `TransportError` need to handle it.
- **`MCPStdioTransport` negotiates the protocol version (SC-SW-08).** It asks for
  `2025-11-25` (it sent `2024-11-05`) and accepts a server that answers
  `2025-11-25`, `2025-06-18`, `2025-03-26` or `2024-11-05`; any other answer
  fails `connect()`. The agreed version is `negotiatedProtocolVersion`.

#### Channel

- **The channel bridge moved to `SmallChatChannel` (SC-SW-31).**
  `ChannelBridgeServer`, `ChannelBridgeProtocol`, `ChannelBridgeResponse` and
  `ChannelInboundEvent` were in `SmallChatAgents`; `SmallChatAgents` now depends on
  `SmallChatChannel` and re-exports it (`@_exported import`), so code that imports
  either module (or the `SmallChat` umbrella) still sees them
  (DOC-AGENTS-REEXPORT). `ChannelBridgeProtocol.constantTimeEqual` is public.
- **`serializeChannelTag` XML-escapes `&`, `<` and `>` in the content (SC-SW-24).**
  Content containing those characters now renders as entities (`&lt;b&gt;`, not
  `<b>` or a blocklist-escaped tag).
- **The bridge's sender is the credential's identity, not the body's.** `POST /event`
  ignores the body's `sender` and `channel`: every event is from the identity the
  shared secret authenticates on the configured channel, as in smallchat
  (TypeScript) 1.0 (its SC-SURF-10 and SC-SURF-25).
  `ChannelServerConfig.httpBridgeSecretIdentity` (`--http-bridge-secret-identity`,
  default `bridge`) names it, and the sender allowlist judges it; `ChannelBridgeProtocol.handle` and `ChannelBridgeServer` take
  `secretIdentity:` (`ChannelBridgeProtocol.defaultSecretIdentity`). `sender`,
  `source` and `user` are reserved meta keys (`reservedMetaKeys`), which
  `isValidMetaKey` and `filterMetaKeys` drop; `ChannelServer.injectEvent` stamps the
  event's sender as the notification's `meta.sender`, and
  `serializeChannelTag(channel:content:meta:sender:)` renders it as the tag's
  `sender` attribute. The messenger's objection channel stamps `stenographer`.
- **`ChannelServer.shutdown()` is `async`** (it also stops the HTTP bridge).
- **`smallchat channel --http-bridge` requires `SMALLCHAT_CHANNEL_SECRET`**, and the
  channel server negotiates its protocol version (it always answered `2024-11-05`):
  it echoes `2025-11-25`, `2025-06-18` or `2024-11-05` and offers `2025-11-25`
  otherwise.

#### Truth (`SmallChatTruth`)

- **SmallChatTruth reads truth format v2, and fails closed (SC-SW-05, SC-SW-06,
  SC-SW-07, XSUITE-08).** Stenographer's truth streams are hash-chained JSONL
  (`schemaVersion: 2`, `seq`, `prevHash`, `hash` = SHA-256 of the line's JCS form)
  with `TRANSITION` lines for status changes. `TruthWiki.parse` checks every line
  and the chain and refuses a v2 stream with any bad line or break
  (`ParseResult.refused`, no entries); its `errors` are `TruthReadError`s (line,
  error, id, file), not `TruthError`s. An entry's status is folded from the last
  `TRANSITION` that targets it. `TbStatus`, `UvStatus`, `TruthEvidence.Kind` and
  `TruthVerifyBy.Kind` are open, string-backed structs (the known values are static
  members, with `TbStatus.struck`, `UvStatus.struck` and
  `TruthEvidence.Kind.claimedCommand` added), and
  `TruthTbEntry.status`/`TruthUvEntry.status` are optional: an unknown or missing
  status is kept as written and is history. A struck, unsigned or inadmissible
  entry is history too, and `TruthObjections.check` ignores every TB that isn't
  current truth. Version 1 TBs (no hash) are unverifiable unless
  `TruthReadOptions(admitV1Tbs: true)`. Version 1 lines must have a real `ts` and
  at least one piece of evidence, as Stenographer's import requires.
- **Agents settle claims only together (truth format v2, "Agent quorum").** A
  settlement by agents is valid only with a `quorum` of two or more agent sessions
  agreeing from different angles within 15 minutes. `TruthFormat.decode` refuses a
  line whose quorum breaks the spec's rules 1–6, a quorum on any line but a v2 TB or
  ADDENDUM, and a version 1 line carrying one. A TB an agent signs is truth only with
  a quorum whose members are all agents (with a signer registry, listed with role
  `agent`; without one, an `agent:` key) and, read with every kind this version
  doesn't know as question-class, cite settling evidence of two kinds; otherwise it
  is inadmissible with the new reason `.agentWithoutQuorum` (`agent-without-quorum`),
  so a `switch` over `TruthInadmissible.Reason` needs the case. `TruthTbEntry` carries
  `quorum` (no longer among its `extra` fields).
- **`consumptionRules` is Stenographer's new text:** an agent that can check an open
  UV files its verdict and evidence with `resolve_uv`, which settles only when another
  agent session agrees from a different angle within 15 minutes, or a person rules.
- **`TruthWiki.serialize` writes lines back as read (XSUITE-09).** An entry read
  from a stream serializes to the exact line it came from (no `sortedKeys`
  rewrite, no status rewrite); an entry built in code is written in the version 1
  shape with Stenographer's field order.
- **Tombstones are no longer written to wiki files (SC-SW-14, XSUITE-06).**
  `TombstoneDraft.sign()` and `TruthWiki.append(_:toFileAt:)` are removed.
  `TombstoneDraft.proposal(author:)` builds a PROPOSAL envelope, and
  `MessengerModel.assertTombstone(_:)` is now `async`: it submits the envelope to
  Stenographer (`POST /proposals`) and notarizes it as the signer.
  `MessengerModel.tombstoneTarget` is gone and `MessengerSettings.tombstoneFile` is
  no longer read.
- **Proposals are the suite's PROPOSAL envelope.** `TruthProposals.serialize`
  writes hash-chained truth format v2 lines (`after:` continues a file's stream);
  `InvariantProposal.Signal` defaults to `compaction-candidate` (the retired
  `shorthand-compaction` source is no longer written); `InvariantProposal` is no
  longer `Codable`.
- **Literal validation is Stenographer's (SC-SW-33).** A literal without a subject
  needs at least 4 UTF-16 code units and an ASCII letter, values are trimmed with
  ECMAScript whitespace, and an explicit `"subject": null` is refused;
  `TruthTombstonedLiteral.validationError` and `TombstoneDraft.problems` use the
  same rule.
- **Truth renderings escape untrusted text.** `TruthCompaction.renderSection`,
  `compactionItems`, `invariantRecords`, `TruthObjection.summary` and the
  stenographer's notes and prompt put a `\` before a frozen marker (`[TB…`,
  `[UV…`) or a reproduced `## Asserted Truth` heading inside ledger fields and
  transcript text, and collapse line breaks in ledger fields. An active TB with
  an open contesting UV now renders as `[TB ⚠ CONTESTED]`.
- **Identities compare by key.** `isAnonymousIdentity` folds width, case and
  invisible characters (`ａｓｓｉｓｔａｎｔ` is anonymous), and
  `assertAccountableAuthor` also refuses control characters and the reserved
  `migration` and `detector:*` (unless `allowDetector`). `TruthError.malformedLine`
  with line 0 describes itself as just its reason. As in Stenographer, a key is
  lowercased as ECMAScript's `toLowerCase` lowercases (a word-final `Σ` is `ς`; a
  quorum's `commit` refs compare the same way), and the `agent:` and `detector:`
  prefixes and a signer registry's `*` entries match code point for code point, so
  `agent:` followed by a combining mark is an agent (SW-QUORUM-1, SW-QUORUM-2).

#### Messenger (`SmallChatAgents`, `SmallChatUI`)

- **The switchboard protocol is nonce-framed (SC-SW-20).**
  `SwitchboardProtocol.systemPrompt(name:nonce:)`,
  `relayCommand(ticket:to:cwd:body:nonce:)` and `parse(_:nonce:)` replace the
  versions without a nonce; `makeNonce()` and `listCommand(nonce:)` are new, and
  `Switchboard.init` takes an optional `nonce` (for tests). `parse` ignores every
  line that doesn't carry the nonce.
- **`claude` launches keep text off the command line and need a current Claude
  Code CLI (SC-SW-21, SC-SW-36).** `ClaudeCommand` invocations use
  `--input-format stream-json` and carry the prompt in the new
  `ClaudeInvocation.prompt` (written to stdin) and system prompts in
  `ClaudeInvocation.appendSystemPrompt` (passed with `--append-system-prompt-file`);
  `arguments` no longer contain either. The switchboard and stenographer sessions
  add `--tools`, `--strict-mcp-config` and `--setting-sources user`, so the
  `claude` binary must support those flags.
- **`AgentTransport` requires `shutdown()` (SC-SW-30).** Conforming types must
  implement it (stop any process they keep running); `MessengerModel.setTransport(_:)`
  calls it on the transport it replaces.
- **A running session is never resumed (SC-SW-22).** `ClaudeCodeTransport.send` to
  a live session whose Claude Code name isn't known fails with the new
  `AgentTransportError.liveSessionUnnamed` instead of starting `claude -p --resume`
  on it.
- **The switchboard runs in its own directory**,
  `<Application Support>/SmallChat/switchboard`
  (`ClaudeCodeTransport.Configuration.switchboardDirectory`), not your home
  directory.
- **The messenger keeps its secrets outside `messenger.json` (SC-SW-23,
  XSUITE-13).** `MessengerSettings.objectionChannelSecret` is removed.
  `MessengerModel.channelSecret` authenticates stenographer to the
  objection-channel bridge (`SMALLCHAT_CHANNEL_SECRET`), the new
  `MessengerModel.notarySecret` authenticates the messenger's notarize and dismiss
  calls (`X-Notary-Secret`, `STENOGRAPHER_NOTARY_SECRET`), and the new
  `MessengerModel.restToken` (`MessengerSecret.restToken`,
  `STENOGRAPHER_REST_TOKEN`) is sent as `Authorization: Bearer` on every
  Stenographer REST call. All three live in `MessengerStore.secrets`, a
  `MessengerSecretStore`: the Keychain on macOS (`KeychainSecretStore`), 0600 files
  in a 0700 directory elsewhere (`FileSecretStore`), or `InMemorySecretStore` for a
  store without a file. `MessengerStore.init(url:secrets:)` picks the platform's
  store when `secrets` is nil. The secrets are generated anew on the first 1.0
  launch, and the old one is removed from `messenger.json`.
  `NotaryClient.request(for:notarizeURL:secret:restToken:)` and
  `NotaryClient.openDrafts(restBase:restToken:session:)` take the REST token.
- **Notarize URLs come only from the messenger's settings (XSUITE-13).**
  `PendingProposal.notarizeURL` is removed and `NotaryClient.parseInbox(_:)` no
  longer takes `restBase`. `NotaryClient.notarizeURL(restBase:proposalId:)` returns
  nil for an id other than letters, digits, `-` and `_`
  (`NotaryClient.isValidProposalId(_:)`); such proposals are not queued.
- **`MessengerModel` saves in the background (SC-SW-28).** Changes are written
  within `persistDelay` (500 ms) of the first one, and when the app quits, instead
  of before each mutating call returns. Call `await model.flushPersistence()` before
  reading `messenger.json` or loading a second model from the same store.
  `messenger.json` is written without pretty-printing.
- **`AppWebViewSandbox` is `@MainActor` (SC-SW-11)**, like WebKit's delegate
  protocols; create it on the main actor (`AppWebViewConfiguration.make(for:)`
  already is). `AppWebViewSandbox.policy(for:allowedURI:)` is new.

### Added

- **@smallchat/core's conformance vectors run in `swift test` (XSUITE-19).**
  `Scripts/sync-spec.sh <smallchat checkout>` copies its `spec/` into
  `Tests/Fixtures/spec` (recording the commit in `SOURCE`) and regenerates the
  artifact schema; the `SmallChatConformanceTests` target runs every canonical
  JSON, call digest, tool id, ranking and resolve vector and every artifact fixture.
- **Canonical call digests** (`callDigest(toolId:arguments:)`, `canonicalJSON`
  (RFC 8785), `domainDigest`, `sha256Hex`): a dispatch result's
  `metadata["callDigest"]` and its proof's `callDigest` are the same SHA-256 as
  @smallchat/core computes for the same tool id and arguments.
- **`JSONSchemaValidator`**, `ToolAnnotations`, `EmbedderFingerprint`,
  `ArtifactV1` (`read`, `parse`, `validate`, `build`, `write`,
  `assertEmbedder`), `builtinEmbedder(for:)`, `MCPToolkit.make(artifact:…)`,
  `ProviderManifest.launch` / `LaunchSpec`, and `ToolDefinition` `title`,
  `outputSchema`, `annotations` and `uiResourceUri` (carried into artifacts and
  `tools/list`).
- **`MCPToolkit`, `EndpointToolIMP`, `MCPToolCatalog`** and
  `MCPServer.setRuntime(_:resolveTool:)`, `setToolExecutor(_:)`, `setArtifact(_:)`
  and `boundPort` (start on port 0 and read the port). `serve` gains `--provider`,
  `--no-resolve-tool`, `--auth-token-file` and `--max-connections`.
- `smallchat compile --dims` (hash embedder dimensions) and `smallchat resolve --json`.
- **Truth format v2 conformance in `swift test` (XSUITE-19).** `Scripts/sync-truth-fixtures.sh
  <stenographer checkout>` copies Stenographer's `spec/truth-format` (README, JSON
  Schema, golden fixtures) into `Tests/Fixtures/truth-format`, recording the commit
  and every file's SHA-256 in `SOURCE`; `TruthFormatConformanceTests` runs every
  fixture (valid lines against the schema and the codec, hashes, chains, the fold,
  verbatim re-serialization, routing, v1 lines, and every invalid line).
- **`TruthFormat`** (line codec: `decode`, `hash`, `checkChain`, `chain`,
  `literalIssue`), **`TruthWiki.parseFiles`** (one stream per writer, merged on the
  status lattice), `TruthWiki.statusTable`, **`TruthSignerRegistry`** (Stenographer's
  `signers.json`), `TruthReadOptions`, **`TruthEscaping.escapeUntrusted`**, and
  **`TruthProposalEnvelope`** (the suite PROPOSAL envelope, written byte for byte
  as the golden fixtures).
- **The agent quorum and evidence classes in `SmallChatTruth`.**
  `TruthQuorum` (`issues(in:)`, the line-local rules; `isAgent(_:signers:)`;
  `windowMilliseconds` 900 000 and `minimumMembers` 2) and `TruthQuorumMember`.
  `TruthEvidence.Kind` knows `chat` (a chat message or thread), `ticket` (an issue or
  ticket) and `doc` (a document outside the truth ledger), and `TruthEvidenceClass`
  classifies every kind: `Kind.settling` (`commit`, `file`, `test`,
  `claimed-command`, `wiki`) are settling, every other kind, and any this version
  doesn't know, question-class (`Kind.evidenceClass`, `Kind.isKnown`,
  `TruthEvidence.isSettling`). A signer registry entry may carry `keys` (public keys
  reserved for 1.x), which 1.0 reads past. `Tests/Fixtures/truth-format` carries the
  spec's new fixtures: a UV verified and a TB minted by agent quorums in
  `valid/ledger.jsonl`, agent settlements without a quorum in `valid/routing.jsonl`,
  and a refused line for each quorum rule in `invalid/`.
- **`NotaryClient.submitAndNotarize`** files a PROPOSAL envelope with Stenographer
  (`POST /proposals`, idempotent by envelope id) and notarizes it, returning the
  minted TB; `MessengerModel.authoredTombstones` keeps it in the ledger until a
  wiki export carries it, as long as the exports read cleanly
  (`TruthLedgerSnapshot.refused`).
- **CI on every supported platform.** macOS 15 (Xcode 16.4, Swift 6.1), the newest
  Xcode (`macos-26`), an iOS build of the `SmallChat` scheme, and builds and tests
  in `swift:6.1`, `swift:6.3` and `swift:6.4` Linux containers (the 6.1 tests link
  with `-Xlinker --allow-shlib-undefined`; see Known issues).
- **`DispatchContext.registryGeneration` and `isRegistered(_:)`**,
  `ResolvedTool.registryGeneration` and the `registryGeneration:` parameter of
  `ResolutionCache.store` (SW-REV-02).
- **`SemanticRateLimiter.admit(_:principal:)`**, `record(_:vector:)` and
  `release(_:)` with `RateLimitAdmission` / `RateLimitReservation`: check and
  reserve a window slot in one step (SW-REV-06). `evaluate` and `check` only look.
- **`MCPAuthTokenFile.loadOrCreate(at:)`** and `MCPAuthTokenFileError`: the token
  file `serve --auth` uses (SW-REV-07).
- **`ClaudeProcess.enqueue(line:completion:)`** writes to `claude`'s stdin on the
  process's own serial queue and returns at once; `Switchboard.listAgents(timeout:)`
  takes the listing timeout (60 s by default).
- **`SmallChatVersion.current`** in `SmallChatCore`: the one place the package
  version is spelled.
- **The MIT `LICENSE` file (SC-SW-37, XSUITE-18)** the README badge has always
  linked to; without it the package carried no license grant.
- **The macOS app is a messenger for your Claude Code sessions**
  (`SmallChatApp` + the new `SmallChatAgents` library). The sidebar lists live
  and recent non-archived sessions. Live status and kind come from Claude
  Code's session registry; title, branch, and recency come from transcripts.
  Each session gets a durable, renamable handle such as `@instrument-62`.
  - **Direct chats.** A live session receives messages through Claude Code
    inter-agent messaging, via a headless *switchboard* session limited to
    `SendMessage`/`ListAgents`. A stopped session is resumed headlessly, one turn
    at a time.
  - **Group chats.** Messages fan out to every agent, or only to the agents
    you `@mention`. Agent replies land private to you, with **Share with
    group**, which delivers the reply to the other agents as an
    inter-agent interrupt, and **Keep private**.
  - **Stenographer.** Every chat has a stenographer preloaded from the
    wiki's TB/UV ledger. It objects to tombstoned literals and flags
    reliance on open UVs (notes visible only to you), and answers
    `@stenographer` questions through a headless session briefed with the
    ledger.
  - **Live tool activity on agent cards.** `TranscriptActivity` reads the
    tail of each live session's transcript. It pairs `tool_use` with
    `tool_result` by id, skips sidechains, and keeps the in-flight tool, the
    last 5 steps, and the latest prose.
  - **Objection channel.** `ChannelBridgeServer` is a loopback NIO HTTP
    bridge that receives Stenographer's `--objection-channel` posts. It uses
    the TS channel-bridge contract: `POST /event`, `X-Channel-Secret` or
    Bearer auth, and 401/400/404/413 errors. Objections are routed by
    `meta.session_ids` into each agent's direct and group chats, relayed as
    an interrupt into live sessions (a toggle turns relaying off), and
    deduplicated by objection id.
  - **Authoring tombstones with literals.** `TombstoneDraft` covers claim,
    evidence, literals, and an accountable signer. It goes to Stenographer as a
    PROPOSAL envelope that the signer notarizes, and the app ledger reloads so
    objections to the new literals start at once.
  - The existing tool panels moved under **Toolkit**.
- **`SmallChatTruth`: truth-ledger interop with Stenographer.** Reads and writes
  the ledger's TB/UV lines (truth format v2, see above; unknown fields kept
  verbatim), applies the §7 consumption rules (`TruthWiki.classify`/
  `selectCurrentTruth`: active TBs are ground truth, contested TBs carry their live
  contesting UVs, open UVs are flagged `[UV — UNVERIFIED]` and never render as
  proven, everything else is history), projects the selection into compaction
  corpus items and L4-shaped invariant records (`TruthCompaction`), and ships a
  stock `CompactionVerifier` invariant (`TruthInvariants.preserved(_:)`) that fails
  any compaction which drops a truth item or strips the UNVERIFIED marker.
  `InvariantProposal`/`TruthProposals` are the proposal-only write path, and refuse
  anonymous and generic identities (`system`, `assistant`, …).
- **`TruthObjections`**: a Swift port of Stenographer's real-time objection
  detector (tombstoned-literal matching, §12). `TruthTbEntry` carries `literals`.

### Fixed

- **Builds with Swift 6.2+ (Xcode 26, and Swift 6.3/6.4 on Linux) (SC-SW-02).**
  `HTTPTransport`, `LocalTransport`, `MCPSSETransport`, `MCPStdioTransport` and
  `RtkTransport` each bumped a nonisolated `static var counter` to mint their ids,
  which newer compilers reject as global mutable state. It was also a data race:
  transports created concurrently could get the same id (which names their circuit
  breaker). Ids now come from a lock-protected `TransportIDSequence`.
- **Transport, MCP, Channel, the `SmallChat` umbrella and the CLI build and
  pass their tests on Linux (SC-SW-26).** `FoundationNetworking` is imported where
  `URLSession` is used; `URLSession.streamingBytes(for:)` replaces
  `bytes(for:)`, which swift-corelibs-foundation lacks, with a delegate that
  yields body chunks as they arrive (SSE and NDJSON keep streaming), and
  SHA-256/HMAC come from swift-crypto. Every `import os` is guarded with
  `#if canImport(os)`, so `SmallChatTruth` and its dependencies also build there.
- **Library products compile for iOS (SC-SW-12)** (checked by the new iOS CI
  job). Besides the subprocess guards above, Dream reads `NSHomeDirectory()`
  instead of the macOS-only `FileManager.homeDirectoryForCurrentUser`.
  `SmallChatAgents` stays macOS/Linux only, and the README's platform table
  now says so.
- **The MCP server no longer crashes on every request (SC-SW-01).** Request
  handling ran in a Swift task and wrote to `ChannelHandlerContext` from there, off
  its event loop: NIO's precondition killed debug builds (`smallchat serve`, the
  app's Server panel) on the first request, and release builds raced on the
  pipeline. Work still runs in tasks; every write hops back to the connection's
  event loop. Tests now send real HTTP requests.
- **`smallchat serve` runs tools (SC-SW-03).** It never wired a runtime, and the
  compiler's `ToolProxy` faked execution anyway. `serve` (and `MCPServer.start()`
  with a `sourcePath`) now loads manifests or an artifact with `MCPToolkit`, whose
  `EndpointToolIMP`s call each provider's remote endpoint (its manifest `endpoint`,
  or the artifact's `launch.url`): MCP servers over Streamable HTTP, REST APIs as
  `POST <endpoint>/<tool>`. A provider launched over stdio is listed, and its
  tools fail when called. Artifacts record each tool's description, input schema
  and annotations, and each provider's launch spec (schemas used to be looked up
  by tool name alone, so two providers sharing a tool name got the same schema).
- **The README describes only endpoints that exist (SC-SW-32).** It listed
  `/mcp/initialize`, `/mcp/invoke`, `/mcp/events` and friends, an SSE stream that
  sent one event, and a "production-grade" server on 2024-11-05.
- **`MCPClientTransport` works with Streamable HTTP servers**: it initializes
  lazily, sends `Accept`, `Mcp-Session-Id` and `MCP-Protocol-Version`, reads
  responses sent as SSE, re-initializes once when the server drops the session,
  and ends sessions with `terminateSession()`.
- Tool content that is not a string is rendered as JSON (`formatContent` used
  Swift's `String(describing:)`).
- **Timeouts fire on time.** `TimeoutMiddleware` raced the operation in a task
  group, so when the deadline passed it still waited for an operation that
  ignored cancellation (every continuation-based transport call did): stdio MCP
  calls and the rtk filter hung past their timeouts. The new
  `withTimeout(seconds:_:)`, which `TimeoutMiddleware` now uses, resumes exactly
  once, cancels the operation and returns at once.
- **`MCPStdioTransport` no longer corrupts or loses output, and never hangs on a
  dead server (SC-SW-08).** stdout is read as bytes on its own thread and split
  into lines before UTF-8 decoding, in order; each pipe read used to be decoded on
  its own, so a read ending inside a multibyte character was dropped (a 210 KB
  result of "€" arrived as 4,464 characters) and chunks were handed on through
  unordered tasks. A call that times out or whose task is cancelled is removed and
  the server is sent `notifications/cancelled`. A server that exits, closes stdout
  or stops reading stdin fails every pending call with its stderr tail (calls
  used to wait forever). stderr is drained, so a chatty server cannot block.
  Writes no longer crash the process on a broken pipe (Linux `FileHandle.write`
  traps on `EPIPE`, and SIGPIPE killed the process); concurrent first calls
  start one server, not two; the server's `ping` requests are answered.
- **`HTTPTransport` sends path and query arguments (SC-SW-09)**, as described
  under Breaking; REST tools used to hit `/pets/%7BpetId%7D` and lose their GET
  arguments.
- **The rtk filter no longer deadlocks on large output (SC-SW-10).** It wrote the
  whole body to stdin before reading stdout, so a filter whose output filled the
  pipe buffer (about 64 KB) blocked forever. stdin is now written while stdout and
  stderr are read, and on `timeoutMs` the process is stopped.
- **`smallchat channel --http-bridge` listens (SC-SW-31, XSUITE-14).** The flag and
  the startup banner promised an HTTP bridge that was never started, so webhooks
  and stenographer's `--objection-channel` got connection refused.
  `ChannelServer.startHTTPBridge()` now serves `POST /event` (403 when sender
  gating or the size limit rejects the event) and `GET /health`. The README's
  `smallchat channel --port 3002` never existed; it is `--name`.
- **`smallchat channel` exits when stdin closes (SC-SW-31).** It waited only for
  SIGINT, so it outlived the Claude Code session that started it. stdin is read on
  its own thread instead of blocking a cooperative-pool thread, and replies
  already queued are written before it exits.
- **Canonical forms, tiers and pins agree with @smallchat/core (SC-SW-15).** 0.6
  split words at punctuation (`"search_code"` → `search:code`, `"don't"` →
  `don:t`) where TypeScript deletes it, used thresholds of 0.98/0.85/0.70/0.55 (so
  0.96 was HIGH in Swift and EXACT in TypeScript), and compared `exact` pins by
  canonical form, which drops "not": `"do not transfer funds"` matched a pin on
  `"transfer funds"`. Canonicalization, `intentKey`, pin phrases, thresholds,
  quantization and tie-breaks now follow the TypeScript rules, and the
  `spec/resolve` vectors check the outcomes.
- **An open UV contesting a TB is never dropped (SC-SW-05, XSUITE-04).** Rendering,
  compaction items and the invariant skipped every UV with a `contests` field,
  so a UV contesting an active TB (Stenographer's incremental export had not
  re-sent the TB as contested) or a TB that wasn't loaded vanished from the brief
  and compaction. An open contesting UV now rides its TB whatever the TB's
  recorded status, and is rendered on its own when its TB isn't current truth.
- **Unknown or missing statuses fail closed and are never rewritten (SC-SW-06,
  XSUITE-08).** A TB whose status was `retracted`, or missing, was read as
  `active` ground truth and written back as `"status":"active"`; an evidence kind
  like `url` or a verifyBy kind like `query` made the whole line unreadable.
- **Struck TBs are history and never object (SC-SW-07, XSUITE-03).** A strike
  reaches the reader as a `TRANSITION` to `struck` (or, from Stenographer 0.x, an
  inbound `strikes` link), and the TB leaves ground truth and stops raising
  objections.
- **Literal validation matches Stenographer's (SC-SW-33).** `日本語版` and `ÅÅÅÅ`
  were accepted, `éé` written with combining accents refused, and an explicit
  `"subject": null` accepted, where Stenographer's import decides the opposite.
- **Signing a tombstone never touches Stenographer's export (SC-SW-14,
  XSUITE-06).** The messenger appended human-signed TBs to the wiki file
  Stenographer's full export rewrote, so they could be lost. It now submits a
  PROPOSAL envelope over REST and notarizes it; Stenographer writes the TB.
- **Re-serializing keeps key order (XSUITE-09).** Lines were rewritten with sorted
  keys, which Stenographer's (0.x) import compared as different content and filed
  as reconciliation proposals.
- **A switchboard relay that times out fails (SC-SW-13).** `Switchboard.relay`
  raced the receipt against a timer whose task returned normally, so when the
  switchboard never answered (rate limit, expired login, crashed turn) the relay
  returned as if delivered and the chat waited for a reply that could not come. It
  now throws `SwitchboardError` ("switchboard timed out"), and a cancelled relay
  throws too instead of leaving its ticket pending.
- **A session is resumed one turn at a time (SC-SW-22).** Messaging a live session
  that the registry hadn't named started `claude -p --resume` on it next to the
  running process, and two quick messages to a stopped session started two
  resumes; either appended a divergent branch to the same transcript. Live sessions
  are only ever messaged, and headless turns of one session (agent or
  stenographer) now wait for each other.
- **Changing the `claude` path stops the old switchboard (SC-SW-30).** The replaced
  transport was never shut down, so a second switchboard named `smallchat` kept
  running, and agents' replies could reach the one nobody listened to. A
  switchboard that ended also no longer fails the tickets of the one that replaced
  it, and writes to a `claude` that stopped reading its stdin fail instead of
  raising `SIGPIPE`.
- **The messenger no longer rewrites its store on the main actor for every
  change (SC-SW-28).** Each message, receipt and stenographer note re-encoded every
  conversation (pretty-printed) and wrote the file synchronously: with a 20,000
  message history one send took about 390 ms and rewrote 13 MB. A burst of changes
  is now one compact write, encoded and written on a background queue.
- **Session rescans read only the transcripts that changed (SC-SW-27).** The full
  rescan every minute re-read up to 256 KB of every transcript under
  `~/.claude/projects`, and parsing each timestamp built two
  `ISO8601DateFormatter`s (about 250 µs per call on Linux). Summaries are now
  cached by path, size and modification time
  (`ClaudeSessionScanner.summaryCache`), and dates parse with shared
  `Date.ISO8601FormatStyle` values (about 1 µs).
- **Live activity shows a tool call bigger than the tail window (SC-SW-35).** When
  the newest transcript line was longer than the 64 KB window (a Write with a large
  file body), no whole line was left and the card went blank. The window now
  doubles until it holds a line, up to 8 MB.
- Settings saved by an older build load: `MessengerSettings` decodes leniently, so
  adding a setting can't make the whole saved store (conversations included) fail
  to decode.
- **The docs describe the code as it is (XSUITE-16).** The README called this port
  "same semantics" as TypeScript; it now says which vectors are checked. The docs
  site's transport, embedding, tool-class, channel and Claude Code pages showed APIs
  that don't exist (`TransportInput(method:params:)`, `OAuth2Auth(tokenEndpoint:)`,
  `ToolCategory(targetClass:)`, `SelectorMatch.similarity`,
  `PermissionVerdict(allowed:)`, `SCMethodSignature(params:)`); the security guide said
  the channel's `SenderGate` made every tool call wait for approval and that metadata
  filtering removed credentials; the README claimed "no raw threads", automatic
  schema-change detection and core selectors that no registration could shadow; and
  the Phase 4 guide called CRDT correctness "mathematically guaranteed" (see SC-SW-29
  under Known issues). Each now says what the code does, the
  CLI reference covers all 13 commands, and the pre-1.0 ecosystem evaluation and the
  0.5.0 roadmap are marked as archived. `smallchat doctor` no longer reports
  Accelerate on Linux, and `dream --embedder` says that only the hash embedder is
  built in.

- **A tool from an unregistered or replaced class could still run (SW-REV-02).**
  A cache hit ran the cached tool without checking that its id still named it, and
  a resolution that raced `unregisterClass`, `registerClass` or `reindex` cached
  its pick after the flush, so a later dispatch of the same intent ran a tool that
  `getTool` no longer knew (8 of 400 concurrent runs in review). Cache entries now
  carry the registry generation, a stale resolution is not cached, and both
  dispatch paths check the tool is still registered just before it starts.
- **The semantic rate limiter bounds concurrent novel intents (SW-REV-06).**
  Admission was a check, then embedding, then a record, so 20 concurrent novel
  intents from one principal all passed `maxNovelIntents = 2` before any was
  counted. `admit` now takes the window slot in the same step, and a failed
  embedding gives it back.
- **A stuck switchboard can't block the messenger (SW-REV-03).** `relay` and
  `listAgents` wrote to the switchboard's stdin on the `Switchboard` actor, and the
  write blocks until `claude` reads it: with a body larger than the pipe buffer and
  a switchboard that wasn't reading, the actor stayed blocked, so the relay timeout
  never fired and `shutdown()` hung until the process exited. Writes now go to the
  process's own serial queue (`ClaudeProcess.enqueue`), in order and whole, and
  `closeInput()` closes stdin after them.
- **An earlier LIST can't end a later one (SW-REV-04).** Every `listAgents` call
  started a 60 s timer that ended whichever LIST was waiting when it fired, so a
  timer left from a finished LIST returned a later one early, often empty. Each
  LIST's timer and failed write now end only that LIST, and a finished LIST
  cancels its timer.
- **A refused ledger keeps tombstones signed in the app out of current truth too
  (SW-REV-05).** When an export failed to load (a bad hash, a broken chain), the
  ledger loaded nothing, as designed, but tombstones signed in this session were
  still added to it, so the stenographer kept objecting from a TB the unreadable
  export might have struck. They now wait in `authoredTombstones` until a readable
  export speaks for them, and `TruthLedgerSnapshot.refused` says the load was
  refused.
- **Canonically equivalent member names no longer collapse
  (JCS-CANONICAL-EQUIV-KEYS).** Swift `String` keys compare by canonical equivalence, so `parseJSON` (and the MCP
  server's JSONDecoder path) kept one of two members named `"\u00e9"` and
  `"e\u0301"`, which `JSON.parse` and RFC 8785 keep as two: `canonicalJSON` and
  `callDigest` then disagreed with @smallchat/core on the same wire JSON, and the
  runtime validated and forwarded different arguments. `parseJSON` now refuses
  such an object (`JSONParseError`); identical repeated names still keep the last
  value.

### Security

- **Repeating an intent can't run a tool the first call refused (SC-SW-04).** The
  0.6 resolution cache was consulted before tier checks, verification and strict
  mode, so the second dispatch of an intent ran the tool the first one had declined
  to run, in strict mode too. The cache now holds only resolutions the policy
  allowed (never pinned or destructive tools), every hit is judged again by the
  policy, and strict mode ignores cached resolutions below EXACT.
- **Strict mode does what it says (SC-SW-25).** 0.6's strict mode ran a MEDIUM
  match without asking anyone (its docs said it returned `StrictAmbiguityError`
  below HIGH), and keyword verification found no words in `snake_case` tool names,
  so `delete_records` shared nothing with "delete production records". Strict mode
  now verifies every match below EXACT and considers nothing below MEDIUM, a
  MEDIUM or LOW match needs an LLM verifier's approval in every mode, and keyword
  overlap splits names on any non-alphanumeric character, as TypeScript does.
- **The MCP perimeter matches TypeScript #85 (SC-SW-18).** Rate limiting is keyed by
  the client's address (it used the client-chosen `Mcp-Session-Id`, so a fresh id
  per request was never throttled); sessions are validated; `maxConnections` is
  enforced (it was never read); and a loopback-bound server refuses non-loopback
  `Host` names and foreign `Origin`s (DNS rebinding). Loopback means `localhost`,
  `::1` or a dotted-decimal IPv4 literal in 127.0.0.0/8 (`MCPServer.isLoopbackHost`);
  a DNS name never is, so `127.attacker.example` and `127.0.0.1.nip.io`, which a
  rebinding page can resolve to the server, are refused (SW-REV-01).
- **`serve --auth` works, with a bearer token (SC-SW-17).** Nothing could register
  an OAuth client from the CLI, so `serve --auth` rejected every request; scopes
  were never enforced; client secrets were stored as unsalted SHA-256 (the README
  said PBKDF2). OAuth is removed; the bearer token is compared in constant time.
- **The serve token file is never readable by other users (SW-REV-07).** It was
  written by `FileManager.createFile`, which on Linux writes a temporary file with
  mode 0666 minus the umask, renames it into place and only then sets 0600, in a
  `~/.smallchat` created 0755, so another local user could read the token in that
  window; an existing token file was used whatever its mode. It is now created by
  `open(O_CREAT | O_EXCL)` with mode 0600, a missing directory is created 0700, and
  a file that group or other users can access is refused.
- **The audit log can't be forged with a public key, and verifies after eviction
  (SC-SW-16).** The built-in default HMAC key was public, so anyone could forge a
  valid chain; the chain left out `clientId` and `error`; and `verifyChain()`
  started from the zero hash, so it reported tampering on every log that had
  evicted an entry.
- **No unenforced TLS settings (SC-SW-19).** `TLSConfig`'s certificate pinning and
  minimum TLS version were never applied by any transport; the types and the
  README's "TLS Configuration" claim are gone.
- **Channel content can't forge a channel tag (SC-SW-24).** `serializeChannelTag`
  escaped only a blocklist of tag names, so event content could close `</channel>`
  and open a forged `<channel source="trusted-admin">`, as TypeScript fixed in #85.
- **A bridge post can't choose who it is from** (TypeScript's SC-SURF-10 and
  SC-SURF-25). The HTTP bridge took the event's sender from the request body, so
  anyone holding the shared secret could post as any sender the allowlist admits,
  and a meta `sender`, `source` or `user` could put a second, forged identity or
  provenance attribute in the `<channel>` tag. The sender is now the identity of the
  credential, the channel the configured one, and those meta keys are dropped.
  A key followed by a line terminator (`source\n`, `sender\r\n`) is not an identifier
  either (C5-1): ICU's `$` matched before a final line terminator, so since 0.2
  `isValidMetaKey` passed such a key, which an XML reader takes for a second `source`.
- **`ChannelBridgeProtocol.constantTimeEqual` compares full lengths (SC-SW-34).**
  It folded the length difference into 8 bits, so a secret followed by 256 NUL
  bytes matched.
- **The app web view's navigation sandbox runs (SC-SW-11).** The policy method of
  `AppWebViewSandbox` (and of `AppWebView`'s coordinator) took a plain
  `(WKNavigationActionPolicy) -> Void` handler where the SDK's requirement is
  `@MainActor @Sendable`, so it only nearly matched, was never exposed to
  Objective-C, and WebKit never called it: an MCP App's `ui://` HTML could navigate
  the view anywhere. The signatures now match, so cross-origin navigations are
  cancelled; the initial `about:blank` document that `loadHTMLString` creates is
  allowed explicitly, and the coordinator no longer allows everything when it has
  no sandbox.
- **Relayed and inbound text can't forge switchboard protocol (SC-SW-20).** The
  switchboard copies message bodies verbatim, and the parser trusted any line
  starting with `DELIVERED`, `FAILED`, `AGENT` or `INBOUND`, so a message from
  another session could end its own envelope, open one attributed to a trusted
  agent, or confirm a pending ticket; a relayed body could hold extra `RELAY`
  commands. Commands, receipts, listings and envelopes now carry a random
  per-switchboard nonce, bodies sit between nonce markers, and a message from
  another session is always passed on as inbound text, never run as a command. A
  body that contains the nonce is not relayed. The switchboard is still a model, so
  this keeps the parser honest; it does not make the model immune to instructions
  in what it relays.
- **Inbound replies are attributed by Claude Code session name only (SC-SW-20).** A
  reply whose sender matched no session name fell back to the smallchat handle, so
  a session that named itself after an agent's handle was shown as that agent. The
  handle now counts only for a live session whose Claude Code name isn't known yet,
  and a name two sessions share matches nobody (the reply shows as from an unknown
  session).
- **The messenger's own headless sessions are least-privilege (SC-SW-21).**
  `--allowedTools` only pre-approves tools; it never removed any, so under
  `dontAsk` the switchboard could still use whatever the user's settings allowed
  (shell patterns, `WebFetch`, MCP servers), and the stenographer, which reads
  untrusted chat transcripts, had everything but a short denylist. The switchboard
  now has exactly `SendMessage` and `ListAgents` and runs in an empty directory of
  its own; the stenographer has `Read`, `Grep` and `Glob`, none pre-approved, so it
  can read the chat's working directory and nothing else. Neither loads MCP servers
  or the working directory's project and local settings.
- **Prompts and the ledger brief no longer go through argv (SC-SW-36).** A first
  prompt starting with `-` (`--help`) was parsed as a flag, a ledger brief over
  128 KB failed to launch on Linux (`E2BIG`; about 1 MB on macOS), and both were
  visible to every local process in `ps`. Prompts go to stdin as stream-json, and
  system prompts through a 0600 file in a private directory that is removed when
  `claude` exits.
- **Notarization no longer rides on the channel secret (SC-SW-23, XSUITE-13).** The
  messenger signed its notarize and dismiss calls with the objection-channel
  secret, so anything given that secret to post events could also mint tombstones.
  The secret sat in plaintext in `messenger.json`, where an agent's Read tool could
  reach it, and the copyable stenographer command set it inline, so it also landed
  in shell history. The notary secret is now separate, the secrets are kept in the
  Keychain, and the copied command reads them with `security find-generic-password`
  when it runs instead of containing them.
- **The copied stenographer command runs the scoped package (XSUITE-07).** It is
  `npx -y @stenographer/core start …`; the unscoped `stenographer` on npm is an
  unrelated package that would have run with the suite's secrets in its
  environment.
- **A channel event can't redirect the notary secret (XSUITE-13).** The messenger
  posted approvals to whatever `meta.notarize_url` a proposal event named, sending
  the secret along. It now always posts to `http://127.0.0.1:<stenographer REST
  port>` from its settings, and ignores proposal ids that could change the path.
- **Ledger text can't pose as truth markers.** The brief, compaction items,
  invariant records, objection summaries and the stenographer's notes escape the
  frozen `[TB]`/`[UV — UNVERIFIED]` markers and the `## Asserted Truth` heading when
  they appear inside ledger fields or transcript text (truth format v2 rendering
  rule), and identities like `ａｓｓｉｓｔａｎｔ` count as anonymous.

### Known issues

- **On Linux with Swift 6.1, executables that link `SmallChatAgents` need
  `-Xlinker --allow-shlib-undefined`** (SWIFT61-LINUX-OBSERVATION-LINK). 6.1's
  `libswiftObservation.so` references `swift::threading::fatal`, which its
  `libswiftCore.so` does not export, and `SmallChatAgents` uses `@Observable`, so
  linking fails, the test bundle's included (the `swift:6.1` CI job runs
  `swift test -Xlinker --allow-shlib-undefined`). Swift 6.2 and later, and macOS,
  are not affected.
- **`LWWMap` merges are not commutative on ties (SC-SW-29).** Two entries for one
  key with the same timestamp and replica id (two writes in one tick, or a set and
  a remove at the same timestamp) keep whichever side the merge started from, and
  a remove at the timestamp of a set is ignored. Give each write a distinct
  timestamp per replica (a Lamport counter) until this is fixed.
- `smallchat serve` lists the tools of providers launched over stdio, but calling
  them fails: `serve` reaches providers only at an HTTP endpoint.
- The only built-in embedder is the hash embedder (`LocalEmbedder`). An artifact
  compiled by @smallchat/core with its default ONNX embedder loads only with an
  `Embedder` of yours that declares the same fingerprint.
- Not ported from @smallchat/core 1.0: argument coercion, the semantic map (learned
  choices), observer feedback, the decision log, replay and explain. Proof digests
  are per runtime (the proof step texts differ from TypeScript's).
- `SmallChatImportance`, `SmallChatCRDT`, `SmallChatCompaction` and
  `SmallChatShorthand` are ports of smallchat's 0.4-era modules (TS PRs #55–#58),
  not of @shorthand/core 1.0, whose versions of them differ.

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
