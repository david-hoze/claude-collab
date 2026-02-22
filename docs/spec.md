# `claude-collab` — Specification

## Overview

`claude-collab` is a cross-platform CLI tool that enables multiple Claude Code instances to coordinate while working in the same repository. It provides:

- A **file claim registry** so agents can see who's working on what
- A **resource reservation system** for exclusive operations (tests, builds, installs)
- A safe **git commit wrapper** that only commits an agent's own files

### Design philosophy

**Two primitives — claim and commit.**

Claim is the entry gate: it declares intent to edit a file and forces a pause on conflicts. Commit is the exit gate: for co-claimed files, it's a two-phase operation where the first agent to commit *stages* and the last agent triggers the actual `git commit` with everyone's changes.

No rigid locks on files, no mutexes — the only hard serialization is the physical `git commit` invocation (because git itself can't handle two simultaneous commits).

## File structure

```
.claude/agents/
├── registry.json            # Agent registry with file claims
├── resources.json           # Defined resources (test, build, install, ...)
├── reservations.json        # Active resource reservations
├── <agent-hash>/
│   └── output.log           # Optional tee'd output
└── ...
```

## CLI commands

```
claude-collab init <hash>
claude-collab files claim <hash> <path> [<path>...] [--shared]
claude-collab files unclaim <hash> <path> [<path>...]
claude-collab files status
claude-collab commit <hash> -m <message>
claude-collab reserve <hash> <resource> [--ttl SECONDS] [--timeout SECONDS] [--renew]
claude-collab release <hash> <resource>
claude-collab reservations
claude-collab list
claude-collab cleanup <hash>
claude-collab tee <hash>
```

All commands print JSON to stdout and diagnostics/warnings to stderr.

---

## Command reference

### `init <hash>`

Registers a new agent and sets up the working environment.

1. Creates `.claude/agents/<hash>/` directory.
2. Creates `resources.json` with defaults if it doesn't exist:
   ```json
   {
     "test": { "default_ttl": 1800, "description": "Test suite" },
     "build": { "default_ttl": 1800, "description": "Build / compile" },
     "install": { "default_ttl": 1800, "description": "Package installation (npm, pip, etc.)" }
   }
   ```
3. Creates `reservations.json` as `{}` if it doesn't exist.
4. Adds an entry to `registry.json` with `started` timestamp, empty `claimed` map, and `status: "active"`.

**Output:** `{"ok": true, "hash": "<hash>", "agent_dir": ".claude/agents/<hash>"}`

### `files claim <hash> <path> [<path>...] [--shared]`

Declares intent to edit one or more files. This is one of the two core primitives.

For each path:
- **Unclaimed:** added to this agent's claims. Success.
- **Already claimed by this agent:** no-op. Success.
- **Claimed by another agent, `--shared` NOT set:** prints a warning to stderr and rejects the claim. **Exit code 1.** The agent is expected to negotiate and retry with `--shared`.
- **Claimed by another agent, `--shared` IS set:** adds a co-claim. Both agents now share the file.

The `--shared` flag is an intentional friction point. Without it, a conflicting claim fails, forcing the agent to pause and negotiate before proceeding.

**Output:**
```json
{
  "ok": true,
  "claimed": ["src/auth.ts"],
  "shared": ["src/routes.ts"],
  "rejected": []
}
```

`ok` is `false` and exit code is 1 if any files were rejected.

### `files unclaim <hash> <path> [<path>...]`

Removes file claims.

**Output:** `{"ok": true, "unclaimed": ["src/auth.ts"]}`

### `files status`

Cross-references `git status --porcelain` with the claim registry.

**Output:**
```json
{
  "ok": true,
  "files": [
    {"path": "src/auth.ts", "status": "M", "owner": "abc1"},
    {"path": "src/new.ts", "status": "??", "owner": "unclaimed"}
  ]
}
```

Exit code 3 if git fails.

### `commit <hash> -m <message>`

Commits this agent's claimed dirty files. This is the second core primitive.

**Rules:**
- **All-or-nothing per commit.** All of an agent's *unstaged* claimed dirty files are part of one commit. If any co-claimed file is waiting on another agent, those files are staged and wait.
- **Additional staging allowed.** An agent with pending staged files can stage *new* unstaged claims. Already-staged files (and their commit messages) are preserved untouched. Only if the agent has no new unstaged claims does the command error with exit code 1.
- Unclaimed dirty files are warned about but not staged.

**Behavior:**

1. If all of the agent's claimed files are already staged (no new work): error, exit code 1.
2. Collect the agent's claimed files that are dirty per `git status`.
3. Warn about any unclaimed dirty files (stderr only, not staged).
4. Check if any dirty claimed file is co-claimed where co-claimers haven't staged yet.
5. **If waiting is needed:** run `git add` for all dirty claimed files, mark them as staged in the registry with the commit message, and exit.
   ```json
   {"ok": true, "staged": ["src/auth.ts", "src/config.ts"], "waiting_on": {"src/auth.ts": ["d4e5"]}}
   ```
6. **If no waiting needed:** run `git add`, build the commit message, run `git commit`, clean up registry.
   ```json
   {"ok": true, "commit": "3f2a1b", "committed": ["src/auth.ts", "src/config.ts"]}
   ```

For co-claimed commits, messages from all co-claimers are concatenated:
```
[abc1] refactor validateToken + update config
[d4e5] add rate limiting
```

Solo commits use the plain message without the agent prefix.

After a successful commit: solo-claimed files are unclaimed for this agent; co-claimed files are unclaimed for *all* co-claimers.

If git commit fails: nothing is cleaned up. Files remain staged in the registry.

**Example scenario:**

```
Agent abc1 claims src/auth.ts (shared with d4e5) and src/config.ts (solo).

abc1 finishes:
  $ claude-collab commit abc1 -m "refactor validateToken + update config"
  -> src/auth.ts co-claimed, d4e5 not staged -> WAITING
  -> stages ALL files (including solo src/config.ts)
  -> "Staged 2 files. Waiting on d4e5 for src/auth.ts."
  -> abc1 is free to keep working on new files.

abc1 claims and edits src/utils.ts while waiting:
  $ claude-collab files claim abc1 src/utils.ts
  $ claude-collab commit abc1 -m "add helper functions"
  -> src/utils.ts is a new unstaged claim -> stages it normally
  -> Already-staged files (src/auth.ts, src/config.ts) are untouched.

d4e5 finishes:
  $ claude-collab commit d4e5 -m "add rate limiting"
  -> src/auth.ts co-claimed, abc1 IS staged -> no waiting needed
  -> re-stages with latest versions on disk
  -> git commit with combined message
  -> unclaims for BOTH agents

abc1 sees the commit message. The previously-staged files are resolved.
```

### `reserve <hash> <resource> [--ttl SECONDS] [--timeout SECONDS] [--renew]`

Reserves a shared resource for exclusive use. Unlike file claims, resources are physically exclusive — two agents cannot run the test suite simultaneously.

Resources must be defined in `resources.json`. Attempting to reserve an undefined resource prints the available resources and exits with code 1.

- `--ttl`: Override the resource's default TTL (in seconds).
- `--timeout`: How long to wait if the resource is busy (default 30 seconds, polls every 500ms).
- `--renew`: Atomically release the resource before re-reserving. Use this instead of `release` + `reserve` to avoid a race condition where another agent grabs the resource between the two calls.

**Behavior:**

- **Unreserved:** reserves it immediately.
- **Already held by this agent:** refreshes the TTL.
- **Already held by this agent, `--renew` set:** atomically releases then re-reserves within a single lock acquisition. This avoids the race condition where another agent grabs the resource between a separate `release` and `reserve`.
- **Held by another agent, TTL expired:** takes it over with a warning to stderr.
- **Held by another agent, TTL valid:** waits (polling), retrying until freed or timeout.
- **Timeout reached:** exit code 2.

**Output:** `{"ok": true, "resource": "test", "ttl": 300}`

With TTL refresh: `{"ok": true, "resource": "test", "ttl": 300, "refreshed": true}`

### `release <hash> <resource>`

Releases a resource held by this agent.

- If held by another agent: error with exit code 1.
- If not reserved: no-op, success.

**Output:** `{"ok": true, "resource": "test"}`

### `reservations`

Lists all defined resources and their reservation status. Expired reservations are cleaned up and shown as available.

**Output:**
```json
{
  "ok": true,
  "resources": [
    {"name": "test", "description": "Test suite", "status": "available"},
    {"name": "build", "description": "Build / compile", "status": "reserved", "holder": "abc1", "remaining": 245}
  ]
}
```

### `list`

Lists all registered agents with their full info (start time, status, claimed files).

**Output:** `{"ok": true, "agents": { ... }}`

### `cleanup <hash>`

Removes an agent completely:
1. Unclaims all files.
2. Releases all reservations held by this agent.
3. Removes from `registry.json`.
4. Removes the agent's directory.

**Output:** `{"ok": true, "hash": "<hash>"}`

### `tee <hash>`

Reads stdin line-by-line, writes to both stdout and `.claude/agents/<hash>/output.log`. For use as: `claude 2>&1 | claude-collab tee abc1`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (missing agent, claim conflict, pending commit, unknown resource, wrong holder) |
| 2 | Lock/reservation timeout |
| 3 | Git command failed |

Uncaught exceptions print `{"ok": false, "error": "..."}` and exit with code 1.

## JSON schemas

### Registry (`registry.json`)
```json
{
  "abc12345": {
    "started": "2025-01-15T10:00:00Z",
    "status": "active",
    "claimed": {
      "src/auth.ts": { "staged": false, "commit_msg": null },
      "src/utils.ts": { "staged": true, "commit_msg": "refactor auth" }
    }
  }
}
```

### Resources (`resources.json`)
```json
{
  "test": { "default_ttl": 1800, "description": "Test suite" },
  "build": { "default_ttl": 1800, "description": "Build / compile" }
}
```

### Reservations (`reservations.json`)
```json
{
  "test": {
    "holder": "abc12345",
    "acquired": "2025-01-15T10:00:00Z",
    "ttl": 300,
    "purpose": null
  }
}
```
