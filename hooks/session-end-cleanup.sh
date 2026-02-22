#!/bin/bash
# SessionEnd hook: clean up claude-collab agent registration
# Unclaims all files and removes the agent from the registry.

set -euo pipefail

REGISTRY=".claude/agents/registry.json"
if [ ! -f "$REGISTRY" ]; then
    exit 0
fi

# Clean up all registered agents
for AGENT_HASH in $(jq -r 'keys[]' "$REGISTRY" 2>/dev/null); do
    claude-collab cleanup "$AGENT_HASH" 2>/dev/null || true
done

exit 0
