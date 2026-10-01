---
sidebar_position: 5
title: Resolution Pipeline
---

# Resolution Pipeline

Resolution turns a natural-language intent into **at most one** tool. It is the
equivalent of `objc_msgSend`'s method lookup, split from the call itself:

- `resolve(intent)` decides and runs nothing. It returns a `Resolution` with an
  outcome (`resolved`, `needs-disambiguation`, `unresolved` or `throttled`), the tier,
  the chosen canonical tool id (`<providerId>/<toolName>`), the ranked candidates and a
  `ResolutionProof`.
- `dispatchById(toolId, args:)` validates the arguments and runs exactly that tool.
- `dispatch(intent, args:)` is `resolve` (with the cache) followed by `dispatchById` of
  the chosen tool. When resolution does not settle on one tool, nothing runs.

The rules are those of @smallchat/core 1.0, and smallchat-swift runs its conformance
vectors (`Tests/Fixtures/spec/resolve`, `spec/ranking`) in `swift test`.

## Pipeline steps

### 1. Validate the intent

Null bytes and control characters are stripped and length is capped
(`validateIntent`). An empty intent is an error.

### 2. Pinned phrase

If the intent is, as a whole phrase, the canonical or an alias of an
[intent pin](#intent-pins) (`normalizePinPhrase`: Unicode NFKC, lower case, collapsed
whitespace), its tool is the only candidate, and it still goes through the dispatch
policy.

### 3. Cache (intent dispatch only)

`dispatch` (and `resolve` with `ResolveOptions(learn: true)`) consult the
`ResolutionCache`, keyed by `intentKey(intent)`: the whole intent text up to case,
Unicode NFC form and whitespace. Two intents that differ in any word, "not" included,
never share an entry. Only calls without arguments use it. A hit is judged by the
dispatch policy again, and strict mode ignores cached resolutions below EXACT.

### 4. Rate limit (opt-in)

With `RuntimeOptions.rateLimiter` set, a principal that sends too many novel intents
in a window gets the `throttled` outcome with `retryAfterMs`, before the intent is
embedded.

### 5. Embed and search

The intent is embedded on its own; its vector is never interned into the selector
table or the index. The vector index returns the 5 nearest tool selectors at or above
the candidate floor: LOW (0.60), or MEDIUM (0.75) in strict mode. Scores are cosine
similarities quantized to 1e-4 (`quantizeScore`), and equal scores are ordered by
tool id (`rankedBefore`).

### 6. Overloads and protocol conformance

When the call carries arguments and a matched selector has overloads, the overload
that accepts those arguments is the candidate. Protocol conformance is tried only when
no selector matched.

### 7. Pin gate

A tool with an intent pin is never a candidate for an intent its pin refuses: an
`exact` pin accepts only its pinned phrases, an `elevated` pin only a similarity of the
intent's own embedding at or above its threshold (0.98 by default). Excluded candidates
are listed in the proof.

### 8. Tier

| Tier | Score | |
|------|-------|---|
| `.exact` | >= 0.95 | |
| `.high` | >= 0.85 | |
| `.medium` | >= 0.75 | needs verification |
| `.low` | >= 0.60 | needs verification; `dispatch` may decompose it |
| `.none` | < 0.60 | never runs |

`DispatchConfig(thresholds:)` changes the bars; `DispatchConfig.miniLM` is a preset
for lower-contrast sentence embedders. With nothing above the floor, the outcome is
`unresolved` with the nearest tools (from 0.3 up) as refinement options.

### 9. Verification

Below HIGH (below EXACT in strict mode) the best candidate, then each alternate, must
pass verification: the tool's required parameters are present when the arguments are
known, the intent shares keywords with the tool's name and description, and below HIGH
an LLM verifier approves it. With `requireLLMForSubHighDispatch` (the default) and no
verifying `LLMClient` (`NoOpLLMClient` has `providesVerification == false`), a MEDIUM
or LOW match is needs-disambiguation.

### 10. Dispatch policy

`evaluateDispatchPolicy` is the same rule set on every path (pinned phrase, cache hit,
vector and overload candidates, protocol conformance, decomposed sub-intents):

