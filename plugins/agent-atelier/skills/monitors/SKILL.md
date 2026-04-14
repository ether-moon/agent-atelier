---
name: monitors
description: "Background monitor lifecycle — spawn continuous observers, poll for events, stop monitors, or check health. Use when starting the orchestration loop, polling for state changes, cleaning up on exit, or diagnosing monitor health. Triggers on 'spawn monitors', 'check monitors', 'stop monitors', 'monitor status', 'spawn ci monitor', 'poll events'."
argument-hint: "spawn | check <task-ids-json> | stop [all | <name>] | status | spawn-ci --run-id <ID> | --pr <NUM>"
---

# Monitors — Background Observer Lifecycle

Monitors are long-running background processes that observe orchestration state and external systems, emitting structured NDJSON events to stdout. They **never write** to `.agent-atelier/**` — all state mutations triggered by monitor events are routed through the Orchestrator to the appropriate skill (watchdog, gate, execute).

## When This Skill Runs

- The `/run` skill starts the orchestration loop (Phase 2: spawn monitors)
- CronCreate polling fires to check accumulated events
- The loop reaches DONE or the user requests stop (cleanup)
- Cold resume re-spawns monitors after recovery
- Diagnosing why a monitor stopped or is unresponsive

## Prerequisites

- Orchestration must be initialized (`/agent-atelier:init`)
- For `spawn-ci`: a GitHub Actions run ID or PR number must exist

## Allowed Tools

- Bash (`run_in_background` for spawn, `TaskOutput` for check, `TaskStop` for stop)
- Read (state-dir detection via `git rev-parse --show-toplevel`)

## Write Protocol

This skill performs **no state writes**. It only manages background process lifecycles and reads their output. The sole artifacts are background task handles (session-scoped, non-persistent).

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
4. Classify events:

| Event Type | Condition | Urgency |
|------------|-----------|---------|
| `heartbeat_warning` | `severity == "expired"` | IMMEDIATE |
| `heartbeat_warning` | `severity == "warning"` | WARNING |
| `gate_resolved` | — | IMMEDIATE |
| `gate_opened` | — | IMMEDIATE |
| `ci_status` | `conclusion == "success"` | IMMEDIATE |
| `ci_status` | `conclusion == "failure"` or `"cancelled"` | IMMEDIATE |
| `ci_status` | `conclusion == null` (in-progress) | INFO |
| `branch_divergence` | `severity == "critical"` | IMMEDIATE |
| `branch_divergence` | `severity == "warning"` | WARNING |
| `state_committed` | — | INFO |

5. Detect dead monitors: if `TaskOutput` returns an error or the task has exited with a non-zero code (for always-on monitors), flag it.
6. Return the classified report.

**Output:**

```json
{
  "checked_at": "<ISO-8601 UTC>",
  "immediate": [
    {"event": "heartbeat_warning", "severity": "expired", "work_item_id": "WI-014", "source": "heartbeat"}
  ],
  "warning": [
    {"event": "branch_divergence", "severity": "warning", "commits_behind": 7, "source": "divergence"}
  ],
  "info": [
    {"event": "state_committed", "revision": 12, "source": "events"}
  ],
  "dead_monitors": ["gate"],
  "healthy_monitors": ["heartbeat", "events", "divergence"]
}
```

**Orchestrator response protocol** (for the CronCreate polling prompt):

- **IMMEDIATE events:** Act within this polling cycle.
  - `heartbeat_warning` (expired) → trigger `/agent-atelier:watchdog tick`
  - `heartbeat_warning` (warning) → message Builder via `SendMessage` to send `execute heartbeat`
  - `gate_resolved` → re-read gate state, resume blocked WIs
  - `gate_opened` → present HDR to user immediately
  - `ci_status` (success) → proceed with VALIDATE → REVIEW_SYNTHESIS transition
  - `ci_status` (failure/cancelled) → record validation failure, candidate demotion
  - `branch_divergence` (critical) → inform user, strongly recommend rebase
- **WARNING events:** Log for next human-visible status report.
- **INFO events:** Update situational awareness, no action required.
- **Dead monitors:** Re-spawn via `/agent-atelier:monitors spawn` (or `spawn-ci` for ci-status). If same monitor has died 3+ times in a session, escalate to user instead of retrying.

### `stop [all | <name>]`

Stops one or all monitors.

1. If `all`: iterate all known task IDs and call `TaskStop` for each.
2. If `<name>`: call `TaskStop` for the specified monitor's task ID.
3. Return confirmation.

**Arguments:**
- `all` — stop all monitors (used during DONE cleanup)
- `<name>` — one of: `heartbeat`, `gate`, `events`, `divergence`, `ci-status`

**Output:**

```json
{
  "stopped": ["heartbeat", "gate", "events", "divergence"],
  "stopped_at": "<ISO-8601 UTC>"
}
```

### `status`

Reports current health of all monitors.

1. For each known task ID, check whether the background task is still running.
2. Return status summary.

**Output:**

```json
{
  "monitors": {
    "heartbeat": {"task_id": "t1", "alive": true},
    "gate": {"task_id": "t2", "alive": true},
    "events": {"task_id": "t3", "alive": false, "exit_code": 1},
    "divergence": {"task_id": "t4", "alive": true},
    "ci-status": {"task_id": "t5", "alive": true, "target": "pr-42"}
  },
  "checked_at": "<ISO-8601 UTC>"
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage error (missing arguments, invalid subcommand) |
| `4` | Runtime failure (unable to spawn, TaskOutput error) |

## Input Conventions

- `check` accepts task IDs as a JSON object argument
- `spawn-ci` requires either `--run-id` or `--pr` (mutually exclusive)
- `stop` accepts `all` or a monitor name

## Output Contract

All subcommands return JSON to stdout. Diagnostic messages go to stderr.

## Idempotency

- `spawn` skips already-running monitors (same session)
- `stop` on an already-stopped monitor returns `"changed": false`
- `check` is inherently idempotent (read-only)

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| Monitor script not found at expected path | `4` | Report missing path, suggest plugin integrity check |
| `gh` not available (for `spawn-ci`) | `2` | Report dependency missing |
| `jq` not available (for `spawn` heartbeat) | `4` | Report dependency missing |
| TaskOutput returns error | `0` | Flag monitor as dead in check report |
| All monitors dead on check | `0` | Return report with all in `dead_monitors` — orchestrator decides action |

## Constraints

- Monitors are **observation-only** — they never write to `.agent-atelier/**`
- All state mutations triggered by events route through the Orchestrator to the appropriate skill
- Monitor task IDs are **session-scoped** — they do not survive session restarts
- ci-status is the only self-terminating monitor (exits 0 on CI completion)
- The CronCreate poll job that invokes `check` is created by the `/run` skill, not by this skill
