#!/bin/bash
# PreToolUse hook for Edit|Write: auto-claim files via claude-collab
# Reads JSON from stdin, extracts file_path, claims it if an agent is registered.

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Nothing to claim if no file path
if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Find our agent hash from the registry
REGISTRY=".claude/agents/registry.json"
if [ ! -f "$REGISTRY" ]; then
    exit 0  # Not in collaboration mode
fi

# Get all agent hashes, pick the one matching our session
# (fallback: use the most recently registered agent)
AGENT_HASH=$(jq -r 'keys[-1] // empty' "$REGISTRY" 2>/dev/null)
if [ -z "$AGENT_HASH" ]; then
    exit 0  # No agent registered
fi

# Claim the file (ignore errors if already claimed by us)
claude-collab files claim "$AGENT_HASH" "$FILE_PATH" 2>/dev/null || true

exit 0
