# Implementation Status

## Architecture

Written in Haskell (GHC 9.6), built with Cabal. Single binary: `claude-collab` / `claude-collab.exe`.

### Module layout

```
app/
├── Main.hs                    # CLI parser (optparse-applicative)
├── ClaudeCollab/
│   ├── Types.hs               # Data types, JSON instances, path constants
│   ├── Lock.hs                # mkdir-based locking
│   ├── Registry.hs            # registry.json read/write
│   ├── Channel.hs             # Message send/read/watch, cursor management
│   ├── Git.hs                 # git status/add/commit wrappers
│   └── Commands.hs            # All command implementations
test/
└── Spec.hs                    # Test suite (19 tests)
```

### Dependencies

- `optparse-applicative` — CLI parsing
- `aeson` / `aeson-pretty` — JSON
- `fsnotify` — declared but not currently used (polling used instead)
- `directory` — file/directory operations
- `process` — git subprocess execution
- `time` — timestamps
- `filepath` — path manipulation
- `bytestring` / `text` — string handling
- `containers` — Map

## Concurrency & atomicity

### mkdir locks

The only locking mechanism. `mkdir` is atomic on NTFS, ext4, APFS, and HFS+. Three lock directories:

| Lock | Path | Stale timeout | Used by |
|------|------|---------------|---------|
| Channel | `.claude/agents/channel/.lock/` | 5s | `send` (sequence increment) |
| Git | `.claude/agents/.git-lock/` | 30s | `commit` (git commit serialization) |
| Reserve | `.claude/agents/.reserve-lock/` | 5s | `reserve`, `release`, `cleanup` |

Behavior: spin-retry every 20ms. If the lock directory is older than the stale timeout, force-break it (rmdir + retry).

### Atomic file writes

All JSON file writes use write-to-temp-then-rename. On Windows, the destination is removed before renaming (Windows `rename` fails if target exists).

### Registry writes

`registry.json` uses read-modify-write without a lock. There's a small race window between read and rename, but agents operate at human speed, so collisions are unlikely.

## File watching

`read --wait` and `watch` use **polling** (500ms interval), not `fsnotify`. This is simpler and more reliable cross-platform. The `fsnotify` dependency is declared but unused.

## Path handling

All file paths are normalized: backslashes are converted to forward slashes before comparison or storage. This allows Windows and Unix path styles to coexist in the registry.

## Git integration

Uses `readProcessWithExitCode` to run:
- `git status --porcelain` — parsed into (status, path) pairs
- `git add <files>` — stages specific files
- `git commit -m <message>` — commit hash extracted from output

The commit hash extraction parses the `[branch hash]` pattern from git's output. Falls back to the first 40 characters if the pattern doesn't match.

## Message format

Messages are stored as individual JSON files named with zero-padded 6-digit sequence numbers: `000042.json`. Supports up to 999,999 messages.

## Test coverage

19 tests across 5 sections:

| Section | Tests | Coverage |
|---------|-------|----------|
| Lock | 2 | Acquire/release, bracket pattern |
| Channel | 5 | Send, round-trip, cursor, sequencing, target field |
| Registry | 3 | Empty read, write/read, modify |
| Reservations | 5 | Defaults, reserve, release, expiry detection, holder check |
| Integration | 4 | Claim, conflict detection, co-claim, git operations |

Tests run in a temporary directory with a fresh git repo.

## Known limitations

- `fsnotify` is a dependency but polling is used instead. Could switch to event-based watching for lower latency.
- Sequence numbers are 6-digit zero-padded (max 999,999 messages). No overflow handling.
- `reservations` command cleans up expired entries, but nothing else does proactively — expired reservations persist until someone reads them.
- The `purpose` field on reservations is declared in the type but never set by any command.
- No `--purpose` flag on `reserve`.
- `tee` appends to the log file without rotation or size limits.