1. A call by exact tool id is always allowed.
2. Intent pins as in step 7.
3. A destructive tool runs by intent only from a pinned phrase or an EXACT similarity
   of the intent's own embedding. A tool is destructive when its MCP annotations say
   `destructiveHint: true`, or `readOnlyHint: false` without `destructiveHint`
   (`isDestructive`); `treatUnannotatedAsDestructive` extends this to tools with no
   annotations.
4. Below HIGH, only with an LLM verifier's approval (unless
   `requireLLMForSubHighDispatch` is off).
5. Below LOW, never.

A denial is the `needs-disambiguation` outcome with the candidates as a
`ToolRefinement`; no other path is tried. Allowed vector resolutions of tools that are
neither pinned nor destructive are cached.

### 11. Run (`dispatchById`)

The arguments are validated against the tool's JSON Schema `inputSchema`
(`JSONSchemaValidator`; drafts 2020-12, 2019-09 and 07). A failing call runs nothing
and returns outcome `invalid-arguments` with the errors. Otherwise the call digest
(`callDigest(toolId:arguments:)`, SHA-256 over the RFC 8785 canonical JSON of the tool
id and arguments) is recorded in the proof and exactly that tool runs. A task
cancelled before the tool starts gets outcome `aborted`.

## Results

`dispatch` and `dispatchById` return a `ToolResult` whose `metadata` holds
(`DispatchMetadataKey`):

| Key | Value |
|-----|-------|
| `outcome` | `resolved`, `needs-disambiguation`, `unresolved`, `throttled`, `invalid-arguments`, `aborted`, `not-dispatched` |
| `toolId` | The tool that ran (or would have) |
| `proof` | The `ResolutionProof` |
| `callDigest` | Canonical call digest of what ran |
| `refinement` | `ToolRefinement` with near matches (by tool id) |
| `validationErrors` | `[ValidationError]` for `invalid-arguments` |

Only `resolved` means a tool ran; every other outcome is `isError` and ran nothing. A
tool that ran and failed is `isError` with outcome `resolved`.

## Strict mode

`DispatchConfig(strict: true)` verifies every match below EXACT (HIGH included) and
considers nothing below MEDIUM. It does not make a MEDIUM match run: below HIGH the LLM
verifier rule applies in every mode.

## Proofs and determinism

Each resolution records its steps, candidates (eligible and excluded), guards, call
digest, artifact hash and embedder fingerprint in a `ResolutionProof`. `proofDigest`
is a SHA-256 over the proof without its timings.

For the same artifact, embedder and runtime state (registered classes, intent pins,
resolution cache, options), resolving the same intent text yields the same outcome,
chosen tool, candidate order and `proofDigest`; intents resolved earlier do not enter
into it. This does not cover an LLM verifier's or decomposer's answers, an opted-in
rate limiter's window, or float differences between platforms larger than half a score
quantum. Proof digests are per runtime: the TypeScript runtime's step texts differ, so
compare outcomes, tool ids and tiers across the two.

## Decomposition

`dispatch` (not `resolve`) may ask the `LLMClient` to split a LOW-tier or unmatched
compound intent into sub-intents. Each sub-intent is dispatched through the same
pipeline and policy, up to `maxDecompositionDepth` levels and `maxSubDispatches`
sub-intents; sub-intents past the cap are `not-dispatched`. `NoOpLLMClient` never
decomposes.

## Streaming variant

`dispatchStream` resolves first and streams only an allowed resolution;
`dispatchStreamById` streams exactly one tool. They yield `DispatchEvent` values:

```swift
.resolving(intent: "find flights")
.toolStart(toolName: "search_flights", providerId: "flights", confidence: 0.94, selector: "flights.search_flights")
.chunk(content: ..., index: 0)
.done(result: ToolResult(...))
```

The execution phase picks the richest tier the tool supports: `InferenceIMP` (token
deltas), `StreamableIMP` (chunks), or a single-shot `ToolIMP` wrapped in `.done`.

## Intent pins

```swift
let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder(),
    options: RuntimeOptions(intentPins: [
        IntentPin(canonical: "bank.transfer", policy: .exact, aliases: ["transfer funds"]),
    ])
)
```

`"transfer funds"` resolves to the pinned tool; `"do not transfer funds"` and
`"transfer funds to bob"` do not match the pin, and the pinned tool is not a candidate
for them.
