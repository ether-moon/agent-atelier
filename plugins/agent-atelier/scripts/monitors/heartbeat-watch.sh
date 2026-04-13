#!/usr/bin/env bash
#
# heartbeat-watch.sh — Monitor for approaching lease expiry on active work items.
#
# Polls work-items.json every 60 seconds and emits JSON events to stdout
# when an implementing work item's lease is within 10 minutes of expiry
# or has already expired.  Designed to run under Claude Code's Monitor Tool,
# which feeds each stdout line back to the conversation.
#
# Usage:
#   heartbeat-watch.sh [--state-dir <path>] [--poll-interval <seconds>]
#
# Options:
#   --state-dir <path>      Path to orchestration state directory
#                           (default: .agent-atelier)
#   --poll-interval <secs>  Seconds between checks (default: 60)
#   -h, --help              Show this help message
#
# Output (stdout, one JSON object per line):
#   {"event":"heartbeat_warning","timestamp":"...","work_item_id":"WI-NNN",
#    "lease_expires_at":"...","remaining_seconds":NNN,
#    "severity":"warning|expired","owner_session_id":"..."}
#
# Debug logging goes to stderr.  Only stdout is visible to Monitor.
#
# Requirements: jq (checked on startup)
# Compatibility: Bash 3.2+

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────
readonly WARNING_THRESHOLD_SECS=600   # 10 minutes
readonly DEFAULT_POLL_INTERVAL=60
readonly DEFAULT_STATE_DIR=".agent-atelier"

# ── Helpers ──────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
heartbeat-watch.sh — Lease expiry warning monitor for agent-atelier

Usage:
  heartbeat-watch.sh [--state-dir <path>] [--poll-interval <seconds>]
  heartbeat-watch.sh -h | --help

Options:
  --state-dir <path>      Orchestration state directory (default: .agent-atelier)
  --poll-interval <secs>  Seconds between checks (default: 60)
  -h, --help              Show this help message

Emits JSON events to stdout when a work item's lease is near expiry or expired.
Debug output goes to stderr.
EOF
}

log() {
  printf '[heartbeat-watch %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# iso_to_epoch — Convert ISO 8601 UTC timestamp to Unix epoch seconds.
# Handles both GNU date (Linux) and BSD date (macOS).
# Falls back to a portable awk parser for environments with neither.
# All timestamps are treated as UTC (Z suffix expected).
iso_to_epoch() {
  local ts="$1"

  # Try GNU date first (accepts -d and handles Z natively)
  if date -d "$ts" +%s 2>/dev/null; then
    return 0
  fi

  # Try BSD date (-j -f)
  # Strip trailing Z, timezone offset, and fractional seconds for the
  # format string.  Force TZ=UTC so the parsed time is interpreted
  # correctly — BSD date -j uses local timezone by default.
  local stripped
  stripped="${ts%%Z}"
  stripped="${stripped%%+*}"
  # Remove fractional seconds (.NNN) if present
  stripped="$(printf '%s' "$stripped" | sed 's/\.[0-9]*//')"

  if TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null; then
    return 0
  fi

  # Fallback: parse with awk (handles YYYY-MM-DDTHH:MM:SSZ)
  # TZ=UTC ensures mktime interprets the components as UTC.
  printf '%s' "$ts" | TZ=UTC awk -F'[T:-]' '{
    # mktime expects "YYYY MM DD HH MM SS"
    gsub(/Z/, "", $6)
    t = mktime($1" "$2" "$3" "$4" "$5" "$6)
    if (t == -1) exit 1
    print t
  }' 2>/dev/null && return 0

  return 1
}

