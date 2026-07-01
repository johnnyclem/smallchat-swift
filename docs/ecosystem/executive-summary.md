# The Agent Stack: Executive Summary (smallchat-swift vantage)

## Sourcing note

This document was produced from a session scoped to `github.com/johnnyclem/smallchat-swift`
only. Claims about **this repo** (smallchat-swift) are verified directly against source,
`Package.swift`, `CHANGELOG.md`, and git history. Claims about **AgentVault**, **smallchat**
(the TypeScript original), **Stenographer**, and **Short-Hand** are sourced from their public
READMEs and GitHub repo metadata (fetched over HTTPS, no API/source access) — these are marked
"README-sourced" below and should be re-verified by a session with source access before being
treated as fact. This document also reads and extends
[AgentVault's `docs/ecosystem/executive-summary.md`](https://github.com/johnnyclem/AgentVault/blob/main/docs/ecosystem/executive-summary.md)
and
[`engineering-guide.md`](https://github.com/johnnyclem/AgentVault/blob/main/docs/ecosystem/engineering-guide.md),
which are themselves explicit that their own SmallChat/Stenographer/Short-Hand claims are
README-derived, not source-verified. Nothing here contradicts that document's methodology; it adds
a second, source-verified data point from the opposite side of the graph.

## The four-layer thesis, as seen from here

AgentVault's docs propose:

```
 AgentVault        →  the body        (durable, on-chain execution + wallet + secrets)
 SmallChat         →  the reflexes    (deterministic tool selection, no schema bloat)
 Stenographer      →  the memory      (passive conversation observer + GraphRAG index)
 Short-Hand        →  working memory  (compacts raw history into an LLM-sized context frame)
```

**The "reflexes" label for SmallChat holds up under direct inspection.** smallchat-swift's public
API (`SmallChatCompiler`, `SmallChatRuntime`, confidence-tiered dispatch — `EXACT/HIGH/MEDIUM/LOW/NONE`
— see `README.md`) is exactly what "deterministic tool selection, no schema bloat" describes. This
is a real, working, tested library, not aspirational.

**One important correction to the mental model: smallchat-swift is not an independent evaluation of
"SmallChat's role" — it is a 1:1 architectural port of the TypeScript original**
(`github.com/johnnyclem/smallchat`, README-sourced), tracked feature-for-feature against that
repo's PR numbers (e.g. this repo's `CHANGELOG.md` cites "TS PR #54", "TS PR #57", "TS PR #61" for
its own features). Anything true of "SmallChat's role" architecturally is inherited from the TS
repo, not independently designed here. Treat this repo as a second data point on the same design,
not a different project.

## Key finding: a naming collision, not an integration

The single most useful thing this repo's source can tell the ecosystem story that the AgentVault-side
docs could not: **smallchat-swift ships a module literally named `SmallChatShorthand` — and it has
nothing to do with the sibling "Short-Hand" project.**

- `SmallChatShorthand` (`Sources/SmallChatShorthand/Shorthand.swift`) is a small, dependency-free
  text-primitives module: word tokenization, sentence splitting, Jaccard similarity, FNV-1a hashing.
  It was ported from the TS smallchat repo's own internal `@shorthand/core` package (extracted in
  "TS PR #58" from smallchat's own compaction/CRDT/importance modules, per this repo's
  `CHANGELOG.md`). It's an internal utility library for SmallChat itself.
- The sibling **Short-Hand** project (`github.com/johnnyclem/short-hand`, README-sourced) is a
  much larger, unrelated system: LSM-tree-style five-level (L0–L4) progressive compaction of
  conversation history, importance scoring, an `ActiveEngramStore`, tombstones, and optional
  LLM-assisted summarization.
- These two things share a name fragment and *nothing else* — no shared code, no shared API shape,
  no cross-reference in either repo. Short-Hand's own README (fetched directly, README-sourced)
  contains **zero** mentions of SmallChat, Stenographer, or AgentVault, despite Stenographer's
  README (README-sourced) listing Short-Hand, SmallChat, and AgentVault together as companion
  projects in an "Agent Stack" roadmap section. That's an asymmetric claim: Stenographer's docs
  assert the relationship; Short-Hand's docs don't reciprocate it. Anyone building against this
  stack should not assume the sibling projects are mutually aware of each other just because one
  side's README says so.
- Practical implication: if an integrator sees "`smallchat` already has a `Shorthand` module" and
  assumes that means Short-Hand's compaction is already vendored into SmallChat, that assumption is
  wrong. They are unrelated packages with a coincidental name.

## What's actually wired vs. aspirational, from this side

- **Wired:** Nothing. A whole-repo case-insensitive search for `agentvault`, `stenograph`,
  `short-hand`, and `shorthand` turns up matches only for this repo's own `SmallChatShorthand`
  module (see naming-collision finding above) and the docs describing it. `Package.swift`'s
  dependency list is exclusively Apple/community Swift packages
  (`swift-argument-parser`, `SQLite.swift`, `swift-nio`, `swift-collections`) — no reference to any
  sibling project, direct or transitive.
- **Plausible, not built:** `SmallChatMCP` includes a generic `MCPClientTransport` (JSON-RPC 2.0
  over HTTP/SSE) capable of talking to *any* MCP server — including, in principle, Stenographer,
  which is itself an MCP server (README-sourced). No Stenographer-specific adapter exists; this is
  a generic capability that happens to make the integration path low-effort, not evidence the
  integration exists.
  `SmallChatCompaction` is a **compaction verifier** (checks that a compaction pass preserved
  semantics via resampling, contradiction-detection, and diff-invariants), not a compactor. It is
  functionally complementary to — not duplicative of — Short-Hand's actual LSM-tree compaction
  engine (README-sourced): SmallChatCompaction could plausibly verify Short-Hand's compaction
  output, but no such wiring exists today and neither project's docs currently propose it.
- **Aspirational only:** everything else in the four-layer thesis beyond "these are four projects
  by the same author with complementary design goals."

This matches AgentVault's own conclusion (from the opposite side of the graph): the "ecosystem" is
currently a shared design philosophy and naming lineage, not working cross-repo code.

## Maturity signals (this repo, source-verified)

- 77 commits, `2026-03-26` → `2026-06-09` (most recent as of this writing); active but not
  under continuous development at time of writing.
- 38 test files across module targets (`Tests/`); no CI workflow found (`.github/` does not exist
  in this repo) — test suite is not automatically enforced on push/PR.
- README badges claim an MIT license, but no `LICENSE` file exists at the repo root — a
  paperwork gap worth closing, unrelated to the ecosystem question but a real maturity ding.

## Recommendations

1. **Do not conflate `SmallChatShorthand` with Short-Hand** in any integration doc, prompt, or
   onboarding material for either project — rename risk or doc-clarity footnotes are cheap
   insurance against a confused integrator wiring the wrong thing.
2. **The MCP-client path is the lowest-effort real integration**, if anyone wants one:
   `SmallChatMCP`'s existing generic transport could point at a running Stenographer server with no
   new protocol work, only a Stenographer-specific tool/resource mapping.
3. **Verifier/compactor pairing is worth a design spike**, not immediate work: feed Short-Hand's
   L0–L4 output through `SmallChatCompaction`'s three-strategy verifier as an independent
   correctness check. This is a genuinely novel integration idea not present in the AgentVault-side
   docs, because it only becomes visible once you've read what `SmallChatCompaction` actually does.
4. **Close the CI/LICENSE gaps** before treating this repo as production-grade infrastructure for
   any of the other three projects to depend on.

See [`engineering-guide.md`](./engineering-guide.md) in this directory for the component-level
detail and file references behind these findings.
