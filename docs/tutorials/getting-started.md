# Getting Started with claude-collab

This guide walks you through installing `claude-collab`, setting up a project, and launching two Claude Code agents that coordinate automatically.

## Prerequisites

- **GHC 9.6+** and **Cabal 3.0+** — install via [GHCup](https://www.haskell.org/ghcup/)
- **Claude Code CLI** — install via `npm install -g @anthropic-ai/claude-code`
- A git repository to work in

## 1. Install claude-collab

Clone and build:

```bash
git clone <repo-url> claude-collab
cd claude-collab
cabal build && cabal install
```

Verify it's on your PATH:

```bash
claude-collab --help
```

## 2. Set up your project

Navigate to any git repository and run:

```bash
cd my-project
claude-collab install
```

This creates:

| File | Purpose |
|------|---------|
| `CLAUDE_COLLAB.md` | Agent-facing instructions (how agents should behave) |
| `.claude/hooks/session-start-init.sh` | Auto-registers each agent on session start |
| `.claude/hooks/pre-edit-claim.sh` | Auto-claims files before any Edit/Write |
| `.claude/hooks/session-end-cleanup.sh` | Auto-cleans up when a session ends |
| `.claude/settings.json` | Hooks configuration for Claude Code |
| `.claude/agents/resources.json` | Default shared resources (build, test) |
| `CLAUDE.md` | Updated with a collaboration section (created if missing) |

## 3. Launch two agents

Open two terminal windows in the same project directory. In each one, start a Claude Code session:

```bash
# Terminal 1
claude

# Terminal 2
claude
```

Each session automatically registers via the `session-start-init.sh` hook. You can verify with:

```bash
claude-collab list
```

This shows both agents with their auto-generated names (e.g., `agent-a3f8b201`, `agent-7c4e9d12`).

## 4. See it in action

Give each agent a task that touches different files. For example:

- **Agent 1:** "Add input validation to `src/auth.ts`"
- **Agent 2:** "Write tests in `test/auth.test.ts`"

As each agent works, the `pre-edit-claim.sh` hook automatically runs `claude-collab files claim` before any file edit. You can see the claims:

```bash
claude-collab files status
```

When an agent finishes, it commits through the tool:

```bash
claude-collab commit agent-a3f8b201 -m "add input validation"
```

The tool stages only that agent's claimed files, commits them, and unclaims the files.

## 5. What just happened

Here's what the hooks did behind the scenes:

1. **Session start** — the `SessionStart` hook ran `claude-collab init --name "agent-<id>"`, registering the agent in `.claude/agents/registry.json`

2. **Before each edit** — the `PreToolUse` hook (matching `Edit|Write`) ran `claude-collab files claim <agent> <file>`, recording the claim in the registry. If another agent already claimed the file, the hook rejects the edit and the agent must negotiate.

3. **On commit** — the agent ran `claude-collab commit` manually. The tool checked which files the agent had claimed, staged only those, and committed.

4. **Session end** — the `SessionEnd` hook ran `claude-collab cleanup`, removing the agent's claims, releasing any resource reservations, and deregistering from the registry.

## Next steps

- [Two agents on separate files](separate-files.md) — the simplest workflow
- [Co-claiming a shared file](shared-files.md) — negotiating shared edits and two-phase commits
- [Resource reservations](resource-reservations.md) — exclusive access to the test suite or build
