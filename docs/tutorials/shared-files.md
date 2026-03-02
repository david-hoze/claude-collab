# Tutorial: Co-Claiming a Shared File

When two agents need to edit the same file, they use co-claims and the two-phase commit.

## Setup

Two agents are registered. Both need to edit `src/config.ts`.

## Step by step

### 1. First agent claims the file

Agent A edits `src/config.ts`. The hook auto-claims it:

```
claude-collab files claim agent-a3f8 src/config.ts
# {"ok": true, "claimed": ["src/config.ts"], "shared": [], "rejected": []}
```

### 2. Second agent's claim is rejected

Agent B tries to edit the same file. The hook runs:

```
claude-collab files claim agent-7c4e src/config.ts
# {"ok": false, "claimed": [], "shared": [], "rejected": ["src/config.ts"]}
# stderr: src/config.ts is claimed by agent-a3f8
```

The edit is blocked. Agent B must negotiate.

### 3. Negotiate and co-claim

Agent B messages Agent A using Claude Code's native messaging to ask about sharing the file. Once they agree, Agent B re-claims with `--shared`:

```bash
claude-collab files claim agent-7c4e src/config.ts --shared
```

```json
{"ok": true, "claimed": [], "shared": ["src/config.ts"], "rejected": []}
```

Both agents now co-claim `src/config.ts`.

### 4. First agent commits (stages and waits)

Agent A finishes and commits:

```bash
claude-collab commit agent-a3f8 -m "update database connection config"
```

Agent B hasn't staged yet, so the tool **stages** Agent A's changes but does not run `git commit`:

```json
{
  "ok": true,
  "staged": ["src/config.ts"],
  "waiting_on": {"src/config.ts": ["agent-7c4e"]}
}
```

Agent A is free to move on to other work — claim new files, make edits, even run another commit for different files.

### 5. Second agent commits (triggers the real commit)

Agent B finishes and commits:

```bash
claude-collab commit agent-7c4e -m "add cache TTL settings"
```

Agent A has already staged, so no more waiting. The tool:

1. Re-stages all co-claimed files (picks up latest versions on disk)
2. Builds a combined commit message
3. Runs `git commit`
4. Unclaims the file for **both** agents

```json
{"ok": true, "commit": "a1b2c3", "committed": ["src/config.ts"]}
```

### 6. The combined commit message

The commit message combines both agents' messages with a `|` separator and agent prefixes:

```
[agent-a3f8] update database connection config | [agent-7c4e] add cache TTL settings
```

Solo commits (files claimed by only one agent) use the plain message without prefixes.

## Working on other files while waiting

After Agent A stages and is "waiting on" Agent B, Agent A can keep working:

```bash
# Agent A claims and edits a new file
claude-collab files claim agent-a3f8 src/utils.ts
# ... edits src/utils.ts ...
claude-collab commit agent-a3f8 -m "add helper functions"
```

This new commit only affects `src/utils.ts`. The previously staged `src/config.ts` is untouched — it stays staged until Agent B triggers the combined commit.

## Key points

- Claims without `--shared` are rejected when another agent holds the file — this forces negotiation
- The first agent to commit stages changes and moves on
- The last agent to commit triggers the actual `git commit` with combined messages
- Agents don't need to coordinate timing — just commit when done
- Previously staged files are preserved when committing new work
