#!/usr/bin/env bash
set -euo pipefail
# event-tail — Follow the semantic event stream (events.ndjson).
#
# Tails .agent-atelier/events.ndjson and passes each new NDJSON line
# to stdout. Designed to be used with Claude Code's Monitor Tool so
# that state changes are surfaced mid-conversation without polling.
#
# Usage:
#   event-tail.sh [--state-dir <path>] [--filter <event_type>]
#
# Options:
#   --state-dir   Path to the orchestration state directory
#                 (default: .agent-atelier)
#   --filter      Only emit events whose "event" field matches this value
#                 (e.g. --filter state_committed)

STATE_DIR=".agent-atelier"
FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --state-dir)
      [ $# -lt 2 ] && { echo "ERROR: --state-dir requires an argument" >&2; exit 1; }
      STATE_DIR="$2"
      shift 2
      ;;
    --filter)
      [ $# -lt 2 ] && { echo "ERROR: --filter requires an argument" >&2; exit 1; }
      FILTER="$2"
      shift 2
      ;;
    *)
      echo "Usage: event-tail.sh [--state-dir <path>] [--filter <event_type>]" >&2
      exit 1
      ;;
  esac
done

EVENTS_FILE="${STATE_DIR}/events.ndjson"

# Create the events file if it doesn't exist yet so tail -f has
# something to attach to immediately.
mkdir -p "$(dirname "$EVENTS_FILE")"
touch "$EVENTS_FILE"

if [ -n "$FILTER" ]; then
  # Filter lines by event type. Use grep -F (fixed-string) with
  # line-buffering so each matching line is flushed immediately.
  # tail -n 0 skips existing lines — only new events are emitted.
  exec tail -n 0 -f "$EVENTS_FILE" | grep -F --line-buffered "\"event\":\"${FILTER}\""
else
  # tail -n 0 ensures only new events are emitted (no historical replay).
  exec tail -n 0 -f "$EVENTS_FILE"
fi
