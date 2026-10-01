---
sidebar_position: 1
title: CLI Commands
---

# CLI Commands

The `smallchat` CLI provides commands for compiling, serving, testing, and exploring tool dispatch.

## Usage

```bash
swift run smallchat <command> [options]
```

Or if installed globally:

```bash
smallchat <command> [options]
```

## Commands

### `compile`

Compile tool manifests into an artifact of format 1.0 (the @smallchat/core format).

```bash
swift run smallchat compile --source <path> [-o <output>]
```

| Option | Description | Default |
|--------|-------------|---------|
| `--source`, `-s` | Path to MCP config, manifest directory, or single manifest | current directory |
| `--output`, `-o` | Output artifact path | `tools.toolkit.json` |
| `--duplicate-threshold` | Distinct tools at or above this cosine similarity are duplicates: a compile error | `0.95` |
| `--allow-duplicates` | Keep duplicates (listed in the artifact) instead of failing | `false` |
| `--collision-threshold` | Similarity above which selector pairs are reported as collisions | `0.89` |
| `--strict` | Treat selector collisions as compile errors | `false` |
| `--dims` | Dimensions of the hash embedder | `384` |
| `--semantic-overloads` | Group similar tools as overloads of one selector | `false` |

**Examples:**

```bash
# Compile from MCP config
swift run smallchat compile --source ~/.mcp.json

# Compile from manifest directory
swift run smallchat compile --source ./manifests/ -o my-tools.toolkit.json
```

---

### `serve`

Serve a toolkit as an MCP server over Streamable HTTP (endpoint `/mcp`).

```bash
swift run smallchat serve --source <path> [options]
```

| Option | Description | Default |
|--------|-------------|---------|
| `--source`, `-s` | Manifest directory, manifest file, or compiled artifact | Required |
| `--port`, `-p` | Listen port | `3001` |
| `--host` | Bind address | `127.0.0.1` |
| `--db-path` | SQLite database path for sessions | `smallchat.db` |
| `--provider` | Serve one provider's tools under their upstream names | all, as `<provider>__<tool>` |
| `--no-resolve-tool` | Do not list the read-only `smallchat_resolve` meta-tool | listed |
| `--auth` | Require a bearer token (`SMALLCHAT_MCP_TOKEN` or the token file) | `false` |
| `--auth-token-file` | Token file, created with a random token (mode 0600) if missing | `~/.smallchat/serve-token` |
| `--rate-limit` | Enable per-address rate limiting | `false` |
| `--rate-limit-rpm` | Requests per minute limit | `600` |
| `--audit` | Enable the in-memory audit log | `false` |
| `--max-connections` | Maximum concurrent connections | `1000` |
| `--session-ttl` | Session TTL in hours | `24` |

**Examples:**

```bash
# Basic server
swift run smallchat serve --source ./manifests --port 3001

# Exposed beyond loopback: require a token
swift run smallchat serve --source ./manifests \
  --port 8080 --host 0.0.0.0 \
  --auth --rate-limit --rate-limit-rpm 1000 --audit
```

---

### `channel`

Start a Claude Code channel server (stdio JSON-RPC).

```bash
swift run smallchat channel --name <name> [--two-way] [--reply-tool <name>] [--permission-relay] \
  [--instructions <text>] [--sender-allowlist <a,b>] [--http-bridge] [--http-bridge-host <host>] [--http-bridge-port <port>]
```

This launches a stdio MCP channel server that Claude Code starts: it pushes injected
events into the session, reads from stdin, writes to stdout, and exits when stdin
closes.

| Option | Description |
|--------|-------------|
| `--two-way` | List a reply tool so Claude Code can answer on the channel |
| `--reply-tool` | Name of the reply tool (default `reply`) |
| `--permission-relay` | Receive Claude Code's permission requests (logged to stderr; verdicts are sent from code) |
| `--instructions` | Instructions returned in `initialize` |
| `--sender-allowlist` | Comma-separated senders whose events are accepted (default: everyone) |
| `--http-bridge` | Serve `POST /event` and `GET /health`; needs the shared secret in `SMALLCHAT_CHANNEL_SECRET` |
| `--http-bridge-host`, `--http-bridge-port` | Bridge address (default `127.0.0.1:3002`) |

See [Claude Code Integration](../guides/claude-code-integration).

---

### `resolve`

Show how an intent resolves against a compiled artifact: the same resolution an intent
dispatch and `smallchat_resolve` make. Nothing runs.

```bash
swift run smallchat resolve <artifact> <intent> [--json]
```

| Argument | Description |
|----------|-------------|
| `artifact` | Path to a compiled `.toolkit.json` file (format 1.0) |
| `intent` | Natural language intent string |
| `--json` | Print the `ResolutionProof` as JSON |

**Examples** (against `Tests/Fixtures/spec/artifact/fixtures/minimal.v1.json`):

