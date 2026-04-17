---
name: watchdog
description: "Health check and mechanical recovery — detect stale leases, expired candidates, stuck reviews, and blocked work items, then take safe recovery actions. Also enforces operating budgets and replays interrupted transactions. Use for routine health checks, when something seems stuck, or when the user says 'watchdog', 'health check', 'check for stale items', 'anything stuck?', 'run maintenance', 'check budgets', 'recovery sweep', or 'clean up orphaned leases'. Also appropriate after a session crash or long idle period."
argument-hint: "[tick]"
---

# Watchdog — Health Check and Mechanical Recovery

Agent sessions can crash, time out, or disappear. Without cleanup, work items stay in `implementing` forever with expired leases, blocking progress. The watchdog detects these situations and takes safe, mechanical recovery actions.

In the long-running loop, watchdog `tick` is the mechanical half of a 15-minute recovery pulse. Teammate respawn, owner reachability checks, and work re-dispatch are Orchestrator responsibilities after the tick completes.

## When This Skill Runs

- Routine health check (recommended: start of each orchestrator session)
- After a session crash or unexpected termination
- When the user suspects something is stuck
- Periodically during long-running orchestration loops
- As the first step of the 15-minute recovery pulse from `/agent-atelier:run`

## Prerequisites

- Orchestration must be initialized (`.agent-atelier/` state files exist)

## Allowed Tools

- Read (state files, HDR files), Bash (git root, state-commit), Glob

## Safety Principle

The watchdog performs ONLY mechanical, reversible recovery. It never edits product code, merges branches, resolves human gates, invents validation results, or makes product decisions. Promoting the next candidate from `candidate_queue` is mechanical (FIFO order was already decided). If something requires judgment, the watchdog escalates to the orchestrator.

The watchdog does not assess whether a lease holder is still reachable. If a WI remains `implementing` with an unexpired lease, the watchdog leaves it alone; the Orchestrator's recovery pulse handles reachability.

## Write Protocol

All state mutations go through `state-commit`. The watchdog reads all three state files, computes recovery actions, and commits them in a single transaction with `expected_revision` per file. On `stale_revision`, re-read state and retry.

## Subcommands

### `tick`

The only subcommand. Runs the full health check and recovery sweep described in Execution Steps below.

## Execution Steps

Each step is summarized below. See `reference/execution-details.md` for field-level specifics.

1. **WAL Recovery** — If `.agent-atelier/.pending-tx.json` exists, replay the interrupted transaction with `state-commit --replay` before any other checks.
2. **Read State** — Read `loop-state.json`, `work-items.json`, `watchdog-jobs.json`. Note timeout thresholds: implementing (90 min), candidate (30 min), review (30 min), gate warning (24 hr).
3. **Stale Leases** — For each `implementing` WI with an expired lease: requeue to `ready`, clear lease fields, increment `stale_requeue_count`.
4. **Stale Reviews** — For each `reviewing` WI past `review_timeout_minutes`: requeue to `ready`.
5. **Stale Candidates** — If `active_candidate_set` has timed out: requeue all WIs, clear promotion metadata, advance queue (FIFO) if non-empty.
6. **Long-Open Gates** — Scan `human-gates/open/` for HDR files older than `gate_warn_after_hours`. Create warning alerts.
7. **Repeated Failures** — Flag WIs with 3+ same finding fingerprints or 2+ watchdog interventions for orchestrator review.
8. **Budget Enforcement** — Check wall-clock time, handoff count, watchdog interventions, and attempt count against thresholds. Create `budget_exceeded` alerts (no auto-cancel).
9. **Commit** — All changes from steps 3-8 go in a single `state-commit` transaction with `expected_revision` per file. On stale revision, re-read and retry.
10. **Report** — Output a summary of recoveries, alerts, and escalations.

After the report, the Orchestrator may respawn teammates, re-message owners, requeue WIs with unreachable owners, and re-dispatch recovered work.

## Examples

**Invocation (typical):**
```bash
/agent-atelier:watchdog tick
```

**Clean tick (no issues):**
```json
{"request_id": "REQ-WD-001", "accepted": true, "changed": false, "recovered": [], "alerts_created": [], "escalations": []}
```

**Tick with recovery:**
```json
{"request_id": "REQ-WD-002", "accepted": true, "changed": true, "tick_at": "2026-04-08T12:00:00Z",
 "recovered": [{"work_item_id": "WI-014", "action": "requeued", "reason": "lease expired", "stale_requeue_count": 2}],
 "alerts_created": [{"id": "WDA-003", "type": "long_open_gate", "work_item_id": "WI-012"}],
 "escalations": []}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Tick completed (with or without recovery actions) |
| `1` | Usage error (invalid arguments) |
| `2` | Stale revision (another writer changed state between read and commit) |
| `3` | State files not found (not initialized) |
| `4` | Runtime or environment failure |

## Input Conventions

The `tick` subcommand takes no payload. Optional flag:
- `--request-id <id>` — audit trail identifier (optional since tick is inherently idempotent)

## Output Contract

Returns JSON to stdout. See `reference/execution-details.md` for the full schema. When presenting to a human, also render a readable summary showing recovered items, alerts, escalations, and healthy items.

## Idempotency

Watchdog `tick` is inherently idempotent. Running it multiple times with the same state produces the same recovery actions. Already-recovered items will not be in the triggering state on re-run.

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| State files missing | `3` | Suggest running `/agent-atelier:init` |
| WI references non-existent gate | `0` | Log inconsistency, suggest manual cleanup |
| Runtime error during tick | `4` | Report and stop — never make partial writes |
| Stale revision on commit | `2` | Re-read all state files and retry the entire tick |

## Constraints

- All recovery actions are logged. The watchdog never silently changes state.
- The watchdog acts on observed state only — no memory across invocations.
- When in doubt, escalate rather than recover. A stuck item that gets human attention is better than a recovered item that loses work.
- The watchdog must not infer teammate liveness from lease state. Reachability checks belong to the Orchestrator's post-tick recovery sweep.
