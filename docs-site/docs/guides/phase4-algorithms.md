---
sidebar_position: 7
title: Phase 4 Algorithm Limitations
---

# Phase 4 Algorithm Limitations

SmallChatCompaction and SmallChatMemex were designed around a "heuristics now, LLM later" principle. Their algorithms are deterministic and dependency-free — they match the TypeScript reference shapes — so richer semantic implementations can land iteratively without changing the public API surface. This guide documents what each heuristic catches, what it misses, and how to upgrade.

## SmallChatCompaction — Contradiction Detection

### What it does

For each `before` item, the verifier checks every `after` item for a literal negation. The check requires two conditions to both be true:

1. **Token overlap**: `Jaccard(before.tokens, after.tokens) >= 0.6` — the items must be about the same thing before the negation check fires.
2. **Negation marker present in `after` but not in `before`**: one of `"not "`, `"no "`, `"never "`, `"isn't "`, `"aren't "`, `"doesn't "`, `"don't "`, `"won't "`.

The algorithm is described in source as "intentionally conservative — meant to catch obvious flips, not philosophical disagreements" (`Compaction.swift:128–130`).

### What it catches

- Direct surface-level reversals: `"The deploy succeeded"` → `"The deploy did not succeed"`
- Explicit negation of a fact when the surrounding tokens are nearly identical

### What it misses

- **Paraphrase negations**: `"The service is healthy"` → `"The service is broken"` — no negation marker, so no flag
- **Scope inversions**: `"All tests pass"` → `"Not all tests pass"` — the marker is present but the substring match fails on `"all tests pass"` vs `"not all tests pass"`
- **Implicit contradictions**: `"Capacity: 100"` → `"Capacity: 50"` — purely numeric, no negation token
- **Cross-sentence negations** where the negated clause isn't a direct substring of the pre-text

### Upgrade path

`CompactionVerifier` accepts a `[Invariant]` array. An LLM-backed or embedding-backed invariant can be injected without touching the verifier's public API:

```swift
let semanticContradictionCheck: CompactionVerifier.Invariant = { before, after in
    // Call your LLM or embedding model to detect semantic contradictions.
    // Return nil if none found, or a violation message.
    return nil
}

let verifier = CompactionVerifier(
    invariants: [semanticContradictionCheck]
)
```

The built-in literal-negation check always runs as Strategy 2; the caller-supplied invariants run as Strategy 3 on top.

---

## SmallChatMemex — Claim Extraction

### What it does

Stage 2 (EXTRACT) splits each source body into sentences using `Shorthand.sentences(in:)` — a crude but stable splitter on `.`, `!`, `?`, and `\n`. Any sentence shorter than `minClaimLength` characters (default 20) is discarded. Each surviving sentence becomes an `ExtractedClaim` with a hardcoded confidence of `0.85`.

### What it catches

- Well-punctuated declarative sentences
- Short imperative statements long enough to pass the length gate

### What it misses

- **Multi-sentence claims**: a fact that spans two sentences is split into two unrelated claims
- **Bullet-pointed or numbered facts**: list items without terminal punctuation may be joined into one oversized "sentence" or dropped
- **Implicit claims**: information expressed as headers, code, or tables is not extracted
- **Confidence variation**: every claim gets `0.85` regardless of evidence quality or source authority

### Upgrade path

The compiled `KnowledgeBase.claims` array can be post-processed or replaced. A typical LLM-augmented workflow:

```swift
let compiler = MemexCompiler()
var kb = compiler.compile(sources)

// Replace heuristic claims with LLM-extracted ones.
let llmClaims = await myLLMExtractor.extractClaims(from: sources)
kb = KnowledgeBase(
    version: kb.version,
    compiledAt: kb.compiledAt,
    sources: kb.sources,
    pages: kb.pages,
    claims: llmClaims,      // swap in semantic claims
    entities: kb.entities,
    relationships: kb.relationships,
    contradictions: kb.contradictions
)
```

---

## SmallChatMemex — Entity Surfacing

### What it does

For each extracted sentence, `surfaceEntities(from:)` walks characters looking for contiguous letter-or-hyphen runs of 3+ characters whose first character is uppercase. Results are deduped while preserving order. The goal stated in source is "recall on names, not perfection" (`MemexCompiler.swift:197`).