```bash
swift run smallchat resolve minimal.v1.json "jot something down"
# Intent:  "jot something down"
# Outcome: resolved (tier exact, decision ranked)
# Chosen:  notes/create_note (serve name notes__create_note)
# Candidates:
#   1.0000  exact   notes/create_note
#   0.7346  low     notes/delete_note
# Proof:   022f37af…
# Nothing was executed.

swift run smallchat resolve minimal.v1.json "permanently delete the note"
# Outcome: needs-disambiguation (tier high, decision destructive-needs-exact)
# Reason:  notes/delete_note is destructive: it runs only by exact tool id, a pinned
#          phrase, or EXACT similarity (>= 0.95); got similarity 0.909
```

---

### `inspect`

Examine a compiled artifact (format 1.0). It is validated first, and its content hash
recomputed.

```bash
swift run smallchat inspect <artifact> [--selectors] [--providers] [--collisions] [--embeddings]
```

**Example:**

```bash
swift run smallchat inspect minimal.v1.json
# ToolKit artifact: minimal.v1.json
# Format: 1.0
# Content hash: eb0df050… (verified)
# Stats:
#   Tools: 2
#   Selectors: 3
#   Providers: 1
#   Collisions: 1
#   Duplicates: 0
```

---

### `init`

Scaffold a new smallchat project from a template.

```bash
swift run smallchat init <name> [--template <template>]
```

| Option | Description | Default |
|--------|-------------|---------|
| `--template`, `-t` | Project template | `basic` |

Available templates:

| Template | Description |
|----------|-------------|
| `basic` | Minimal project with one tool class |
| `agent` | Agent project with multiple providers and streaming |
| `server` | MCP server project with auth and persistence |

**Examples:**

```bash
# Basic project
swift run smallchat init my-tools

# Agent project
swift run smallchat init my-agent --template agent

# MCP server project
swift run smallchat init my-server --template server
```

---

### `docs`

Generate Markdown documentation from a compiled artifact.

```bash
swift run smallchat docs <artifact> [-o TOOLS.md]
```

Produces a Markdown file (`--output`, default `TOOLS.md`) documenting:
- All registered tools with descriptions
- Input schemas and parameter types
- Provider groupings
- Selector mappings

---

### `repl`

Interactive shell for testing resolution against a compiled artifact. Nothing runs.

```bash
swift run smallchat repl <artifact>
```

Type an intent to see its resolution (outcome, tier, decision, chosen tool,
candidates, proof digest).

**Example session:**

```
smallchat> jot something down
Intent:  "jot something down"
Outcome: resolved (tier exact, decision ranked)
Chosen:  notes/create_note (serve name notes__create_note)
Candidates:
  1.0000  exact   notes/create_note
  0.7346  low     notes/delete_note
Proof:   022f37af…
Nothing was executed.

smallchat> :stats
Artifact:
  Format:     1.0
  Embedder:   hash smallchat-hash-v1 (16 dims, normalized)
  Tools:      2
  Selectors:  3
  ...

smallchat> :quit
```

REPL commands (prefixed with `:`):

| Command | Description |
|---------|-------------|
| `:providers`, `:p` | List providers and their tool counts |
| `:selectors`, `:s` | List selectors and the tools they point to |
| `:stats` | Show the artifact's format, embedder, counts and hash |
| `:help`, `:h` | Show available commands |
| `:quit`, `:q` | Exit the REPL |

---

### `doctor`

Run diagnostics to verify your environment.

```bash
swift run smallchat doctor [--db-path smallchat.db]
```

Checks:
- The Swift runtime and platform
- `LocalEmbedder` produces a vector
- `MemoryVectorIndex` finds an inserted vector
- Cosine similarity (Accelerate on Apple platforms, scalar elsewhere)
- Canonicalization
- Whether the session database (`--db-path`, used by `serve`) exists

---

### `setup`

Interactive wizard: finds your MCP servers, compiles them into a toolkit, and reports
the bundled loom-mcp manifest.

```bash
swift run smallchat setup [--no-interactive] [-o tools.toolkit.json]
```

---

### `install`

Print the install plan for a registry entry or a bundle. It is a dry run: nothing is
written and no install command runs.

```bash
swift run smallchat install examples/registry/github.json [--json]
```

---

### `dream`

Recompile a toolkit using what Claude session logs and memory files (`CLAUDE.md`) say
about your tools: it scans memory for tool mentions, counts tool usage in session logs,
prioritizes tools, compiles, and keeps earlier artifact versions for rollback.

```bash
swift run smallchat dream [--source <manifests>] [--output tools.toolkit.json] [--log-dir <dir>] \
  [--config <file>] [--auto] [--dry-run] [--max-versions 5]
```

`--dry-run` only analyzes; `--auto` replaces the current artifact with the new one. The
artifact is compiled with the built-in hash embedder whatever `--embedder` says.

---

### `memex`

Compile text sources into a cross-referenced knowledge base (separate from tool
dispatch).

```bash
swift run smallchat memex compile notes/*.md -o memex.json
swift run smallchat memex query memex.json "deployment" [--limit 5]
swift run smallchat memex lint memex.json
swift run smallchat memex inspect memex.json
swift run smallchat memex export memex.json -o memex-wiki
```

See [Phase 4 Algorithm Limitations](../guides/phase4-algorithms) for what the
extraction heuristics catch and miss.
