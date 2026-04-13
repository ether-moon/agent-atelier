#!/usr/bin/env bash
#
# ci-status.sh — CI/PR status polling monitor for Claude Code Monitor Tool.
#
# Emits structured JSON one-liners to stdout on each CI status change.
# Designed for use with Claude Code's Monitor tool during candidate
# validation to watch GitHub Actions runs or PR check suites.
#
# Usage:
#   ci-status.sh --run-id <ID>       Watch a specific GitHub Actions run
#   ci-status.sh --pr <NUMBER>       Poll PR check status at 30s intervals
#   ci-status.sh --help              Show this help message
#
# Output format (one JSON object per line):
#   {"event":"ci_status","timestamp":"<ISO-8601>","run_id":"<id>",
#    "status":"in_progress|completed","conclusion":"success|failure|cancelled|null",
#    "url":"<run-or-checks-url>"}
#
# Exit codes:
#   0  Run completed (any conclusion)
#   1  Usage error or missing arguments
#   2  gh CLI not installed or not authenticated
#   3  Target not found (bad run ID or PR number)
#   4  Runtime error (network, unexpected gh output)

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'USAGE'
ci-status.sh — CI/PR status polling monitor

Usage:
  ci-status.sh --run-id <ID>       Watch a GitHub Actions run
  ci-status.sh --pr <NUMBER>       Poll PR check status (30s interval)
  ci-status.sh --help              Show this help

Output: structured JSON one-liners to stdout on each status change.
Debug logging goes to stderr (ignored by Monitor Tool).

Exit codes:
  0  Run completed
  1  Usage error
  2  gh CLI not available or not authenticated
  3  Target not found
  4  Runtime error
USAGE
}

log() {
  printf '%s [ci-status] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# json_escape — escape backslashes and double quotes for safe JSON embedding
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

emit() {
  local status="$1" conclusion="$2" run_id="$3" url="$4"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Escape user-controlled strings for JSON safety
  local safe_run_id safe_url
  safe_run_id="$(json_escape "$run_id")"
  safe_url="$(json_escape "$url")"
  printf '{"event":"ci_status","timestamp":"%s","run_id":"%s","status":"%s","conclusion":%s,"url":"%s"}\n' \
    "$ts" "$safe_run_id" "$status" "$conclusion" "$safe_url"
}

# Quote a value for JSON: wraps in double quotes, or emits null for empty/null.
json_str_or_null() {
  local v="$1"
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    printf 'null'
  else
    printf '"%s"' "$v"
  fi
}

# ── Preflight ────────────────────────────────────────────────────────

check_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    log "ERROR: gh CLI not found in PATH"
    exit 2
  fi
  if ! gh auth status >/dev/null 2>&1; then
    log "ERROR: gh CLI not authenticated — run 'gh auth login' first"
    exit 2
  fi
}

# ── Mode: --run-id ───────────────────────────────────────────────────
# Uses `gh run view` to poll a single Actions run until it reaches a
# terminal status. We poll ourselves rather than using `gh run watch`
# because watch produces human-readable output that is hard to parse
# reliably, and we need structured JSON.

watch_run() {
  local run_id="$1"
  local prev_status=""

  log "watching run $run_id"

  # Validate the run exists with an initial fetch.
  local initial
  if ! initial="$(gh run view "$run_id" --json status,conclusion,url 2>&1)"; then
    log "ERROR: could not fetch run $run_id — $initial"
    exit 3
  fi

  while true; do
    local raw
    if ! raw="$(gh run view "$run_id" --json status,conclusion,url 2>&1)"; then
      log "WARN: transient error fetching run $run_id — $raw"
      sleep 15
      continue
    fi

    # Parse fields from the already-fetched JSON via --jq (single call).
    local status conclusion url
    local parsed
    parsed="$(gh run view "$run_id" --json status,conclusion,url --jq '[.status, .conclusion, .url] | @tsv' 2>/dev/null)" || parsed=""
    IFS=$'\t' read -r status conclusion url <<< "$parsed"

    # Normalize: gh may omit conclusion for in-progress runs.
    status="${status:-in_progress}"
    url="${url:-}"

    local conclusion_json
    conclusion_json="$(json_str_or_null "$conclusion")"

    # Emit only on status change.
    local cur_key="${status}:${conclusion}"
    if [ "$cur_key" != "$prev_status" ]; then
      emit "$status" "$conclusion_json" "$run_id" "$url"
      prev_status="$cur_key"
    fi

    # Terminal state: only "completed" is a status value.
    # "failure" and "cancelled" are conclusion values under status=completed.
    if [ "$status" = "completed" ]; then
      log "run $run_id reached terminal status: $status (conclusion: ${conclusion:-none})"
      exit 0
    fi

    sleep 15
  done
}

