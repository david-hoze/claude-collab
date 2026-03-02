# Changelog

## 0.1.0.0 — 2026-03-02

Initial release.

- **File claims** — declare which files an agent is editing, with conflict detection and co-claiming (`--shared`)
- **Resource reservations** — exclusive access to shared resources (test suite, build) with TTL, timeout, and `--renew`
- **Safe git commits** — only commits an agent's own claimed files; two-phase commit for co-claimed files (first agent stages, last agent commits with combined message)
- **Automatic hooks** — `install` command sets up Claude Code hooks for auto-registration, auto-claiming, and auto-cleanup
- **Agent names** — `init --name` for human-readable agent identifiers, usable in place of hashes
- **Cross-platform** — works on Windows, macOS, and Linux; mkdir-based locking, normalized path handling
