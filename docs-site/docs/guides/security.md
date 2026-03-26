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

## Intent Pinning

The `IntentPinRegistry` protects sensitive selectors from semantic collision:

```swift
// Only exact "delete:account" intent resolves — no similar intents
registry.pin("delete:account", policy: .exact)

// Require 0.99+ similarity (instead of default 0.75)
registry.pin("transfer:funds", policy: .elevated(threshold: 0.99))
```

With exact pinning, even an intent with 0.98 cosine similarity to "delete:account" will **not** resolve to that tool. The user must express the exact canonical form.

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

The `SemanticRateLimiter` protects against embedder flooding — attacks that send many high-entropy, low-similarity intents to exhaust embedding compute:

```swift
let options = SemanticRateLimiterOptions(
    windowSize: .seconds(60),
    maxUniqueIntents: 100,
    minAverageSimilarity: 0.3
)
```

When the rate limiter detects a flood pattern (many unique intents with low mutual similarity), it throws `VectorFloodError` and blocks further intents from that source.

### Detection Heuristics

- **Unique intent count** — Too many distinct intents in a time window
- **Average similarity** — Legitimate use produces clusters of similar intents; attacks produce random spread
- **Entropy analysis** — High-entropy intent strings are flagged

## Type Validation

Overload resolution includes strict type validation via `SignatureValidationError`:

```swift
// Tool expects: search(query: String, limit: Int)
// Attack sends: search(query: ["'; DROP TABLE --"], limit: "not-a-number")
// → SignatureValidationError: type mismatch
```

This prevents type confusion attacks where adversarial arguments could exploit tool implementations that don't validate their inputs.

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

The `AuditLog` (in SmallChatMCP) records all security-relevant events:

- Authentication attempts (success/failure)
- Rate limit triggers
- Permission requests and verdicts
- Selector shadowing attempts
- Intent pin violations

Logs are stored in SQLite for queryability and compliance.

## Best Practices

1. **Pin sensitive selectors** — Use `.exact` policy for destructive operations
2. **Register core classes** — Use `registerCoreClass()` for system tools
3. **Enable rate limiting** — Set appropriate thresholds for your workload
4. **Enable audit logging** — For production deployments
5. **Use OAuth** — For MCP server deployments exposed to networks
6. **Validate at boundaries** — Tool implementations should still validate arguments
7. **Minimize plugin trust** — Don't grant plugins access to protected namespaces
