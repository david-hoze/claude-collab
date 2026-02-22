# Messaging Implementation

## Overview

claude-collab uses a file-based message channel. Messages are JSON files in `.claude/agents/channel/`, numbered sequentially. Each agent tracks its read position with a cursor file.

## Data Flow

```
Agent A sends              Agent B reads
    |                          |
    v                          v
acquire channel lock       read own cursor (e.g. 5)
read .seq (e.g. 7)         read .seq (e.g. 9)
write .seq = 8             read files 000006.json .. 000009.json
release lock               filter out own messages
write 000008.json          write cursor = 9
                           return other agents' messages
```

## Channel Directory Layout

```
.claude/agents/
  channel/
    .seq              # Global sequence counter (plain integer)
    .lock/            # mkdir-based lock directory
    000001.json       # Message at seq 1
    000002.json       # Message at seq 2
    ...
  <hash>/
    cursor            # This agent's read position (plain integer)
  registry.json       # All agents: hash, name, status, claimed files
```

## Sending a Message

`sendMessage` in `Channel.hs`:

1. Acquire the channel lock (mkdir-based, stale after 5s)
2. Read `.seq`, increment to `next`, write `.seq`
3. Release the lock
4. Build a `Message` record with seq, timestamp, sender hash, type, body, optional target
5. Write to `000042.json.tmp`, then `rename` to `000042.json` (atomic on most filesystems)
6. Return the seq number

The lock only protects the seq increment. The message file write happens after the lock is released — this is safe because no other agent will read a seq number until the file exists, and `readRange` silently skips missing files.

## Reading Messages

`readMessages` in `Channel.hs`:

1. Read the agent's cursor (e.g. 5)
2. Read the global `.seq` (e.g. 9)
3. If cursor >= seq, return empty
4. Read message files from cursor+1 to seq
5. **Filter out messages where `msgFrom == hash`** — agents only see other agents' messages
6. Advance cursor to seq
7. Return the filtered messages

The self-filtering is critical: without it, an agent's own sends (claims, commits, status messages) would be returned as "new messages", obscuring actual messages from other agents. The cursor still advances past own messages so they aren't re-read.

## Message Format

```json
{
  "seq": 42,
  "ts": "2026-02-22T03:51:37.546Z",
  "from": "f390e203",
  "type": "chat",
  "msg": "Hello from f390e203",
  "target": null
}
```

Types: `chat`, `status`, `claim`, `unclaim`, `staged`, `commit`, `reserve`, `release`.

The `target` field is optional — used by claim/unclaim/reserve/release to indicate which file or resource the message is about.

## Cursor Management

Each agent has a cursor file at `.claude/agents/<hash>/cursor` containing a plain integer. It represents the last seq number consumed by this agent.

- **On init**: cursor is set to current `.seq`. The agent starts seeing messages sent after it joined.
- **On read**: cursor advances to the latest `.seq`, regardless of whether messages were returned (own messages are filtered but still advance the cursor).
- **On `--from N`**: cursor is NOT touched. This is a replay/debug feature that reads from a specific seq without side effects.

## Agent Name Resolution

Agents can register with a human-readable name via `claude-collab init --name <name>`. Names are stored in `registry.json` in the `agentName` field.

Every command that takes a `HASH|NAME` argument runs through `resolveAgent` in `Registry.hs`:

1. If the input matches a registered hash directly, use it
2. Otherwise, search all agents' `agentName` fields for a match
3. If no match, pass through unchanged (the command will fail naturally with "agent not found")

This means `claude-collab read git-tests` and `claude-collab read a3145e62` are equivalent if `a3145e62` registered with `--name git-tests`.

## Locking

The channel uses a mkdir-based lock (`channelDir/.lock/`). `mkdir` is atomic on both Windows and POSIX — only one process can create the directory. The lock auto-breaks after 5 seconds (stale detection via directory mtime).

The lock only protects the seq increment. It is NOT held during message file writes or reads. This keeps contention low — the critical section is just: read int, write int+1.

## Known Limitations

- **Init cursor**: a message sent just before an agent inits is invisible to that agent via normal `read`, because init sets cursor to current seq. Use `--from 0` to recover missed messages.
- **No garbage collection**: message files accumulate forever. A future `prune` command could delete messages older than N or below all agents' cursors.
- **No message delivery guarantee**: if an agent never reads, messages pile up. There's no backpressure or notification mechanism beyond polling.
- **Single-directory scope**: the channel lives in `.claude/agents/` relative to CWD. Agents must run from the same directory to share a channel.
