---
sidebar_position: 6
title: Security
---

# Security

smallchat-swift includes multiple security layers to protect against adversarial inputs, semantic collision attacks, and denial-of-service attempts.

## Threat Model

When an LLM selects tools based on natural language, several attack vectors emerge:

1. **Semantic collision** — Crafting an intent that tricks the runtime into dispatching to an unintended tool
2. **Type confusion** — Providing arguments of unexpected types to exploit tool implementations
3. **Selector shadowing** — A plugin overriding critical system tools
4. **Embedder flooding** — Sending high-entropy intents to exhaust embedding resources
5. **Permission bypass** — Executing privileged tools without authorization

## The dispatch policy

Resolution never runs anything; `dispatchById` runs exactly one named tool. Between
them, one rule set (`evaluateDispatchPolicy`) decides whether a tool chosen from an
intent may run, on every path: pinned phrase, cache hit, vector or overload match,
protocol conformance and decomposed sub-intents.

- **Below HIGH (similarity < 0.85)** a tool runs only after an LLM verifier approves
  it for the intent (`DispatchConfig.requireLLMForSubHighDispatch`, on by default).
  Without a verifying `LLMClient`, MEDIUM and LOW matches are returned as
  `needs-disambiguation` with the candidates.
- **Destructive tools** (MCP annotations: `destructiveHint: true`, or
  `readOnlyHint: false` without `destructiveHint`) run by intent only from a pinned
  phrase or an EXACT similarity (>= 0.95) of the intent's own embedding. A cache hit or
  an overload match is not enough. `treatUnannotatedAsDestructive` applies the same
  rule to tools that declare no annotations.
- **Below LOW (< 0.60)** nothing runs.

A denial is never followed by another way of running the tool. The caller gets the
candidates and calls `dispatchById` with the one the user picks.

## Intent Pinning

The `IntentPinRegistry` protects sensitive tools from semantic collision:

```swift
let pins = IntentPinRegistry()
// Only these phrases resolve to the tool, compared as whole phrases
pins.pin(IntentPin(canonical: "account.delete_account", policy: .exact, aliases: ["delete my account"]))
// The intent's own embedding must reach 0.99 (default for elevated pins: 0.98)
pins.pin(IntentPin(canonical: "bank.transfer_funds", policy: .elevated, threshold: 0.99))
```

With an `exact` pin, an intent that is not one of the pinned phrases does **not**
resolve to the tool, however similar it embeds: "remove my account", "delete my
account now" and "do not delete my account" all miss. Phrases are compared after
Unicode NFKC normalization, lower-casing and whitespace collapsing.

### When to Use Intent Pinning

- Destructive operations (delete, drop, remove)
- Financial operations (transfer, charge, refund)
- Permission changes (grant, revoke, escalate)
- Any tool where false-positive dispatch has serious consequences

## Selector Namespacing

The `SelectorNamespace` prevents plugins from overriding core system selectors:

```swift
let namespace = SelectorNamespace()

// Protect core selectors
namespace.protect("tools:list")
namespace.protect("health:check")
namespace.protect("session:create")

// Later, if a plugin tries to register "tools:list":
// → throws SelectorShadowingError
```

Core classes registered via `registerCoreClass()` automatically have their selectors protected.

## Semantic Rate Limiting

The `SemanticRateLimiter` protects against embedder flooding — many high-entropy,
low-similarity intents sent to exhaust embedding compute. It is opt-in:

```swift
let options = RuntimeOptions(rateLimiter: SemanticRateLimiterOptions(
    windowMs: 60_000,
    maxNovelIntents: 100,
    similarityFloor: 0.3
))
```

Each principal (`ResolveOptions.principal`, `DispatchOptions.principal`) has its own
window. Over the limit, resolution returns the `throttled` outcome with
`retryAfterMs` before embedding the intent; nothing runs.

### Detection Heuristics

- **Novel intent count** — Too many distinct intents in a time window
- **Average similarity** — Legitimate use produces clusters of similar intents; attacks produce random spread
- **Entropy analysis** — High-entropy intent strings are flagged

## Argument Validation

Every call is validated against the tool's JSON Schema `inputSchema` before it runs
(`dispatchById`, intent dispatch and MCP `tools/call` alike):

```swift
// Tool schema: {"type": "object", "properties": {"limit": {"type": "integer"}}, "required": ["query"]}
let result = try await runtime.dispatchById("search/search", args: ["limit": "ten"])
// isError, outcome "invalid-arguments", nothing ran:
//   missing required argument "query"
//   argument "limit" must be integer, got string "ten"
```

`JSONSchemaValidator` supports drafts 2020-12, 2019-09 and 07 (04 and 06 are read as
07). A schema it cannot evaluate (`unevaluatedProperties`, `unevaluatedItems`,
`$dynamicRef`, `$recursiveRef`, a remote `$ref`, an unknown `$schema`, an invalid
`pattern`) makes the tool uncallable rather than unchecked. `format` is not checked.
Overload resolution additionally matches argument types to overload signatures
(`SignatureValidationError`).

## Permission Gating

The `SenderGate` in the Channel module implements a permission relay:

```swift
// 1. Tool execution request arrives
// 2. SenderGate creates a PermissionRequest
// 3. Request is forwarded to the user (via Claude Code UI)
// 4. User approves or denies
// 5. Execution proceeds only if approved

let gate = server.getSenderGate()
// Pending permissions can be inspected
let pending = await server.getPendingPermissions()
```

No tool executes without explicit user approval when the channel is active.

## Metadata Filtering

The `ChannelAdapter` strips sensitive metadata before forwarding events to external consumers:

- Internal debugging fields
- Stack traces
- Provider credentials
- Session tokens

## Audit Logging

With `enableAudit`, the MCP server's `AuditLog` (in SmallChatMCP) records each JSON-RPC request it answers: method, session, client address, outcome, duration and error. Entries form an HMAC-SHA256 chain over every field, under a key you supply (`MCPServerConfig.auditKey`; a random key per server otherwise). Editing a retained entry without the key breaks `verifyChain()`.

The log is in memory: it does not survive a restart, and it does not record channel permission verdicts, selector shadowing or intent pin violations.

## Best Practices

1. **Annotate destructive tools** — `destructiveHint: true`, and pin the phrases that may trigger them with `.exact`
2. **Register core classes** — Use `registerCoreClass()` for system tools
3. **Enable rate limiting** — Set `RuntimeOptions.rateLimiter` and pass a principal per caller
4. **Enable audit logging** — For production deployments
5. **Require a bearer token** — `smallchat serve --auth` for MCP servers reachable beyond loopback (OAuth is not implemented)
6. **Validate at boundaries** — Tool implementations should still validate arguments
7. **Minimize plugin trust** — Don't grant plugins access to protected namespaces
