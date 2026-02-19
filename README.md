# claude-collab

A cross-platform CLI tool that enables multiple [Claude Code](https://claude.com/claude-code) instances to coordinate while working in the same repository.

## What it does

When multiple Claude Code agents work on the same codebase simultaneously, they need to know who's editing what and avoid stepping on each other's changes. `claude-collab` provides:

- **Message channel** — agents can chat with each other to negotiate who does what
- **File claims** — agents declare which files they're editing, with conflict detection
- **Resource reservations** — exclusive access to shared resources like the test suite or build
- **Safe git commits** — only commits an agent's own claimed files, with two-phase commit for shared files

## Building

Requires GHC 9.6+ and Cabal 3.0+.

```
cabal build
```

The output binary is `claude-collab` (or `claude-collab.exe` on Windows).

To install it to your PATH:

```
cabal install
```

## Quick start

```bash
# Agent 1 initializes
claude-collab init abc12345

# Claim a file before editing
claude-collab files claim abc12345 src/auth.ts

# Check for messages from other agents
claude-collab read abc12345

# Send a message
claude-collab send abc12345 "Working on the auth refactor"

# Commit when done
claude-collab commit abc12345 -m "refactor auth validation"

# Clean up when leaving
claude-collab cleanup abc12345
```

## Commands

| Command | Description |
|---------|-------------|
| `init <hash>` | Register as an agent |
| `send <hash> <msg>` | Send a channel message |
| `read <hash>` | Read new messages |
| `watch <hash>` | Stream messages continuously |
| `files claim <hash> <paths...>` | Claim files for editing |
| `files unclaim <hash> <paths...>` | Release file claims |
| `files status` | Show all dirty files and their owners |
| `commit <hash> -m <msg>` | Commit claimed files |
| `reserve <hash> <resource>` | Reserve a shared resource |
| `release <hash> <resource>` | Release a reserved resource |
| `reservations` | Show resource status |
| `list` | List all agents |
| `cleanup <hash>` | Unregister and clean up |
| `tee <hash>` | Pipe stdin to stdout + log file |

See [docs/spec.md](docs/spec.md) for full command reference.

## How co-claimed commits work

When two agents need to edit the same file, they co-claim it with `--shared`. When the first agent commits, their changes are staged (`git add`) but not committed. When the last agent commits, the actual `git commit` fires with everyone's changes and a combined message. Agents don't need to coordinate timing — just `commit` when done and move on.

## Setting up your project

Once `claude-collab` is in your PATH, add this to your project's `CLAUDE.md`:

```markdown
Read and follow the instructions in CLAUDE_COLLAB.md.
```

Then copy [`docs/CLAUDE_COLLAB.md`](docs/CLAUDE_COLLAB.md) into your project root. This file contains the agent-facing instructions that teach Claude Code how to use the tool.

## Running tests

```
cabal test
```

## Documentation

- [CLAUDE_COLLAB.md](docs/CLAUDE_COLLAB.md) — agent-facing instructions (copy into your project)
- [Specification](docs/spec.md) — full command reference and JSON schemas
- [Implementation status](docs/implementation-status.md) — architecture, internals, known limitations
