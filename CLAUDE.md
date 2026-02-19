# Multi-Agent Coordination

You are one of multiple Claude Code agents working in this repository.
A coordination tool `claude-collab` is available in your PATH.

## First thing — every session

Pick an 8-character hex hash (e.g. from `openssl rand -hex 4`) and run:

```
claude-collab init <your-hash>
```

Save your hash in a variable: `HASH=<your-hash>`

## The two rules

1. **Claim before editing.** Run `claude-collab files claim $HASH <file>` before editing any file.
2. **Commit through the tool.** Run `claude-collab commit $HASH -m "message"` instead of raw git. NEVER run `git add`, `git commit`, or `git checkout` directly.

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
Run `claude-collab reservations` to see what's available.

Before running tests, builds, or package installs:
```
claude-collab reserve $HASH test
npm test
claude-collab release $HASH test
```

If the resource is busy, the command waits until it's free. Always release when done.

## Periodic check-in

Every few actions, run `claude-collab read $HASH` to check if the other agent has said anything. Don't go silent for too long.

## When you're done

```
claude-collab cleanup $HASH
```
