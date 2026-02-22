# Multi-Agent Coordination

You are one of multiple Claude Code agents working in this repository.
A coordination tool `claude-collab` is available in your PATH.

## First thing — every session

Run `init` to register yourself. Your Claude Code session ID is used as the agent hash automatically:

```
claude-collab init
```

The hash (first 8 characters of your session UUID) is printed in the JSON output. Save it in a variable: `HASH=<your-hash>`

If not running inside Claude Code, a random hash is generated instead. You can also supply your own hash: `claude-collab init <your-hash>`

## The two rules

1. **Claim before editing.** Run `claude-collab files claim $HASH <file>` before editing any file.
2. **Commit through the tool.** Run `claude-collab commit $HASH -m "message"` instead of raw git. NEVER run `git add`, `git commit`, or `git checkout` directly.

## The workflow: claim → edit → commit

Always follow this order:

```
claude-collab files claim $HASH <file>       # 1. Claim
# ... edit the file ...                       # 2. Edit
claude-collab commit $HASH -m "message"       # 3. Commit (stages, commits, and unclaims)
```

`commit` automatically unclaims the committed files — you do NOT need to run `files unclaim` afterward. Never unclaim files without committing first, or your changes will be untracked dirty files that no agent owns.

## Replaying missed messages

If you suspect you missed messages (cursor advanced past them), replay from a specific point:

```
claude-collab read $HASH --from 0    # replay everything
claude-collab read $HASH --from 7    # replay from seq 7
```

## When a claim is rejected

If `files claim` fails because another agent has the file:

1. Send a message:
```
claude-collab send $HASH "I need to edit <file> — what parts are you changing?"
```
2. Wait for a response:
```

claude-collab read $HASH --wait

```
3. Negotiate: agree on who edits what, or whether to co-claim.
4. Once agreed, co-claim:
```
claude-collab files claim $HASH <file> --shared
```

## Committing shared files

When you're done with your part of a co-claimed file, just run `commit` as normal.

- If the other agent isn't done yet, your files will be **staged** (git add) and you're free to work on other things.
- When the last agent runs `commit`, the actual git commit happens with everyone's changes included.
- You'll see a channel message when the commit goes through.

You don't need to wait. You don't need to coordinate the commit timing. Just `commit` when you're done and move on.

## Shared resources

Some operations are physically exclusive — only one agent can run them at a time.
Run `claude-collab reservations` to check what's available.

Before running tests, builds, or package installs:
```

claude-collab reserve $HASH test npm test claude-collab release $HASH test

```

If the resource is busy, the command waits until it's free. Always release when done.

## Sharing test and build results

After running tests or a build, broadcast the result so other agents can skip redundant work:

```
claude-collab send $HASH "test-result: PASS (all 47 specs)" --type status claude-collab send $HASH "build-result: OK (binary at dist/claude-collab)" --type status
```

Before reserving `test` or `build` yourself, read the channel:

```
claude-collab read $HASH
```

If another agent posted a recent `test-result` or `build-result` **and** you haven't changed any files that would affect the outcome since that message, skip the run. Use the existing result. Don't waste time re-running a test suite that already passed against the current state of the code.

If you *have* changed relevant files since the last posted result, run it yourself and post the new result.

## Helping each other

The channel isn't just for conflict resolution — it's how agents delegate work and make use of each other's time. There are two situations where this matters:

### Delegating responsibility

If you discover a problem that belongs to another agent — a test broke because of their changes, a type error in a file they own, a regression in their feature — tell them directly:

```
claude-collab send $HASH "[needs-fix] @<other-hash> Tests in auth.spec.ts are failing — looks like the session refactor broke the token validation path. This is in your claimed files." --type chat
```

Don't fix other agents' bugs silently. The agent who owns the code has the context to fix it properly. If you spot the issue, describe it clearly — what's failing, why you think it's related to their work, and which files are involved. Then move on with your own task.

If you receive a `[needs-fix]` message about your own changes, prioritize it. You broke it, you fix it.

### Requesting help from idle agents

If you're stuck on something outside your feature scope — a flaky test you didn't cause, a build configuration issue, a global refactor that blocks your progress — ask for help:

```
claude-collab send $HASH "[help-wanted] The lint config is rejecting my new files because of a missing rule. Can someone update .eslintrc? I don't want to claim it mid-feature." --type chat
```

This is most useful when another agent is idle or between tasks. Don't expect an immediate response from an agent that's mid-task.

### Picking up work

When you finish your assigned task, don't immediately clean up. Check the channel:

```
claude-collab read $HASH
```

Look for `[help-wanted]` messages or `[needs-fix]` messages directed at agents that have already cleaned up. If you see something you can handle:

```
claude-collab send $HASH "I'm done with my task — picking up the eslint fix." --type chat
```

Then claim the relevant files through the normal flow.

**When to pick up extra work:**
- You are idle or done with your assigned task.
- The request is well-scoped — you can understand what needs doing from the message alone.
- You haven't received user input in the last 10 minutes (helping won't disrupt a conversation).

**When not to:**
- You're mid-task and context-switching would be costly.
- The request is vague or open-ended.
- The user is actively giving you instructions.

If you can't help, say so briefly — "can't right now, mid-task" is better than silence.

## Status heartbeats

Every few minutes of active work, post a brief status so other agents know what you're doing:

```
claude-collab send $HASH "Working on auth middleware, editing src/auth.ts and src/session.ts" --type status
```

This helps other agents make informed decisions: whether to send you a `[needs-fix]`, whether your test results are still relevant, and whether a file you haven't claimed yet is about to be touched.

## Periodic check-in

Every few actions, run `claude-collab read $HASH` to check for messages. Don't go silent for too long. If another agent is talking to you, respond promptly — especially `[needs-fix]` messages about your own changes.

## When you're done

Don't clean up immediately if other agents are still working — check the channel first and see if there are any `[help-wanted]` requests you can handle. Once everything is settled:
