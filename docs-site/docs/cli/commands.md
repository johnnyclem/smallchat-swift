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

Compile tool manifests into a dispatch artifact.

```bash
swift run smallchat compile --source <path> [-o <output>]
```

| Option | Description | Default |
|--------|-------------|---------|
| `--source`, `-s` | Path to MCP config, manifest directory, or single manifest | Required |
| `--output`, `-o` | Output artifact path | `tools.toolkit.json` |

**Examples:**

```bash
# Compile from MCP config
swift run smallchat compile --source ~/.mcp.json

# Compile from manifest directory
swift run smallchat compile --source ./manifests/ -o my-tools.toolkit.json
```

---

### `serve`

Start an MCP-compatible HTTP server.

```bash
swift run smallchat serve --source <path> [options]
```

| Option | Description | Default |
|--------|-------------|---------|
| `--source`, `-s` | Path to manifests or compiled artifact | Required |
| `--port`, `-p` | Listen port | `3000` |
| `--host` | Bind address | `127.0.0.1` |
| `--db` | SQLite database path | `smallchat.db` |
| `--auth` | Enable OAuth 2.1 authentication | `false` |
| `--rate-limit` | Enable rate limiting | `false` |
| `--rpm` | Requests per minute limit | `600` |
| `--audit` | Enable audit logging | `false` |

**Examples:**

```bash
# Basic server
swift run smallchat serve --source ./manifests --port 3001

# Production server
swift run smallchat serve --source ./manifests \
  --port 8080 --host 0.0.0.0 \
  --auth --rate-limit --rpm 1000 --audit
```

---

### `channel`

Start the Claude Code channel server (stdio JSON-RPC).

```bash
swift run smallchat channel
```

This launches a stdio-based JSON-RPC server for bidirectional communication with Claude Code. It reads from stdin and writes to stdout.

---

### `resolve`

Test intent-to-tool resolution against a compiled artifact.

```bash
swift run smallchat resolve <artifact> <intent>
```

| Argument | Description |
|----------|-------------|
| `artifact` | Path to compiled `.toolkit.json` file |
| `intent` | Natural language intent string |

**Examples:**

```bash
swift run smallchat resolve tools.toolkit.json "search for code"
# Output:
#   Intent: "search for code"
#   Selector: search:for:code
#   Match: search_code (provider: github)
#   Confidence: 0.94
#   Resolution: cache miss → vector search → overload resolution

swift run smallchat resolve tools.toolkit.json "find recent documents"
```

---

### `inspect`

Examine a compiled artifact's contents.

```bash
swift run smallchat inspect <artifact>
```

Displays:
- Compilation metadata (version, timestamp)
- Provider summary
- Selector table with vectors
- Dispatch table mappings
- Overload groups

**Example:**

```bash
swift run smallchat inspect tools.toolkit.json
# Output:
#   Artifact: tools.toolkit.json
#   Version: 0.3.0
#   Compiled: 2025-01-15T10:30:00Z
#   Providers: 3
#   Selectors: 47
#   Dispatch entries: 52
#   Overload groups: 5
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
swift run smallchat docs <artifact>
```

Produces a Markdown file documenting:
- All registered tools with descriptions
- Input schemas and parameter types
- Provider groupings
- Selector mappings

---

### `repl`

Interactive shell for testing resolution and dispatch.

```bash
swift run smallchat repl <artifact>
```

The REPL provides:
- Type natural language intents and see resolution results
- View confidence scores and resolution paths
- Test dispatch with arguments
- Inspect the selector table and cache state

**Example session:**

```
smallchat> search for files
  → search_files (github) [confidence: 0.94, cache: miss]

smallchat> read the readme
  → read_file (filesystem) [confidence: 0.91, cache: miss]

smallchat> search for files
  → search_files (github) [confidence: 0.94, cache: hit]

smallchat> :cache
  Entries: 2 / 1024
  Hit rate: 33%

smallchat> :quit
```

REPL commands (prefixed with `:`):

| Command | Description |
|---------|-------------|
| `:cache` | Show cache statistics |
| `:selectors` | List all interned selectors |
| `:providers` | List registered providers |
| `:help` | Show available commands |
| `:quit` | Exit the REPL |

---

### `doctor`

Run diagnostics to verify your environment.

```bash
swift run smallchat doctor
```

Checks:
- Swift version compatibility
- Required dependencies
- Platform support
- Build configuration