# ── Mode: --pr ───────────────────────────────────────────────────────
# Polls `gh pr checks` at 30-second intervals. Derives an aggregate
# status from individual check results and emits JSON on change.

watch_pr() {
  local pr_number="$1"
  local prev_status=""

  log "watching PR #$pr_number checks"

  # Validate the PR exists.
  local pr_url
  if ! pr_url="$(gh pr view "$pr_number" --json url --jq '.url' 2>&1)"; then
    log "ERROR: could not fetch PR #$pr_number — $pr_url"
    exit 3
  fi

  while true; do
    local raw
    if ! raw="$(gh pr checks "$pr_number" --json name,state,link 2>&1)"; then
      log "WARN: transient error fetching PR #$pr_number checks — $raw"
      sleep 30
      continue
    fi

    # If no checks found, gh returns empty JSON array.
    if [ "$raw" = "[]" ] || [ -z "$raw" ]; then
      log "no checks found for PR #$pr_number yet"
      sleep 30
      continue
    fi

    # Aggregate check states. States from gh: SUCCESS, FAILURE, PENDING,
    # CANCELLED, ERROR, SKIPPED, STARTUP_FAILURE, STALE, EXPECTED, NEUTRAL.
    local has_failure=false
    local has_pending=false
    local has_cancelled=false

    # Fetch all check states and first link in a single gh call.
    local checks_raw
    checks_raw="$(gh pr checks "$pr_number" --json state,link 2>/dev/null)" || checks_raw="[]"

    # Parse states from the fetched JSON (use python3 as portable jq fallback).
    local states
    states="$(printf '%s' "$checks_raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data:
    print(c.get('state', ''))
" 2>/dev/null)" || states=""

    local state
    while IFS= read -r state; do
      [ -n "$state" ] || continue
      case "$state" in
        FAILURE|ERROR|STARTUP_FAILURE) has_failure=true ;;
        PENDING|EXPECTED|STALE)        has_pending=true ;;
        CANCELLED)                     has_cancelled=true ;;
      esac
    done <<EOF
$states
EOF

    local agg_status agg_conclusion_raw
    if [ "$has_failure" = true ]; then
      agg_status="completed"
      agg_conclusion_raw="failure"
    elif [ "$has_cancelled" = true ] && [ "$has_pending" = false ]; then
      agg_status="completed"
      agg_conclusion_raw="cancelled"
    elif [ "$has_pending" = true ]; then
      agg_status="in_progress"
      agg_conclusion_raw=""
    else
      agg_status="completed"
      agg_conclusion_raw="success"
    fi

    local agg_conclusion
    agg_conclusion="$(json_str_or_null "$agg_conclusion_raw")"

    # Extract first check's link from already-fetched data, fall back to PR url.
    local checks_url
    checks_url="$(printf '%s' "$checks_raw" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data[0].get('link', '') if data else '')
" 2>/dev/null)" || checks_url=""
    checks_url="${checks_url:-$pr_url}"

    local cur_key="${agg_status}:${agg_conclusion_raw}"
    if [ "$cur_key" != "$prev_status" ]; then
      emit "$agg_status" "$agg_conclusion" "pr-${pr_number}" "$checks_url"
      prev_status="$cur_key"
    fi

    if [ "$agg_status" = "completed" ]; then
      log "PR #$pr_number checks reached terminal status (conclusion: $agg_conclusion_raw)"
      exit 0
    fi

    sleep 30
  done
}

# ── Main ─────────────────────────────────────────────────────────────

# Clean shutdown on SIGTERM/SIGINT — avoids noisy exit code 143.
trap 'exit 0' INT TERM

main() {
  local mode="" target=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id)
        [ $# -ge 2 ] || { log "ERROR: --run-id requires an argument"; usage; exit 1; }
        mode="run"
        target="$2"
        shift 2
        ;;
      --pr)
        [ $# -ge 2 ] || { log "ERROR: --pr requires an argument"; usage; exit 1; }
        mode="pr"
        target="$2"
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

  if [ -z "$mode" ]; then
    log "ERROR: must specify --run-id or --pr"
    usage
    exit 1
  fi

  check_gh

  case "$mode" in
    run) watch_run "$target" ;;
    pr)  watch_pr  "$target" ;;
  esac
}

main "$@"