### What it catches

- Capitalised proper nouns: `"Alice"`, `"PostgreSQL"`, `"GitHub"`
- Capitalised initialisms that appear as a word: `"API"`, `"MCP"`
- Hyphenated names: `"Smith-Jones"`

### What it misses

- **Lowercase entity names**: `"redis"`, `"swift"`, `"npm"` are invisible to this heuristic
- **Multi-word entities**: `"New York"` → surfaces `"New"` and `"York"` as separate entities
- **Aliased entities**: `"GPT-4"` and `"OpenAI's model"` are not linked
- **Sentence-initial false positives**: the first word of a sentence is always capitalised in English, so common words like `"The"` or `"This"` at sentence starts are surfaced if they reach the length gate

### Upgrade path

Pre-annotate entity spans before calling `compile(_:)`, or replace the `entities` array in the returned `KnowledgeBase` with NER-model output:

```swift
var kb = compiler.compile(sources)

// Replace with NER-model entities.
let nerEntities = await myNERModel.extractEntities(from: sources)
kb = KnowledgeBase(/* ... entities: nerEntities ... */)
```

For the sentence-initial false-positive problem, `MemexConfig.minClaimLength` combined with a custom stop-word list on top is the simplest mitigation without an LLM.

---

## SmallChatMemex — Contradiction Detection

The Memex contradiction pass (`detectContradictions(claims:)`) mirrors the Compaction heuristic with one difference: the Jaccard gate is **0.5** (vs 0.6 in Compaction) because claim texts are typically shorter and sparser than full compaction items.

Limitations and upgrade path are the same as [SmallChatCompaction](#smallchatchatcompaction--contradiction-detection). To replace the result, rebuild the `KnowledgeBase` with a custom `contradictions` array after `compile(_:)` returns.

---

## SmallChatMemex — Stage 3 EMBED (Intentionally Omitted)

The five-stage pipeline (`READ → EXTRACT → EMBED → LINK → EMIT`) skips Stage 3 in the pure compiler: "Stage 3: EMBED — omitted from the pure pipeline; callers wire a real embedder via SmallChatEmbedding when they need it" (`MemexCompiler.swift:102–103`).

Without embeddings, `MemexResolver` falls back to Jaccard similarity over token sets, which has no understanding of synonymy or paraphrase.

### Upgrade path

Post-compile, embed each claim and insert into a vector index:

```swift
import SmallChatMemex
import SmallChatEmbedding

let compiler = MemexCompiler()
let kb = compiler.compile(sources)

let embedder = LocalEmbedder()
let index = MemoryVectorIndex()
for claim in kb.claims {
    let vector = embedder.embed(claim.text)
    index.insert(vector, id: claim.id)
}

// Semantic query — returns claim IDs ranked by cosine similarity.
let queryVector = embedder.embed("deployment failure")
let hits = index.query(queryVector, limit: 5)
```

---

## Summary

| Module | Heuristic | Catches | Misses | Upgrade Hook |
|--------|-----------|---------|--------|--------------|
| SmallChatCompaction | Literal-negation + Jaccard ≥ 0.6 | `"X"` vs `"not X"` | Paraphrase negations, implicit contradictions | `CompactionVerifier.Invariant` closure |
| SmallChatMemex (claims) | Sentence split ≥ 20 chars | Well-punctuated assertions | Multi-sentence claims, bullets, implicit facts | Post-process `KnowledgeBase.claims` |
| SmallChatMemex (entities) | Uppercase 3+ char words | Proper nouns, capitalised acronyms | Lowercase names, multi-word entities | Post-process `KnowledgeBase.entities` |
| SmallChatMemex (contradictions) | Literal-negation + Jaccard ≥ 0.5 | Obvious surface flips | Semantic disagreement, paraphrase | Rebuild `KnowledgeBase.contradictions` |
| SmallChatMemex (EMBED stage) | Omitted | — | Semantic similarity | Wire `SmallChatEmbedding` post-compile |

SmallChatShorthand, SmallChatImportance, and SmallChatCRDT carry no comparable limitations: Shorthand is a primitive, CRDT correctness is mathematically guaranteed, and Importance's three signals (recency exponential decay, co-mention Jaccard centrality, novelty) are straightforward and fully documented in source.
