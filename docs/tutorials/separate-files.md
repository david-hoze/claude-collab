# Tutorial: Two Agents on Separate Files

The simplest multi-agent workflow — each agent edits different files and commits independently.

## Setup

You have a project with `claude-collab install` already run. Two Claude Code sessions are open.

## Scenario

Agent A works on `src/auth.ts`. Agent B works on `src/api.ts`. No overlap.

## Step by step

### 1. Agents register automatically

When each session starts, the `SessionStart` hook runs:

```
claude-collab init --name "agent-a3f8b201"
claude-collab init --name "agent-7c4e9d12"
```

Both agents appear in the registry:

```bash
claude-collab list
# Shows both agents with status "active" and no claimed files
```

### 2. Files are claimed automatically

When Agent A edits `src/auth.ts`, the `PreToolUse` hook fires:

```
claude-collab files claim agent-a3f8b201 src/auth.ts
# {"ok": true, "claimed": ["src/auth.ts"], "shared": [], "rejected": []}
```

When Agent B edits `src/api.ts`:

```
claude-collab files claim agent-7c4e9d12 src/api.ts
# {"ok": true, "claimed": ["src/api.ts"], "shared": [], "rejected": []}
```

No conflicts — different files.

### 3. Check status

At any point, either agent can see who owns what:

```bash
claude-collab files status
```

```json
{
  "ok": true,
  "files": [
    {"path": "src/auth.ts", "status": "M", "owner": "agent-a3f8b201"},
    {"path": "src/api.ts", "status": "M", "owner": "agent-7c4e9d12"}
  ]
}
```

### 4. Agent A commits

```bash
claude-collab commit agent-a3f8b201 -m "add token validation"
```

The tool:
1. Finds `src/auth.ts` is dirty and claimed by Agent A
2. Runs `git add src/auth.ts`
3. Runs `git commit -m "add token validation"`
4. Unclaims `src/auth.ts` for Agent A

```json
{"ok": true, "commit": "3f2a1b", "committed": ["src/auth.ts"]}
```

### 5. Agent B commits

```bash
claude-collab commit agent-7c4e9d12 -m "add rate limiting endpoint"
```

Same process, independent of Agent A's commit. Both commits land cleanly.

## Key points

- No coordination needed when files don't overlap
- Claims are automatic via the `PreToolUse` hook
- Each agent commits only its own files — no risk of committing another agent's work
- Commits are serialized by an internal git lock, so even simultaneous `commit` calls are safe
