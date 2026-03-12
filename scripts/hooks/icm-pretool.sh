#!/usr/bin/env bash
# icm-hook-version: 1
# ICM PreToolUse hook for Claude Code
# Auto-allows `icm` CLI commands without permission prompts.
# Install: icm init --mode hook
#
# Input (stdin): JSON with tool_name, tool_input (command, etc.)
# Output: JSON with permissionDecision=allow if it's an icm command

set -euo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only intercept Bash commands
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$CMD" ]; then
  exit 0
fi

# Check if this is an icm command (starts with "icm " or is just "icm")
# Also handle piped commands: "echo ... | icm extract"
case "$CMD" in
  icm|icm\ *|*\ icm\ *|*\|\ icm\ *|*\|icm\ *)
    ;;
  *)
    exit 0
    ;;
esac

# Auto-allow icm commands — no permission prompt needed
jq -n \
  --argjson input "$(echo "$INPUT" | jq -c '.tool_input')" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "permissionDecisionReason": "ICM auto-allow",
      "updatedInput": $input
    }
  }'