now_epoch() {
  date +%s
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ── Argument parsing ─────────────────────────────────────────────────

state_dir="$DEFAULT_STATE_DIR"
poll_interval="$DEFAULT_POLL_INTERVAL"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      [[ $# -lt 2 ]] && { log "ERROR: --state-dir requires an argument"; exit 1; }
      state_dir="$2"; shift 2 ;;
    --poll-interval)
      [[ $# -lt 2 ]] && { log "ERROR: --poll-interval requires an argument"; exit 1; }
      poll_interval="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      log "ERROR: unknown argument: $1"; usage; exit 1 ;;
  esac
done

# Validate poll_interval is a positive integer
if ! [[ "$poll_interval" =~ ^[1-9][0-9]*$ ]]; then
  log "ERROR: --poll-interval must be a positive integer, got: $poll_interval"
  exit 1
fi

# ── Preflight checks ─────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is required but not found in PATH"
  exit 1
fi

# Clean shutdown on SIGTERM/SIGINT — avoids noisy exit code 143.
trap 'exit 0' INT TERM

wi_file="${state_dir}/work-items.json"
log "Starting heartbeat watch  state_dir=$state_dir  poll=${poll_interval}s  warning_threshold=${WARNING_THRESHOLD_SECS}s"

LAST_SEVERITIES=""

# ── Main loop ─────────────────────────────────────────────────────────

while true; do

  # Check that the file exists before attempting to read
  if [[ ! -f "$wi_file" ]]; then
    log "work-items.json not found at $wi_file — waiting for init"
    sleep "$poll_interval"
    continue
  fi

  # Extract implementing items.  jq may fail if the file is mid-write
  # (state-commit uses atomic rename, but a partial read is still
  # theoretically possible on some filesystems).  Suppress errors and
  # retry on the next cycle.
  items_json="$(jq -r '
    .items // [] | map(select(.status == "implementing"))
  ' "$wi_file" 2>/dev/null)" || {
    log "jq parse failed (file may be mid-write) — skipping cycle"
    sleep "$poll_interval"
    continue
  }

  item_count="$(printf '%s' "$items_json" | jq 'length' 2>/dev/null)" || {
    log "jq length check failed — skipping cycle"
    sleep "$poll_interval"
    continue
  }

  if [[ "$item_count" -eq 0 ]]; then
    sleep "$poll_interval"
    continue
  fi

  current_epoch="$(now_epoch)"
  current_iso="$(now_iso)"
  current_severities=""

  # Iterate over each implementing item
  idx=0
  while [[ $idx -lt $item_count ]]; do
    # Extract all three fields in a single jq call (reduces 3N spawns to N).
    fields="$(printf '%s' "$items_json" | jq -r ".[$idx] | [(.id // \"\"), (.lease_expires_at // \"\"), (.owner_session_id // \"\")] | @tsv" 2>/dev/null)" || {
      log "jq field extraction failed for item $idx — skipping"
      idx=$((idx + 1))
      continue
    }
    wi_id="$(printf '%s' "$fields" | cut -f1)"
    lease="$(printf '%s' "$fields" | cut -f2)"
    owner="$(printf '%s' "$fields" | cut -f3)"

    idx=$((idx + 1))

    # Skip items without a lease timestamp
    if [[ -z "$lease" ]]; then
      log "WI $wi_id has no lease_expires_at — skipping"
      continue
    fi

    lease_epoch="$(iso_to_epoch "$lease" 2>/dev/null)" || {
      log "WI $wi_id: could not parse lease_expires_at=$lease — skipping"
      continue
    }

    remaining=$((lease_epoch - current_epoch))

    # Determine severity (empty = healthy, no event needed)
    severity=""
    if [[ $remaining -lt 0 ]]; then
      severity="expired"
    elif [[ $remaining -lt $WARNING_THRESHOLD_SECS ]]; then
      severity="warning"
    fi

    if [[ -n "$severity" ]]; then
      current_severities="${current_severities}${wi_id}=${severity} "

      # Emit only when this WI's severity changed from last poll cycle
      case " ${LAST_SEVERITIES}" in
        *" ${wi_id}=${severity} "*)
          # Same severity as before — suppress duplicate
          ;;
        *)
          printf '{"event":"heartbeat_warning","timestamp":"%s","work_item_id":"%s","lease_expires_at":"%s","remaining_seconds":%d,"severity":"%s","owner_session_id":"%s"}\n' \
            "$current_iso" "$wi_id" "$lease" "$remaining" "$severity" "$owner"
          ;;
      esac
    fi
  done

  LAST_SEVERITIES="$current_severities"
  sleep "$poll_interval"
done
