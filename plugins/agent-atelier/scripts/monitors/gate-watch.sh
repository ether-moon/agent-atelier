#!/usr/bin/env bash
#
# gate-watch.sh — Gate resolution detection monitor for Claude Code Monitor Tool.
#
# Polls the human-gates/open/ directory and emits structured JSON events
# when gate files appear or disappear. In multi-session Conductor setups,
# a gate may be resolved by a different session — this monitor detects
# that so the current session can react without re-scanning.
#
# Uses portable polling (no fswatch dependency). Bash 3.2+ compatible.
#
# Usage:
#   gate-watch.sh [--state-dir <path>]  Watch for gate changes
#   gate-watch.sh --help                Show this help message
#
# Options:
#   --state-dir <path>   Path to orchestration state directory
#                        (default: .agent-atelier)
#
# Output format (one JSON object per line, stdout only):
#   {"event":"gate_resolved","timestamp":"<ISO-8601>","gate_id":"HDR-NNN","file":"HDR-NNN.json"}
#   {"event":"gate_opened","timestamp":"<ISO-8601>","gate_id":"HDR-NNN","file":"HDR-NNN.json"}
#
# Exit codes:
#   0  Clean shutdown (SIGTERM/SIGINT)
#   1  Usage error or missing arguments

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────

DEFAULT_POLL_INTERVAL=10

usage() {
  cat >&2 <<'USAGE'
gate-watch.sh — Gate resolution detection monitor

Usage:
  gate-watch.sh [--state-dir <path>] [--poll-interval <seconds>]
  gate-watch.sh --help                Show this help

Options:
  --state-dir <path>          Path to orchestration state directory
                              (default: .agent-atelier)
  --poll-interval <seconds>   Seconds between directory scans (default: 10)

Output: structured JSON one-liners to stdout on gate state changes.
Debug logging goes to stderr (ignored by Monitor Tool).

Events:
  gate_resolved   A gate file disappeared from open/ (resolved elsewhere)
  gate_opened     A new gate file appeared in open/

Exit codes:
  0  Clean shutdown
  1  Usage error
USAGE
}

log() {
  printf '%s [gate-watch] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# json_escape — escape backslashes and double quotes for safe JSON embedding
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

emit() {
  local event="$1" gate_id="$2" file="$3"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Escape user-controlled strings for JSON safety
  gate_id="$(json_escape "$gate_id")"
  file="$(json_escape "$file")"
  printf '{"event":"%s","timestamp":"%s","gate_id":"%s","file":"%s"}\n' \
    "$event" "$ts" "$gate_id" "$file"
}

# Extract gate ID from filename: "HDR-007.json" -> "HDR-007"
gate_id_from_file() {
  local file="$1"
  local base
  base="${file%.json}"
  printf '%s' "$base"
}

# ── Snapshot ─────────────────────────────────────────────────────────
# List all *.json filenames in the open gates directory, one per line,
# sorted for stable comparison. Returns empty string if the directory
# does not exist.

snapshot_open_gates() {
  local gate_dir="$1"
  if [ ! -d "$gate_dir" ]; then
    return 0
  fi
  # Use find for robust handling of special filenames (avoids SC2012/SC2035).
  find "$gate_dir" -maxdepth 1 -name '*.json' -type f -exec basename {} \; 2>/dev/null | sort
}

# ── Diff & Emit ──────────────────────────────────────────────────────
# Compare two snapshots (newline-delimited filename lists) stored in
# temp files. Emit events for additions and removals.

diff_and_emit() {
  local prev_file="$1" curr_file="$2"

  # Files that were in prev but not in curr -> resolved.
  local resolved
  resolved="$(comm -23 "$prev_file" "$curr_file")" || true
  if [ -n "$resolved" ]; then
    local file
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      local gid
      gid="$(gate_id_from_file "$file")"
      emit "gate_resolved" "$gid" "$file"
    done <<EOF
$resolved
EOF
  fi

  # Files that are in curr but not in prev -> opened.
  local opened
  opened="$(comm -13 "$prev_file" "$curr_file")" || true
  if [ -n "$opened" ]; then
    local file
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      local gid
      gid="$(gate_id_from_file "$file")"
      emit "gate_opened" "$gid" "$file"
    done <<EOF
$opened
EOF
  fi
}

# ── Cleanup ──────────────────────────────────────────────────────────

PREV_SNAP=""
CURR_SNAP=""

cleanup() {
  [ -z "$PREV_SNAP" ] || rm -f "$PREV_SNAP"
  [ -z "$CURR_SNAP" ] || rm -f "$CURR_SNAP"
}

trap cleanup EXIT

# Handle SIGTERM/SIGINT gracefully — exit 0 for clean shutdown.
shutdown() {
  log "shutting down"
  cleanup
  exit 0
}

trap shutdown INT TERM

# ── Main ─────────────────────────────────────────────────────────────

main() {
  local state_dir=".agent-atelier"
  POLL_INTERVAL="$DEFAULT_POLL_INTERVAL"

  while [ $# -gt 0 ]; do
    case "$1" in
      --state-dir)
        [ $# -ge 2 ] || { log "ERROR: --state-dir requires an argument"; usage; exit 1; }
        state_dir="$2"
        shift 2
        ;;
      --poll-interval)
        [ $# -ge 2 ] || { log "ERROR: --poll-interval requires an argument"; usage; exit 1; }
        POLL_INTERVAL="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        log "ERROR: unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  # Validate poll interval is a positive integer
  case "$POLL_INTERVAL" in
    ''|*[!0-9]*) log "ERROR: --poll-interval must be a positive integer"; exit 1 ;;
  esac
  [ "$POLL_INTERVAL" -ge 1 ] || { log "ERROR: --poll-interval must be >= 1"; exit 1; }

  local gate_dir="${state_dir}/human-gates/open"

  log "watching gate directory: $gate_dir"

  # Create temp files for snapshot comparison.
  PREV_SNAP="$(mktemp)"
  CURR_SNAP="$(mktemp)"

  # Wait for the gate directory to exist before taking the first snapshot.
  while [ ! -d "$gate_dir" ]; do
    log "waiting for $gate_dir to appear..."
    sleep "$POLL_INTERVAL"
  done

  # Take the initial snapshot (no events emitted for pre-existing gates).
  snapshot_open_gates "$gate_dir" > "$PREV_SNAP"

  local count
  count="$(wc -l < "$PREV_SNAP" | tr -d ' ')"
  log "initial snapshot: $count gate(s) in open/"

  # Poll loop — runs until killed.
  while true; do
    sleep "$POLL_INTERVAL"

    snapshot_open_gates "$gate_dir" > "$CURR_SNAP"

    # Skip diff if snapshots are identical (common case).
    if ! cmp -s "$PREV_SNAP" "$CURR_SNAP"; then
      diff_and_emit "$PREV_SNAP" "$CURR_SNAP"

      # Swap: current becomes previous for next iteration.
      cp "$CURR_SNAP" "$PREV_SNAP"
    fi
  done
}

main "$@"
