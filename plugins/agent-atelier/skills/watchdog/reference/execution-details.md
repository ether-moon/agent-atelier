# Watchdog Execution Details

Reference for the watchdog tick execution steps. See `../SKILL.md` for the core workflow.

## Table of Contents

- [WAL Recovery](#wal-recovery)
- [Stale Lease Recovery](#stale-lease-recovery)
- [Stale Review Recovery](#stale-review-recovery)
- [Stale Candidate Recovery](#stale-candidate-recovery)
- [Long-Open Gate Warnings](#long-open-gate-warnings)
- [Repeated Failure Detection](#repeated-failure-detection)
- [Operating Budget Enforcement](#operating-budget-enforcement)
- [Alert Structure](#alert-structure)
- [Output Contract](#output-contract)
- [Report Format](#report-format)

## WAL Recovery

Before any checks, look for `.agent-atelier/.pending-tx.json`. This write-ahead log is left behind when a previous state-commit was interrupted mid-write.

If found:
1. Read the pending transaction.
2. Replay it:
   ```bash
   cat .agent-atelier/.pending-tx.json | <plugin-root>/scripts/state-commit --root <repo-root> --replay
   ```
   The `--replay` flag skips files whose revision already matches the target (already written) and applies only the remaining files. This avoids the stale-revision false rejection that would occur with a normal commit.
3. Report which files were replayed vs skipped.

If not found, proceed normally.

## Stale Lease Recovery

For each work item with status `implementing`:
1. Parse `lease_expires_at`.
2. If the lease has expired (current time > lease_expires_at):
   - Set `status` -> `ready`
   - Clear `owner_session_id`, `last_heartbeat_at`, `lease_expires_at`
   - Increment `stale_requeue_count`
   - Set `last_requeue_reason` -> `"watchdog: lease expired"`
   - Bump the item's `revision`
   - Record the recovery action

If the lease is still valid, leave it alone. Owner-session reachability is the Orchestrator's responsibility during the post-tick recovery sweep.

## Stale Review Recovery

For each work item with status `reviewing`:
1. Parse `last_heartbeat_at` or the timestamp when status changed to `reviewing`.
2. If elapsed time exceeds `review_timeout_minutes` (default 30):
   - Set `status` -> `ready`
   - Set `last_requeue_reason` -> `"watchdog: review timeout"`
   - Increment `stale_requeue_count`
   - Record the recovery action

## Stale Candidate Recovery

If `active_candidate_set` exists in loop state:
- Read `active_candidate_set.activated_at` (records when the set entered the active slot).
- If `activated_at` is missing or null, fall back to the most recent `last_heartbeat_at` among referenced WIs, or flag for manual review if no timestamp exists.
- Compare against `candidate_timeout_minutes` (default 30).
- If stale:
  - For every WI in `active_candidate_set.work_item_ids`, set `status` -> `ready`
  - Clear promotion metadata (`candidate_branch`, `candidate_commit`, `promotion.status` -> `not_ready`)
  - Clear `active_candidate_set`
  - Promote the next candidate set from `candidate_queue` only if the queue is non-empty and the watchdog can do so mechanically without changing FIFO order

## Long-Open Gate Warnings

Scan `.agent-atelier/human-gates/open/` for HDR files:
- Parse `created_at`
- If older than `gate_warn_after_hours` (default 24): add a warning alert

## Repeated Failure Detection

For each work item, check `stale_requeue_count` and `last_finding_fingerprint`:
- Same finding fingerprint 3+ times -> flag for orchestrator review (something structural is wrong)
- Same watchdog intervention 2+ times on one WI -> flag for orchestrator review
- Environment errors 2+ times -> suggest environment escalation, not code retry

## Operating Budget Enforcement

Read `budgets` from `watchdog-jobs.json`. For each non-`done` work item, check:

- **Wall-clock time**: If `first_claimed_at` is set and `(now - first_claimed_at)` exceeds `max_wall_clock_minutes_per_wi` (default 480), create a `budget_exceeded` alert.
- **Handoff count**: If `handoff_count` exceeds `max_handoffs_per_wi` (default 6), flag for review. Excessive handoffs indicate decomposition problems.
- **Watchdog interventions**: If `stale_requeue_count` exceeds `max_watchdog_interventions_per_wi` (default 3), escalate. The WI is repeatedly getting stuck.
- **Attempt count**: If `attempt_count` exceeds `max_attempts_per_wi` (default 5), flag for review.

The watchdog does NOT auto-cancel on budget violations -- it flags for orchestrator review. Budget alerts use `type: "budget_exceeded"` with a message indicating which budget was exceeded and by how much.

## Alert Structure

When creating an alert in `open_alerts`:

```json
{
  "id": "WDA-NNN",
  "created_at": "<now>",
  "type": "stale_lease | repeated_failure | long_open_gate | environment_error | budget_exceeded",
  "work_item_id": "WI-NNN",
  "message": "Human-readable description",
  "action_taken": "requeued | escalated | none"
}
```

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

If no issues found: `"changed": false, "recovered": [], "alerts_created": [], "escalations": []`.

Diagnostic messages go to stderr.

## Report Format

When presenting to a human user, render a readable summary:

```
Watchdog tick at 2026-04-08T12:00:00Z

Recovered:
  WI-014: lease expired -> requeued to ready (stale_requeue_count: 2)

Alerts:
  HDR-007: open for 36h -- consider nudging the user

Manual attention required:
  WI-021: same finding fingerprint 3x -- likely a structural issue

No issues found: WI-010, WI-011, WI-013, WI-015, WI-018
```
