# claude-collab

A cross-platform CLI tool that enables multiple [Claude Code](https://claude.com/claude-code) instances to coordinate while working in the same repository.

## What it does

When multiple Claude Code agents work on the same codebase simultaneously, they need to know who's editing what and avoid stepping on each other's changes. `claude-collab` provides:

- **File claims** — agents declare which files they're editing, with conflict detection
- **Resource reservations** — exclusive access to shared resources like the test suite or build
- **Safe git commits** — only commits an agent's own claimed files, with two-phase commit for shared files
- **Automatic hooks** — agents register, claim files, and clean up automatically via Claude Code hooks

## Quick start

Build and install:

```bash
cabal build && cabal install
```

Set up a project:

```bash
cd my-project
claude-collab install
```

This installs Claude Code hooks and configuration into your repo. From here, open two Claude Code sessions in the same project — the hooks handle everything automatically:

1. Each agent registers on session start
2. Files are auto-claimed before edits
3. Agents commit through the tool: `claude-collab commit <agent> -m "message"`
4. Agents clean up on session end

## How it works

**Two primitives — claim and commit.**

**Claim** is the entry gate: it declares intent to edit a file and forces a pause on conflicts. If two agents want the same file, the second claim is rejected — agents must negotiate and co-claim with `--shared`.

**Commit** is the exit gate: it stages and commits only the agent's own claimed files. For co-claimed files, it's a two-phase operation — the first agent to commit *stages* their changes, and the last agent triggers the actual `git commit` with everyone's changes and a combined message.

**Resource reservations** provide exclusive access to shared resources (test suite, build system). An agent reserves a resource, does its work, and releases it. If busy, the tool polls until the resource is free or times out.

**Hooks** automate the workflow. The `install` command sets up three Claude Code hooks:
- **SessionStart** — auto-registers the agent
- **PreToolUse** (Edit/Write) — auto-claims files before editing
- **SessionEnd** — auto-cleanup

## Commands

| Command | Description |
|---------|-------------|
| `init [HASH] [--name NAME]` | Register as an agent |
| `install` | Install hooks and config into current repo |
| `files claim <HASH\|NAME> <paths...> [--shared]` | Claim files for editing |
| `files unclaim <HASH\|NAME> <paths...>` | Release file claims |
| `files status` | Show all dirty files and their owners |
| `commit <HASH\|NAME> -m <msg>` | Commit claimed files |
| `reserve <HASH\|NAME> <resource> [--ttl N] [--timeout N] [--renew]` | Reserve a shared resource |
| `release <HASH\|NAME> <resource>` | Release a reserved resource |
| `reservations` | Show resource status |
| `list` | List all agents |
| `cleanup <HASH\|NAME>` | Unregister and clean up |
| `tee <HASH\|NAME>` | Pipe stdin to stdout + log file |

All commands that take `HASH|NAME` accept either the agent hash or the human-readable name registered with `--name`.

See [docs/spec.md](docs/spec.md) for the full command reference.

## Building from source

Requires GHC 9.6+ and Cabal 3.0+.

```bash
cabal build
```

The output binary is `claude-collab` (or `claude-collab.exe` on Windows).

To install to your PATH:

```bash
cabal install
```

To run tests:

```bash
cabal test
```

## Documentation

- [Getting started](docs/tutorials/getting-started.md) — step-by-step setup and first run
- [Tutorial: Separate files](docs/tutorials/separate-files.md) — two agents editing different files
- [Tutorial: Shared files](docs/tutorials/shared-files.md) — co-claiming and two-phase commits
- [Tutorial: Resource reservations](docs/tutorials/resource-reservations.md) — exclusive access to test/build
- [CLAUDE_COLLAB.md](docs/CLAUDE_COLLAB.md) — agent-facing instructions (copied into your project by `install`)
- [Specification](docs/spec.md) — full command reference and JSON schemas
- [Implementation status](docs/implementation-status.md) — architecture, internals, known limitations
