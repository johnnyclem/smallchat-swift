# Changelog

All notable changes to the Swift port of smallchat are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
