# Tutorial: Resource Reservations

Some operations can't run in parallel — two agents running the test suite simultaneously would interfere with each other. Resource reservations provide exclusive access.

## Default resources

When you run `claude-collab install`, it creates `.claude/agents/resources.json` with:

```json
{
  "build": {"default_ttl": 300, "description": "Build / compile"},
  "test": {"default_ttl": 1200, "description": "Test suite"}
}
```

You can add custom resources by editing this file.

## Basic usage: reserve and release

### Reserve before running tests

```bash
claude-collab reserve agent-a3f8 test
```

```json
{"ok": true, "resource": "test", "ttl": 1200}
```

The agent now has exclusive access to the test suite for 1200 seconds (20 minutes).

### Run your tests, then release

```bash
# ... run tests ...
claude-collab release agent-a3f8 test
```

```json
{"ok": true, "resource": "test"}
```

## What happens when the resource is busy

If Agent B tries to reserve while Agent A holds it:

```bash
claude-collab reserve agent-7c4e test
```

The tool **polls** every 500ms, waiting for Agent A to release. By default it waits up to 30 seconds. You can change this:

```bash
claude-collab reserve agent-7c4e test --timeout 60
```

If the resource isn't freed in time, the command exits with code 2:

```json
{"ok": false, "error": "timeout waiting for resource: test"}
```

## Stale reservations (TTL expiry)

If an agent crashes or forgets to release, the reservation expires after its TTL. When another agent tries to reserve an expired resource, it takes over with a warning:

```
stderr: Taking over expired reservation for test (was held by agent-a3f8)
```

You can also check reservation status:

```bash
claude-collab reservations
```

```json
{
  "ok": true,
  "resources": [
    {"name": "build", "description": "Build / compile", "status": "available"},
    {"name": "test", "description": "Test suite", "status": "reserved", "holder": "agent-a3f8", "remaining": 245}
  ]
}
```

## Using --renew for back-to-back runs

If you need to run tests again while already holding the reservation, use `--renew`:

```bash
claude-collab reserve agent-a3f8 test --renew
```

This atomically releases and re-reserves in a single lock acquisition. Without `--renew`, doing `release` then `reserve` separately creates a window where another agent could grab the resource between the two calls.

## Custom TTL

Override the default TTL for a specific reservation:

```bash
claude-collab reserve agent-a3f8 build --ttl 60
```

This reserves the build resource for 60 seconds instead of the default 300.

## Key points

- Reserve before running tests, builds, or any exclusive operation
- The tool polls automatically when a resource is busy — no need to retry manually
- Use `--renew` for back-to-back reservations to avoid race conditions
- Stale reservations (past TTL) are automatically taken over
- `cleanup` releases all of an agent's reservations
