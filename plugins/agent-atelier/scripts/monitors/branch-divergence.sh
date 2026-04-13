#!/usr/bin/env bash
# branch-divergence — Monitor for main-branch divergence during long sessions.
#
# Periodically fetches the base branch and counts how many commits it has
# advanced beyond HEAD. Emits structured JSON events to stdout when the
# count changes and exceeds the configured threshold. All diagnostics go
# to stderr so the Monitor Tool only sees clean event lines.
#
# Usage:
#   branch-divergence.sh [--base <branch>] [--interval <seconds>] [--threshold <commits>]
#
# Options:
#   --base <branch>       Remote branch to track (default: main)
#   --interval <seconds>  Polling interval in seconds (default: 300)
#   --threshold <commits> Warn when base is N+ commits ahead (default: 5)
#   --help                Show this help and exit
#
# Output (stdout):
#   {"event":"branch_divergence","timestamp":"<ISO-8601>","base_branch":"main",
#    "commits_behind":NNN,"last_base_commit":"<short_sha>","severity":"warning|critical"}
#
# Severity levels:
#   warning  — commits_behind >= threshold
#   critical — commits_behind >= threshold * 3
#
# Exit codes: 0=clean shutdown, 1=usage error, 2=not a git repository

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
BASE_BRANCH="main"
INTERVAL=300
THRESHOLD=5

# ── Argument parsing ─────────────────────────────────────────────────
usage() {
  cat >&2 <<'USAGE'
branch-divergence — Monitor for main-branch divergence during long sessions.

Periodically fetches the base branch and counts how many commits it has
advanced beyond HEAD. Emits structured JSON events when divergence exceeds
the threshold.

Usage:
  branch-divergence.sh [--base <branch>] [--interval <seconds>] [--threshold <commits>]

Options:
  --base <branch>       Remote branch to track (default: main)
  --interval <seconds>  Polling interval in seconds (default: 300)
  --threshold <commits> Warn when base is N+ commits ahead (default: 5)
  --help                Show this help and exit
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || { echo "error: --base requires a value" >&2; exit 1; }
      BASE_BRANCH="$2"; shift 2 ;;
    --interval)
      [[ $# -ge 2 ]] || { echo "error: --interval requires a value" >&2; exit 1; }
      INTERVAL="$2"; shift 2 ;;
    --threshold)
      [[ $# -ge 2 ]] || { echo "error: --threshold requires a value" >&2; exit 1; }
      THRESHOLD="$2"; shift 2 ;;
    --help|-h)
      usage 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage 1 ;;
  esac
done

# ── Validate numeric arguments ───────────────────────────────────────
case "$INTERVAL" in
  ''|*[!0-9]*) echo "error: --interval must be a positive integer" >&2; exit 1 ;;
esac
case "$THRESHOLD" in
  ''|*[!0-9]*) echo "error: --threshold must be a positive integer" >&2; exit 1 ;;
esac
if [[ "$INTERVAL" -lt 1 ]]; then
  echo "error: --interval must be >= 1" >&2; exit 1
fi
if [[ "$THRESHOLD" -lt 1 ]]; then
  echo "error: --threshold must be >= 1" >&2; exit 1
fi

# ── Precondition: must be inside a git repository ─────────────────────
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not inside a git repository" >&2
  exit 2
fi

# Clean shutdown on SIGTERM/SIGINT — avoids noisy exit code 143.
trap 'exit 0' INT TERM

echo "monitor: branch-divergence started (base=$BASE_BRANCH interval=${INTERVAL}s threshold=$THRESHOLD)" >&2

# ── Helpers ───────────────────────────────────────────────────────────

# iso_timestamp — portable ISO-8601 UTC timestamp (Bash 3.2+ / macOS)
iso_timestamp() {
  if date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null; then
    return
  fi
  # Fallback for unusual environments
  python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || echo "unknown"
}

# emit_event — write a single JSON event line to stdout
emit_event() {
  local behind="$1"
  local short_sha="$2"
  local severity="$3"
  local ts
  ts=$(iso_timestamp)

  # Build JSON without external dependencies (Bash 3.2+ safe)
  printf '{"event":"branch_divergence","timestamp":"%s","base_branch":"%s","commits_behind":%d,"last_base_commit":"%s","severity":"%s"}\n' \
    "$ts" "$BASE_BRANCH" "$behind" "$short_sha" "$severity"
}

# ── Main loop ─────────────────────────────────────────────────────────
LAST_COUNT=""
CRITICAL_THRESHOLD=$((THRESHOLD * 3))

while true; do
  # Fetch the base branch; swallow errors (offline, transient failures)
  if ! git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null; then
    echo "warn: git fetch origin $BASE_BRANCH failed (network?), will retry" >&2
    sleep "$INTERVAL"
    continue
  fi

  # Count commits HEAD is behind origin/<base>
  BEHIND=$(git rev-list "HEAD..origin/$BASE_BRANCH" --count 2>/dev/null || echo "")
  if [[ -z "$BEHIND" ]]; then
    echo "warn: git rev-list failed, will retry" >&2
    sleep "$INTERVAL"
    continue
  fi

  # Only emit when the count changed AND exceeds the threshold
  if [[ "$BEHIND" -ge "$THRESHOLD" && "$BEHIND" != "$LAST_COUNT" ]]; then
    # Determine severity
    if [[ "$BEHIND" -ge "$CRITICAL_THRESHOLD" ]]; then
      SEVERITY="critical"
    else
      SEVERITY="warning"
    fi

    # Get the short SHA of the latest commit on the base branch
    SHORT_SHA=$(git rev-parse --short "origin/$BASE_BRANCH" 2>/dev/null || echo "unknown")

    emit_event "$BEHIND" "$SHORT_SHA" "$SEVERITY"
    echo "monitor: emitted branch_divergence (behind=$BEHIND severity=$SEVERITY)" >&2
  fi

  LAST_COUNT="$BEHIND"
  sleep "$INTERVAL"
done
