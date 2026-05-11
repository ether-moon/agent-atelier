# Monitor Runtime — LLM-Driven Procedure

This reference documents the procedures invoked by `skills/monitors/SKILL.md` (a thin shim) and by cron jobs created during `/agent-atelier:execute`.

Tools used: `Bash run_in_background`, `TaskOutput`, `TaskStop`. Read this entire file before executing any subcommand.

## Subcommands

### `spawn`

Starts the 4 always-on monitors as background processes.

1. Detect repo root: `git rev-parse --show-toplevel`
2. Resolve plugin root: `<repo-root>/plugins/agent-atelier`
3. Resolve state dir: `<repo-root>/.agent-atelier`
4. For each monitor, invoke `Bash` with `run_in_background=true`:

| Monitor | Command |
|---------|---------|
| heartbeat | `<plugin-root>/scripts/monitors/heartbeat-watch.sh --state-dir <state-dir> --poll-interval 60` |
| gate | `<plugin-root>/scripts/monitors/gate-watch.sh --state-dir <state-dir>` |
| events | `<plugin-root>/scripts/monitors/event-tail.sh --state-dir <state-dir> --filter state_committed` |
| divergence | `<plugin-root>/scripts/monitors/branch-divergence.sh --base main --interval 300 --threshold 5` |

5. Collect each task ID returned by `Bash`.
6. Return the task ID mapping.

**Output:**

```json
{
  "spawned": {
    "heartbeat": "<task_id>",
    "gate": "<task_id>",
    "events": "<task_id>",
    "divergence": "<task_id>"
  },
  "spawned_at": "<ISO-8601 UTC>"
}
```

**Idempotency:** If monitors are already running (task IDs known from a previous `spawn` in this session), skip re-spawning and return the existing mapping with `"already_running": true`.

### `spawn-ci --run-id <ID> | --pr <NUM>`

Starts a ci-status monitor for a specific GitHub Actions run or PR. This is an on-demand monitor — it exits automatically when the CI run reaches a terminal state.

1. Detect repo root and plugin root.
2. Invoke `Bash` with `run_in_background=true`:
   - If `--run-id`: `<plugin-root>/scripts/monitors/ci-status.sh --run-id <ID>`
   - If `--pr`: `<plugin-root>/scripts/monitors/ci-status.sh --pr <NUM>`
3. Return the task ID.

**Output:**

```json
{
  "monitor": "ci-status",
  "task_id": "<task_id>",
  "target": "<run-id or pr-number>",
  "spawned_at": "<ISO-8601 UTC>"
}
```

### `check <task-ids-json>`

Reads accumulated output from all active monitors and classifies events by urgency.

1. Parse `<task-ids-json>` — a JSON object mapping monitor names to task IDs:
   ```json
   {"heartbeat": "t1", "gate": "t2", "events": "t3", "divergence": "t4", "ci-status": "t5"}
   ```
2. For each task ID, call `TaskOutput` with `block=false` to get current output without waiting.
3. Parse each line as JSON (NDJSON format). Skip malformed lines.
4. Classify events into IMMEDIATE, WARNING, or INFO urgency levels. See `reference/event-classification.md` for the full classification table and orchestrator response protocol.
5. Detect dead monitors: if `TaskOutput` returns an error or the task has exited with a non-zero code (for always-on monitors), flag it.
6. Return the classified report.

**Output:**

```json
{
  "checked_at": "<ISO-8601 UTC>",
  "immediate": [
    {"event": "heartbeat_warning", "severity": "expired", "work_item_id": "WI-014", "source": "heartbeat"}
  ],
  "warning": [],
  "info": [],
  "dead_monitors": ["gate"],
  "healthy_monitors": ["heartbeat", "events", "divergence"]
}
```

### `stop [all | <name>]`

Stops one or all monitors.

1. If `all`: iterate all known task IDs and call `TaskStop` for each.
2. If `<name>`: call `TaskStop` for the specified monitor's task ID.
3. Return confirmation with `{"stopped": [...], "stopped_at": "<ISO-8601 UTC>"}`.

**Arguments:**
- `all` — stop all monitors (used during DONE cleanup)
- `<name>` — one of: `heartbeat`, `gate`, `events`, `divergence`, `ci-status`

### `status`

Reports current health of all monitors.

1. For each known task ID, check whether the background task is still running.
2. Return status summary with each monitor's `task_id`, `alive` boolean, and `exit_code` if dead.

## Output formats

- All subcommands return JSON to stdout. Diagnostic messages go to stderr.

## Idempotency

- `spawn` skips already-running monitors (same session).
- `stop` on an already-stopped monitor returns `"changed": false`.
- `check` is inherently idempotent (read-only).

## Error handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| Monitor script not found at expected path | `4` | Report missing path, suggest plugin integrity check |
| `gh` not available (for `spawn-ci`) | `2` | Report dependency missing |
| `jq` not available (for `spawn` heartbeat) | `4` | Report dependency missing |
| TaskOutput returns error | `0` | Flag monitor as dead in check report |
| All monitors dead on check | `0` | Return report with all in `dead_monitors` — orchestrator decides action |

# Event Classification and Orchestrator Response Protocol

## Table of Contents

- [Event Classification Table](#event-classification-table)
- [Orchestrator Response Protocol](#orchestrator-response-protocol)

## Event Classification Table

When `check` parses NDJSON output from monitors, each event is classified by urgency:

| Event Type | Condition | Urgency |
|------------|-----------|---------|
| `heartbeat_warning` | `severity == "expired"` | IMMEDIATE |
| `heartbeat_warning` | `severity == "warning"` | WARNING |
| `gate_resolved` | -- | IMMEDIATE |
| `gate_opened` | -- | IMMEDIATE |
| `ci_status` | `conclusion == "success"` | IMMEDIATE |
| `ci_status` | `conclusion == "failure"` or `"cancelled"` | IMMEDIATE |
| `ci_status` | `conclusion == null` (in-progress) | INFO |
| `branch_divergence` | `severity == "critical"` | IMMEDIATE |
| `branch_divergence` | `severity == "warning"` | WARNING |
| `state_committed` | -- | INFO |

## Orchestrator Response Protocol

This protocol defines what the Orchestrator does when the CronCreate polling prompt receives classified events from `check`:

**IMMEDIATE events -- act within this polling cycle:**

- `heartbeat_warning` (expired) -- trigger `bash <plugin-root>/scripts/watchdog tick`
- `heartbeat_warning` (warning) -- message Builder via `SendMessage` to run `bash <plugin-root>/scripts/lifecycle heartbeat` (non-blocking; log if Builder is unresponsive)
- `gate_resolved` -- re-read gate state, resume blocked WIs
- `gate_opened` -- present HDR to user immediately
- `ci_status` (success) -- evaluate fast-track, then transition to IMPLEMENT or REVIEW_SYNTHESIS
- `ci_status` (failure/cancelled) -- record validation failure, candidate demotion
- `branch_divergence` (critical) -- inform user, strongly recommend rebase

**WARNING events -- act on a best-effort basis this cycle:**

- `heartbeat_warning` (warning) -- nudge Builder; if unresponsive, log for next status report
- `branch_divergence` (warning) -- log for next human-visible status report

**INFO events:** Update situational awareness, no action required.

**Dead monitors:** Re-spawn via `/agent-atelier:monitors spawn` (or `spawn-ci` for ci-status). If same monitor has died 3+ times in a session, escalate to user instead of retrying.
