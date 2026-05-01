# Changelog

All notable changes to the Swift port of smallchat are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
