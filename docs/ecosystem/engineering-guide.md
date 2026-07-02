# The Agent Stack: Engineering Guide (smallchat-swift vantage)

## Sourcing note

Source-verified in this document: everything under **smallchat-swift** (this repo) — read
directly from `Package.swift`, `Sources/`, `Tests/`, `CHANGELOG.md`, `README.md`, and
`docs-site/docs/`. Everything about **AgentVault**, the TypeScript **smallchat** original,
**Stenographer**, and **Short-Hand** is **README-sourced only** (public READMEs and GitHub repo
metadata pages, fetched over plain HTTPS — this session has no API/source access to those four
repos). Where a claim below traces to AgentVault's own ecosystem docs rather than this session's
research, it's labeled accordingly. See
[AgentVault's engineering-guide.md](https://github.com/johnnyclem/AgentVault/blob/main/docs/ecosystem/engineering-guide.md)
for the AgentVault-side companion document this one is meant to sit alongside.

## Component reference

| Project | Role (four-layer thesis) | Confirmed from this repo? |
|---|---|---|
| AgentVault | durable execution body (WASM canisters, wallets, secrets, `MemoryRepo`) | README-sourced only, not checked here |
| **smallchat-swift** (this repo) | reflexes — deterministic, in-process tool dispatch | **Source-verified**, see below |
| smallchat (TS original) | same role, canonical implementation | README-sourced; this repo mirrors it PR-for-PR |
| Stenographer | passive conversation observer, GraphRAG index, MCP server | README-sourced only |
| Short-Hand | working memory — LSM-tree conversation compaction | README-sourced only |

### smallchat-swift's actual public surface (source-verified)

Package targets (`Package.swift`):

| Target | Purpose |
|---|---|
| `SmallChatCore` | Shared types, tool-class/selector type system |
| `SmallChatRuntime` | Dispatch execution engine |
| `SmallChatCompiler` | Compiles tool classes into a dispatch table (`ToolCompiler`) |
| `SmallChatEmbedding` | `LocalEmbedder` — 384-dim local embeddings, ABI-matched to the TS `LocalEmbedder` |
| `SmallChatTransport` | HTTP/NIO transport, auth, streaming, `Loom` protocol support |
| `SmallChatMCP` | MCP server implementation + a generic `MCPClientTransport` (JSON-RPC 2.0 over HTTP/SSE, REST, local, gRPC-stub) |
| `SmallChatChannel` | Claude Code channel integration |
| `SmallChatDream` | (see `SmallChatDream` sources / `smallchat dream` CLI command) |
| `SmallChatShorthand` | **Internal** text primitives: tokens, sentences, Jaccard similarity, FNV-1a hash — see naming-collision finding below |
| `SmallChatImportance` | Three-signal importance detector (recency, centrality, novelty); depends on `SmallChatShorthand` |
| `SmallChatCRDT` | `VectorClock`, `LWWMap`, `ORSet`, `GCounter` — CRDT primitives for multi-agent shared state |
| `SmallChatCompaction` | **Compaction verifier** (not a compactor) — resampling, contradiction, diff-invariants checks; depends on `SmallChatShorthand` |
| `SmallChatMemex` | Knowledge-base compiler: Read → Extract → Embed → Link → Emit; depends on `SmallChatCore` + `SmallChatShorthand` |
| `SmallChat` | Umbrella library |
| `SmallChatUI` / `SmallChatApp` | macOS SwiftUI app |
| `SmallChatCLI` (`smallchat` executable) | `compile`, `serve`, `repl`, `inspect`, `resolve`, `channel`, `dream`, `memex`, `install`, `init`, `setup`, `doctor`, `docs` subcommands (`Sources/SmallChatCLI/Commands/`) |

External dependencies (`Package.swift`, lines 25–29): `swift-argument-parser`, `SQLite.swift`,
`swift-nio`, `swift-collections`. **No dependency, direct or transitive, on any package named after
AgentVault, Stenographer, or Short-Hand.**

## Data flow (unchanged from AgentVault's model, confirmed compatible)

AgentVault's diagram (README-sourced description) has an LLM express intent → SmallChat resolves it
to a tool call deterministically → the call executes → results (optionally) get logged by
Stenographer → history gets compacted by Short-Hand before re-entering context → AgentVault persists
durable state. Nothing in this repo's source contradicts that shape for the SmallChat step
specifically:

```
intent text
  → Canonicalize
  → Embed (384-dim, SmallChatEmbedding.LocalEmbedder)
  → Vector search (cosine similarity, default threshold 0.60 as of 0.5.0)
  → Tier classification: EXACT / HIGH / MEDIUM / LOW / NONE
  → Overload resolution (type-validated dispatch)
  → Cache & execute → result | tool_refinement_needed (with replayable proof trace)
```

(`README.md`, "What's New in 0.5.0" section — this is this repo's real, current pipeline, not a
port-in-progress description.)

## Confirming/refuting AgentVault's engineering-guide claims about SmallChat

AgentVault's own guide is careful to say its SmallChat/Stenographer/Short-Hand material is
README-derived and asks for re-verification against upstream source before integration work. From
this repo's source:

- **Confirmed:** "tool inference is the durable idea," semantic dispatch modeled on
  message-passing/tool-class dispatch, auditable decision trail (`tool_refinement_needed` +
  proof trace). All present and functioning in `SmallChatCompiler`/`SmallChatRuntime`.
- **Confirmed:** distribution via `@smallchat/core` on npm is a TS-repo claim
  (README-sourced); this Swift repo distributes separately as a Swift package
  (`SmallChatCore` et al. products) with no npm involvement — consistent with "ported to Swift,"
  not a shared artifact.
- **Refined:** AgentVault's guide frames SmallChat as a single conceptual component. From this
  side, "SmallChat" is really **two repos kept in lockstep by a porting process** — this repo's
  `CHANGELOG.md` explicitly cites the TS PR number ported for nearly every feature (e.g. "TS PR
  #54" for confidence-tiered dispatch, "TS PR #61" for loom-mcp). Any integration guidance aimed at
  "SmallChat" should specify which repo (or both) it targets, since they are not guaranteed to be
  simultaneously up to date — this repo's own docs (`docs/0.5.0-roadmap.md`) list several TS PRs
  as "Not ported" as of that writing.
- **New, not in AgentVault's guide:** the `SmallChatShorthand` naming collision with Short-Hand
  (see below) and the fact that `SmallChatMCP` already contains a generic, protocol-complete MCP
  client transport that could reach Stenographer today without new protocol work.

## README-vs-reality check performed (playbook §4, SmallChat-specific angle)

The playbook's §4 questions are written for someone sitting in `short-hand` or `stenographer`.
From `smallchat-swift`, the equivalent check is: **does this repo's own module named after the
sibling "Short-Hand" project actually implement (or wrap) Short-Hand's functionality, or is the
name a coincidence?**

Verified by reading `Sources/SmallChatShorthand/Shorthand.swift` directly:

```swift
// MARK: - SmallChatShorthand
//
// Shared text/NLP primitives extracted from compaction, CRDT, and
// importance modules in TS PR #58 (`@shorthand/core`). Kept deliberately
// small and dependency-free so any of those modules can pull from it.
```

Its actual public API is `Shorthand.tokens(in:)` (lowercased word tokens with stop-word
filtering) and `Shorthand.sentences(in:)` (crude `.`/`!`/`?`/`\n` sentence splitting), plus (per
`docs-site/docs/modules/overview.md`) Jaccard similarity and FNV-1a hashing. It has:

- **No** LSM-tree levels (L0–L4).
- **No** importance-weighted eviction/retention policy of its own (that's `SmallChatImportance`,
  a *separate* module that merely *uses* `Shorthand` for tokenization).
- **No** `ActiveEngramStore` or anything resembling one.
- **No** reference to, dependency on, or awareness of the `johnnyclem/short-hand` repository
  anywhere in source, tests, or docs.

**Verdict: the name is a coincidence inherited from the TS repo's own internal package naming
(`@shorthand/core`, extracted in TS PR #58 from smallchat's own compaction/CRDT/importance code),
predating or at least independent of any connection to the sibling `short-hand` project.**
This is exactly the kind of README-vs-reality gap the playbook asks same-repo sessions to catch:
an outside evaluator skimming module names alone could easily (and wrongly) conclude SmallChat
already vendors Short-Hand's compaction engine. It does not.

A secondary asymmetry worth flagging (README-sourced on both sides, so lower confidence, but
notable): Stenographer's README lists Short-Hand, SmallChat, and AgentVault together as an "Agent
Stack" in its roadmap section, while Short-Hand's own README contains no mention of any of the
other three projects. The stack relationship, where documented at all, is currently asserted
one-directionally.

## Duplication/overlap risk check (playbook §2)

- `SmallChatCompaction` (this repo) vs. Short-Hand's compaction engine (README-sourced): **not
  duplicative**. `SmallChatCompaction` verifies that a compaction pass preserved semantics
  (resampling check, contradiction check, diff-invariant check) — it takes pre/post corpora and
  produces a pass/fail `CompactionReport`. It does not perform compaction itself. Short-Hand
  performs the compaction. These are complementary roles that happen to share the word
  "compaction" — a second, lower-stakes naming echo alongside the Shorthand/Short-Hand one.
- `SmallChatCRDT` (this repo) vs. anything in Stenographer/Short-Hand: no overlap found;
  Stenographer's README describes SQLite + vector-index storage with no CRDT/multi-writer
  conflict-resolution story, and Short-Hand's README (README-sourced) does mention "CRDT primitives
  for distributed/multi-agent scenarios" as one of its own features — this is a real potential
  duplication to flag for whoever designs the actual integration, since both repos independently
  ship CRDT primitives for a similar purpose (multi-agent shared state). Neither repo's docs
  currently acknowledge the other's CRDT support.
- `SmallChatMCP` (this repo) vs. Stenographer being an MCP server: not duplicative, potentially
  composable — see integration roadmap below.

## Integration roadmap, from this repo's side

Phased by effort, cheapest first:

1. **MCP client wiring (low effort, not started).** `SmallChatMCP.MCPClientTransport` already
   speaks MCP JSON-RPC 2.0 over HTTP/SSE generically. Standing up a Stenographer-specific tool
   mapping (e.g. wrapping Stenographer's `search_conversation`/`get_decisions` MCP tools,
   README-sourced names, unverified against Stenographer source) behind a `SmallChatChannel`- or
   `SmallChatDream`-style adapter would be the lowest-risk way to let a smallchat-swift-based agent
   query Stenographer's index. No transport-layer work needed; only a schema/tool mapping.
2. **Compaction-verifier pairing (design spike, not started).** Prototype feeding Short-Hand's
   L0–L4 compacted output through `SmallChatCompaction`'s three-strategy verifier as an
   independent correctness gate. Requires agreeing on a shared `CompactionItem`-shaped interchange
   format between the two ecosystems — currently undefined on either side.
3. **CRDT reconciliation (needs cross-repo source review before any code).** Before either
   project extends its CRDT support, someone with source access to both `smallchat-swift`/`smallchat`
   and `short-hand` should compare `SmallChatCRDT`'s `VectorClock`/`LWWMap`/`ORSet`/`GCounter` against
   Short-Hand's CRDT primitives (README-sourced, unverified) to check for duplicate effort or an
   opportunity to share one implementation.
4. **Naming disambiguation (documentation only, cheap, not started).** Add a one-line
   cross-reference in `SmallChatShorthand`'s doc comment and in `docs-site/docs/modules/overview.md`
   noting explicitly that it is unrelated to the sibling `short-hand` project, to prevent future
   confusion — this costs nothing and directly closes the gap identified above.

## Risks

- All cross-repo claims above about AgentVault/Stenographer/Short-Hand are README-level; none of
  their actual source, MCP tool schemas, or CRDT implementations have been verified from this
  session. Treat the "duplication risk" and "integration roadmap" items as hypotheses to confirm,
  not settled findings.
- This repo has no CI (`.github/` absent) and no `LICENSE` file despite an MIT badge in
  `README.md` — low but real risk for anyone planning to depend on it as shared infrastructure.
- smallchat-swift trails the TS original on a per-PR basis (`docs/0.5.0-roadmap.md` lists several
  TS PRs as "Not ported" at time of writing); any integration spec written against "SmallChat"
  should pin which repo/version it means.

## Cross-links

- [`executive-summary.md`](./executive-summary.md) (this directory) — condensed findings.
- [AgentVault: executive-summary.md](https://github.com/johnnyclem/AgentVault/blob/main/docs/ecosystem/executive-summary.md)
- [AgentVault: engineering-guide.md](https://github.com/johnnyclem/AgentVault/blob/main/docs/ecosystem/engineering-guide.md)
- Stenographer and Short-Hand equivalents: not yet published at time of writing; link here once
  available.
