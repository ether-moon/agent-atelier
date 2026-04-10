---
name: watchdog
description: "Health check and mechanical recovery — detect stale leases, expired candidates, and stuck work items, then take safe recovery actions. Use for routine health checks, when something seems stuck, or when the user says 'watchdog', 'health check', 'check for stale items', 'anything stuck?', or 'run maintenance'. Also appropriate after a session crash or long idle period to clean up orphaned leases."
argument-hint: "[tick]"
---

# Watchdog — Health Check and Mechanical Recovery

The watchdog exists because agent sessions can crash, time out, or simply disappear. Without cleanup, work items would stay in `implementing` forever with expired leases, blocking progress. The watchdog detects these situations and takes safe, mechanical recovery actions.

## When This Skill Runs

- Routine health check (recommended: at start of each orchestrator session)
- After a session crash or unexpected termination
- When the user suspects something is stuck
- Periodically during long-running orchestration loops

## Prerequisites

- Orchestration must be initialized

## Allowed Tools

- Read (state files, HDR files), Bash (git root, state-commit), Glob

## Safety Principle

The watchdog performs ONLY mechanical, reversible recovery. It never:
- Edits product code or the behavior spec
- Merges branches
- Resolves human gates
- Invents validation results
- Makes product decisions (promoting the next candidate from `candidate_queue` is mechanical — the queue order was already decided by the Orchestrator)

If something requires judgment, the watchdog escalates to the orchestrator.

## Execution Steps

### 0. Check for Incomplete Transactions (WAL Recovery)

Before anything else, check if `.agent-atelier/.pending-tx.json` exists. This file is a write-ahead log left behind if a previous state-commit was interrupted mid-write.

If found:
1. Read the pending transaction.
2. Replay it with the `--replay` flag:
   ```bash
   cat .agent-atelier/.pending-tx.json | <plugin-root>/scripts/state-commit --root <repo-root> --replay
   ```
   The `--replay` flag handles partially applied transactions correctly: it skips files whose revision already matches the target (already written) and applies only the remaining files. This avoids the stale-revision false rejection that would occur with a normal commit.
3. Report that a WAL recovery was performed, including which files were replayed vs skipped.

If not found, proceed normally.

### 1. Read Current State

Read these files:
- `.agent-atelier/loop-state.json`
- `.agent-atelier/work-items.json`
- `.agent-atelier/watchdog-jobs.json`

Note the timeout thresholds from `watchdog-jobs.json`:
- `implementing_timeout_minutes`: 90 (default)
- `candidate_timeout_minutes`: 30
- `review_timeout_minutes`: 30
- `gate_warn_after_hours`: 24

### 2. Check for Stale Leases

For each work item with status `implementing`:
1. Parse `lease_expires_at`.
2. If the lease has expired (current time > lease_expires_at):
   - Set `status` → `ready`
   - Clear `owner_session_id`, `last_heartbeat_at`, `lease_expires_at`
   - Increment `stale_requeue_count`
   - Set `last_requeue_reason` → `"watchdog: lease expired"`
   - Bump the item's `revision`
   - Record the recovery action

### 2b. Check for Stale Reviews

For each work item with status `reviewing`:
1. Parse `last_heartbeat_at` or the timestamp when status changed to `reviewing`.
2. If elapsed time exceeds `review_timeout_minutes` (default 30):
   - Set `status` → `ready`
   - Set `last_requeue_reason` → `"watchdog: review timeout"`
   - Increment `stale_requeue_count`
   - Record the recovery action

### 3. Check for Stale Candidates

If `active_candidate` exists in loop state:
- Read `candidate_activated_at` from loop state — this records when the candidate entered the active slot.
- If `candidate_activated_at` is missing or null, the state predates this field; use the work item's `last_heartbeat_at` as a fallback, or flag for manual review if neither timestamp exists.
- Compare against `candidate_timeout_minutes` from watchdog defaults.
- If stale: requeue the work item, clear `active_candidate` and `candidate_activated_at`, promote next item from `candidate_queue`.

### 4. Check for Long-Open Gates

Scan `.agent-atelier/human-gates/open/` for HDR files:
- Parse `created_at`
- If older than `gate_warn_after_hours`: add a warning alert

### 5. Check for Repeated Failures

For each work item, check `stale_requeue_count` and `last_finding_fingerprint`:
- Same finding fingerprint 3+ times → flag for orchestrator review (something structural is wrong)
- Same watchdog intervention 2+ times on one WI → flag for orchestrator review
- Environment errors 2+ times → suggest environment escalation, not code retry

