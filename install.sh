#!/bin/bash
# Install claude-collab hooks and config into the current repo.
# Run from your project root: bash /path/to/claude-collab/install.sh
#
# What it does:
#   1. Copies CLAUDE_COLLAB.md to the project root
#   2. Installs Claude Code hooks into .claude/hooks/
#   3. Configures hooks in .claude/settings.json
#   4. Creates .claude/agents/resources.json with defaults
#   5. Adds a reminder to CLAUDE.md (if it exists)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing claude-collab into $(pwd)..."

# 1. Copy CLAUDE_COLLAB.md
cp "$SCRIPT_DIR/docs/CLAUDE_COLLAB.md" ./CLAUDE_COLLAB.md
echo "  [+] CLAUDE_COLLAB.md"

# 2. Copy hooks
mkdir -p .claude/hooks
cp "$SCRIPT_DIR/hooks/session-start-init.sh" .claude/hooks/
cp "$SCRIPT_DIR/hooks/pre-edit-claim.sh" .claude/hooks/
cp "$SCRIPT_DIR/hooks/session-end-cleanup.sh" .claude/hooks/
chmod +x .claude/hooks/*.sh
echo "  [+] .claude/hooks/ (3 hooks)"

# 3. Configure hooks in settings.json
SETTINGS=".claude/settings.json"
if [ -f "$SETTINGS" ]; then
    # Merge hooks into existing settings using jq
    if command -v jq &>/dev/null; then
        HOOKS_JSON='{"hooks":{"SessionStart":[{"matcher":"","command":"bash .claude/hooks/session-start-init.sh"}],"PreToolUse":[{"matcher":"Edit|Write","command":"bash .claude/hooks/pre-edit-claim.sh"}],"SessionEnd":[{"matcher":"","command":"bash .claude/hooks/session-end-cleanup.sh"}]}}'
        jq --argjson hooks "$HOOKS_JSON" '. * $hooks' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
        echo "  [+] Updated $SETTINGS (merged hooks)"
    else
        echo "  [!] jq not found — please add hooks to $SETTINGS manually (see docs/CLAUDE_COLLAB.md)"
    fi
else
    cat > "$SETTINGS" << 'SETTINGS_EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "command": "bash .claude/hooks/session-start-init.sh"
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "command": "bash .claude/hooks/pre-edit-claim.sh"
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "command": "bash .claude/hooks/session-end-cleanup.sh"
      }
    ]
  }
}
SETTINGS_EOF
    echo "  [+] Created $SETTINGS"
fi

# 4. Create default resources.json
mkdir -p .claude/agents
RESOURCES=".claude/agents/resources.json"
if [ ! -f "$RESOURCES" ]; then
    cat > "$RESOURCES" << 'RESOURCES_EOF'
{
  "build": {"default_ttl": 300, "description": "Build / compile"},
  "test": {"default_ttl": 1200, "description": "Test suite"}
}
RESOURCES_EOF
    echo "  [+] Created $RESOURCES (edit to match your project)"
else
    echo "  [=] $RESOURCES already exists, skipping"
fi

# 5. Link from CLAUDE.md
CLAUDE_MD="CLAUDE.md"
COLLAB_LINK='Read and follow the instructions in CLAUDE_COLLAB.md for multi-agent coordination.'
if [ -f "$CLAUDE_MD" ]; then
    if ! grep -q "CLAUDE_COLLAB" "$CLAUDE_MD"; then
        printf '\n## Multi-Agent Collaboration\n\n%s\n' "$COLLAB_LINK" >> "$CLAUDE_MD"
        echo "  [+] Appended collaboration section to CLAUDE.md"
    else
        echo "  [=] CLAUDE.md already references CLAUDE_COLLAB.md"
    fi
else
    printf '# Project Guidelines\n\n## Multi-Agent Collaboration\n\n%s\n' "$COLLAB_LINK" > "$CLAUDE_MD"
    echo "  [+] Created CLAUDE.md with collaboration link"
fi

echo ""
echo "Done. Make sure claude-collab is in your PATH, then start multiple Claude Code sessions."
