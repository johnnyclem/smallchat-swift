---
sidebar_position: 6
title: smallchat vs. Nexus
---

# smallchat vs. Nexus

Short answer: they solve different problems at different layers of the agent stack. Nexus is an enterprise knowledge layer; smallchat is a tool dispatch layer. They are not competitors — they can compose.

## What Nexus Is

Nexus is a managed, server-side knowledge engine (not a retrieval system). It pre-compiles enterprise document corpora into typed, governed artifacts shaped for specific tasks, queried via its KnowQL language. The core pitch is moving reasoning *upstream* from inference time to compilation time, with RBAC, citations, versioning, and PII tagging built in.

Target customer: financial services, healthcare, legal, enterprise SaaS — organizations with Box-scale document corpora and hard compliance requirements.

## What smallchat Is

smallchat is a **semantic tool dispatch compiler**. It does not compile knowledge — it compiles *which tool to call* from a natural-language intent. The model is Objective-C message-passing translated to agent toolchains: intents are messages, tools are methods, the compiled `.toolkit.json` is the dispatch table.

The data substrate is the agent's tool registry, not enterprise documents.

## Where the Confusion Comes From

Both projects use the word "compile" and both reduce token usage. But the reduction happens at different places:

| | What gets pre-compiled | Token savings from |
|---|---|---|
| **Nexus** | Answer-shaped knowledge artifacts | Model doesn't sift chunks at inference |
| **smallchat** | Tool dispatch decisions | Model doesn't load every tool schema into context |

Nexus replaces the **retrieval / RAG layer**. smallchat replaces (or compresses) the **tool-selection layer**. A production agent needs both — "what do I know" and "what can I do."

## The Composable Story

A Nexus-backed agent still has to decide which tool to invoke — KnowQL query vs. Slack post vs. file write. That decision is exactly smallchat's territory.

```
Agent intent: "summarize compliance docs for Q3"
        │
        ▼
  smallchat dispatch → resolves to: nexus_query(topic="Q3 compliance")
        │
        ▼
  Nexus returns governed, pre-compiled artifact
        │
        ▼
  Agent uses artifact to compose response
```

"Use Nexus for what the agent knows, smallchat for what the agent does" is a clean division if you ever need to articulate it to an enterprise buyer who runs both.

## Positioning Note

The practical risk is not technical overlap — it is narrative overlap. Vendors framing enterprise context management as a managed cloud service absorb mindshare. If you pitch smallchat to a buyer who just read about Nexus, they may not bother distinguishing layers without a clear frame.

**Lean on:**
- **Dispatch, not retrieval** — smallchat operates on the tool registry, not the document corpus
- **Local / self-custody** — smallchat runs in the agent process as a library, with no SaaS dependency
- **Compile time, not inference time** — the `.toolkit.json` artifact is generated once and loaded at startup, not called over the network per request

Avoid positioning smallchat as a "context engineering" solution without qualification — that phrase has been absorbed by the knowledge-layer narrative. "Semantic tool dispatch compiler" is more precise and harder to conflate.