### 6. Enforce Operating Budgets

Read `budgets` from `watchdog-jobs.json`. For each non-`done` work item, check:

- **Wall-clock time**: If `first_claimed_at` is set and `(now - first_claimed_at)` exceeds `max_wall_clock_minutes_per_wi` (default 480), create a `budget_exceeded` alert. The watchdog does NOT auto-cancel — it flags for orchestrator review.
- **Handoff count**: If `handoff_count` exceeds `max_handoffs_per_wi` (default 6), flag for review. Excessive handoffs indicate decomposition problems.
- **Watchdog interventions**: If `stale_requeue_count` exceeds `max_watchdog_interventions_per_wi` (default 3), escalate. The WI is repeatedly getting stuck.
- **Attempt count**: If `attempt_count` exceeds `max_attempts_per_wi` (default 5), flag for review. The implementation approach likely needs rethinking.

Budget alerts use the same alert structure as other watchdog alerts, with `type: "budget_exceeded"` and `message` indicating which budget was exceeded and by how much.

### 7. Commit All Changes

Gather all changes from steps 2-6 and commit them in a single state-commit transaction. This may include:
- Updated `work-items.json` (recovered items)
- Updated `loop-state.json` (cleared active_candidate)
- Updated `watchdog-jobs.json` (last_tick_at, open_alerts, revision bump)

All changes go in one transaction with `expected_revision` set for each file. If a revision is stale (another writer changed state between read and commit), the entire tick is rejected — re-read and retry.

### 8. Report

Output a summary:

```
Watchdog tick at 2026-04-08T12:00:00Z

Recovered:
  WI-014: lease expired → requeued to ready (stale_requeue_count: 2)

Alerts:
  HDR-007: open for 36h — consider nudging the user

Manual attention required:
  WI-021: same finding fingerprint 3x — likely a structural issue

No issues found: WI-010, WI-011, WI-013, WI-015, WI-018
```

## Alert Structure

When creating an alert in `open_alerts`:

```json
{
  "id": "WDA-NNN",
  "created_at": "<now>",
  "type": "stale_lease | repeated_failure | long_open_gate | environment_error",
  "work_item_id": "WI-NNN",
  "message": "Human-readable description",
  "action_taken": "requeued | escalated | none"
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — tick completed (with or without recovery actions) |
| `1` | Usage error (invalid arguments) |
| `2` | Stale revision (another writer changed state between read and commit) |
| `3` | State files not found (not initialized) |
| `4` | Runtime or environment failure |

## Input Conventions

The `tick` subcommand takes no payload input. Optional flags:

- `--request-id <id>` — unique request identifier for audit trail (recommended but optional for watchdog since tick is inherently idempotent)

## Output Contract

Returns JSON to stdout:

```json
{
  "request_id": "REQ-WD-001",
  "accepted": true,
  "committed_revision": 4,
  "changed": true,
  "tick_at": "2026-04-08T12:00:00Z",
  "recovered": [
    {"work_item_id": "WI-014", "action": "requeued", "reason": "lease expired", "stale_requeue_count": 2}
  ],
  "alerts_created": [
    {"id": "WDA-003", "type": "long_open_gate", "work_item_id": "WI-012"}
  ],
  "escalations": [
    {"work_item_id": "WI-021", "reason": "same finding fingerprint 3x"}
  ],
  "artifacts": [
    ".agent-atelier/work-items.json",
    ".agent-atelier/watchdog-jobs.json"
  ]
}
```

If no issues found: `"changed": false, "recovered": [], "alerts_created": [], "escalations": []`. When presenting to a human user, additionally render the readable summary format shown above. Diagnostic messages go to stderr.

## Idempotency

Watchdog `tick` is inherently idempotent — running it multiple times with the same state produces the same recovery actions. Already-recovered items will not be in the triggering state on re-run.

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| State files missing | `3` | Suggest running `/agent-atelier:init` |
| WI references non-existent gate | `0` | Log the inconsistency, suggest manual cleanup |
| Watchdog encounters an error | `4` | Report and stop — never make partial writes |
| Stale revision | `2` | Re-read and retry the entire tick |

## Constraints

- All recovery actions are logged. The watchdog never silently changes state.
- The watchdog acts on observed state only — it doesn't remember previous ticks or build up internal state across invocations.
- When in doubt, escalate rather than recover. A stuck item that gets human attention is better than a recovered item that loses work.
