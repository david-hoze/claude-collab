# Multi-Agent Coordination

You are one of multiple Claude Code agents working in this repository.
A coordination tool `claude-collab` is available in your PATH.

## First thing — every session

Register yourself:

```
claude-collab init --name my-feature
```

The `--name` flag gives your agent a human-readable alias. Other agents (and you) can use it instead of the hash in all commands — `claude-collab files claim my-feature src/auth.ts` instead of `claude-collab files claim a3f8b201 src/auth.ts`.

The hash is printed in the JSON output. Save it: `HASH=<your-hash>`

You can also supply your own hash: `claude-collab init a3f8b201 --name my-feature`

## The two rules

1. **Claim before editing.** Run `claude-collab files claim $HASH <file>` before editing any file. NEVER use the Edit or Write tool on a file you haven't claimed. Not even "just a quick fix." Claim first, always.
2. **Commit through the tool.** Run `claude-collab commit $HASH -m "message"` instead of raw git. NEVER run `git add`, `git commit`, or `git checkout` directly.

## The workflow: claim → edit → commit

**This order is strict. Do not skip or reorder steps.**

```
claude-collab files claim $HASH <file>       # 1. Claim FIRST
# ... edit the file ...                       # 2. Edit ONLY AFTER claiming
claude-collab commit $HASH -m "message"       # 3. Commit (stages, commits, and unclaims)
```

**Common mistake:** editing a file first, then claiming it right before commit. This is wrong — another agent may have been editing the same file concurrently. The claim must happen BEFORE the first edit, not before the commit.

`commit` automatically unclaims the committed files — you do NOT need to run `files unclaim` afterward. Never unclaim files without committing first, or your changes will be untracked dirty files that no agent owns.

## When a claim is rejected

If `files claim` fails because another agent has the file:

1. Coordinate with the other agent (via Claude's agent teams messaging).
2. Once agreed, co-claim:
```
claude-collab files claim $HASH <file> --shared
```

## Committing shared files

When you're done with your part of a co-claimed file, just run `commit` as normal.

- If the other agent isn't done yet, your files will be **staged** (git add) and you're free to work on other things.
- You can keep claiming and committing new files even while waiting — only the already-staged files are held back.
- When the last agent runs `commit`, the actual git commit happens with everyone's changes included.

You don't need to wait. You don't need to coordinate the commit timing. Just `commit` when you're done and move on.

## Shared resources

Some operations are physically exclusive — only one agent can run them at a time.
Run `claude-collab reservations` to check what's available.

Before running tests, builds, or package installs:
```

claude-collab reserve $HASH test
npm test
claude-collab release $HASH test

```

If the resource is busy, the command waits until it's free. Always release when done.

If you need to release and immediately re-reserve (e.g., running tests again), use `--renew` to do it atomically:
```
claude-collab reserve $HASH test --renew
```
This avoids a race condition where another agent grabs the resource between your `release` and `reserve`.

## When you're done

```
claude-collab cleanup $HASH
```
