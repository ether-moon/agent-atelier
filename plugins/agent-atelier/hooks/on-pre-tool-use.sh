#!/usr/bin/env bash
# PreToolUse hook — blocks destructive commands.
# Exit 0 = allow, Exit 2 = block with feedback message on stdout.
# Loose v1: block only clearly destructive/irreversible ops.

set -euo pipefail

TOOL_NAME="${CLAUDE_TOOL_NAME:-}"
TOOL_INPUT="${CLAUDE_TOOL_INPUT:-}"

# Only inspect Bash commands
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

# Extract the command from tool input (JSON string)
COMMAND=$(echo "$TOOL_INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('command',''))" 2>/dev/null || echo "")
[[ -n "$COMMAND" ]] || exit 0

# ── Destructive command blocklist ─────────────────────────────────
# Each pattern is checked against the full command string.
BLOCK_PATTERNS=(
  'rm\s+-rf\s+/'                    # rm -rf with absolute path
  'git\s+push\s+.*--force'          # force push
  'git\s+push\s+.*-f\b'            # force push short flag
  'git\s+reset\s+--hard'            # hard reset
  'git\s+clean\s+-fd'               # clean untracked files
  'DROP\s+TABLE'                     # SQL drop table
  'DROP\s+DATABASE'                  # SQL drop database
  'DELETE\s+FROM\s+\S+\s*;'         # DELETE without WHERE
  'TRUNCATE\s+TABLE'                # SQL truncate
  'migrate.*--destructive'           # destructive migrations
  'migrate.*down\s+all'             # rollback all migrations
  'chmod\s+777'                      # world-writable permissions
  'curl.*\|\s*sh'                   # pipe curl to shell
  'curl.*\|\s*bash'                 # pipe curl to bash
  'wget.*\|\s*sh'                   # pipe wget to shell
)

for pattern in "${BLOCK_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qiE "$pattern"; then
    echo "BLOCKED: Destructive command detected matching pattern: $pattern"
    echo "Command: $COMMAND"
    echo "If this is intentional, perform this operation manually."
    exit 2
  fi
done

exit 0
