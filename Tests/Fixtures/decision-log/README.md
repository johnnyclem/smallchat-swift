# Decision-log fixture

`typescript.jsonl` is a decision log written by `@smallchat/core` 1.0 (`DecisionLog`
with a fixed clock) against a three-tool runtime with a stub judge: a judged
`resolve` (judge-approved), the `judge-feedback` line that corrected it, a
`dispatch-by-id`, and an unresolved `resolve`. `SmallChatRuntimeTests`
verifies its chain with `verifyDecisionLog` and recomputes every hash, so the
two implementations agree on the line shape, the intent digest and the hash.
