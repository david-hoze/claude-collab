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
│   ├── Git.hs                 # git status/add/commit wrappers
│   ├── Commands.hs            # All command implementations
│   └── Install.hs             # Install hooks, config, and resources into a repo
test/
└── Spec.hs                    # Test suite
```

### Dependencies

- `optparse-applicative` — CLI parsing
- `aeson` / `aeson-pretty` — JSON
- `directory` — file/directory operations
- `process` — git subprocess execution
- `time` — timestamps
- `filepath` — path manipulation
- `bytestring` / `text` — string handling
- `containers` — Map

## Concurrency & atomicity

### mkdir locks

The only locking mechanism. `mkdir` is atomic on NTFS, ext4, APFS, and HFS+. Two lock directories:

| Lock | Path | Stale timeout | Used by |
|------|------|---------------|---------|
| Git | `.claude/agents/.git-lock/` | 30s | `commit` (git commit serialization) |
| Reserve | `.claude/agents/.reserve-lock/` | 5s | `reserve`, `release`, `cleanup` |

Behavior: spin-retry every 20ms. If the lock directory is older than the stale timeout, force-break it (rmdir + retry).

### Atomic file writes

All JSON file writes use write-to-temp-then-rename. On Windows, the destination is removed before renaming (Windows `rename` fails if target exists).

### Registry writes

`registry.json` uses read-modify-write without a lock. There's a small race window between read and rename, but agents operate at human speed, so collisions are unlikely.

## Path handling

All file paths are normalized: backslashes are converted to forward slashes before comparison or storage. This allows Windows and Unix path styles to coexist in the registry.

## Git integration

Uses `readProcessWithExitCode` to run:
- `git status --porcelain` — parsed into (status, path) pairs
- `git add <files>` — stages specific files
- `git commit -m <message>` — commit hash extracted from output

The commit hash extraction parses the `[branch hash]` pattern from git's output. Falls back to the first 40 characters if the pattern doesn't match.

## Test coverage

Tests across 4 sections:

| Section | Coverage |
|---------|----------|
| Lock | Acquire/release, bracket pattern |
| Registry | Empty read, write/read, modify |
| Reservations | Defaults, reserve, release, expiry detection, holder check |
| Integration | Claim, conflict detection, co-claim, git operations |

Tests run in a temporary directory with a fresh git repo.

## Known limitations

- `reservations` command cleans up expired entries, but nothing else does proactively — expired reservations persist until someone reads them.
- The `purpose` field on reservations is declared in the type but never set by any command.
- No `--purpose` flag on `reserve`.
- `tee` appends to the log file without rotation or size limits.
