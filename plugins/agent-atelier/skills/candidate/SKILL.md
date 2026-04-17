---
name: candidate
description: "Candidate pipeline lifecycle — enqueue work items as a candidate set for validation, activate the next queued set into the exclusive validation slot, or clear the active set after completion or demotion. Supports single and batch candidates with fate-sharing semantics. Use when a builder finishes implementation, when the orchestrator needs to start validation, or when validation passes or fails. Triggers on 'candidate', 'enqueue candidate', 'activate candidate', 'clear candidate', 'promote to candidate', 'candidate queue', 'next candidate', 'demote candidate', 'candidate ready', 'submit for validation', or 'validation slot'."
argument-hint: "enqueue <WI-ID>[,WI-ID,...] --branch <name> --commit <sha> | activate | clear [--reason completed|demoted]"
---

# Candidate — Candidate Pipeline Lifecycle

Candidates bridge implementation and validation. When a builder finishes work items, they are enqueued as a **candidate set** — one or more WIs sharing a branch and commit. The orchestrator activates the next set into the exclusive validation slot (one at a time). After validation, the set is cleared as completed or demoted (fate-sharing: all WIs succeed or all return to rework).

## Candidate Set Schema

```json
{
  "id": "CS-001",
  "work_item_ids": ["WI-018", "WI-019"],
  "branch": "feat/phase-2",
  "commit": "abc1234",
  "type": "batch",
  "activated_at": null
}
```

- `id`: `CS-NNN`, auto-generated on enqueue
- `work_item_ids`: always an array, even for single WIs
- `type`: `"single"` (1 WI) or `"batch"` (2+ WIs)
- `activated_at`: set on activation; null while queued

Loop-state stores `active_candidate_set` (one set or null) and `candidate_queue` (FIFO array).

## When This Skill Runs

- Builder finishes implementation and has a candidate branch/commit ready (enqueue)
- Orchestrator is ready to start validation on the next queued set (activate)
- All WIs in the set pass validation and are complete (clear --reason completed)
- Validation fails and all WIs return to rework (clear --reason demoted)

## Prerequisites

- Orchestration must be initialized
- `enqueue`: all specified WIs must be in `implementing` status
- `activate`: `active_candidate_set` must be null; `candidate_queue` must be non-empty
- `clear`: `active_candidate_set` must be non-null

## Allowed Tools

- Read (state files), Bash (git root, state-commit), Glob, TaskList, TaskUpdate

## Write Protocol

All writes go through a single `state-commit` transaction. Every subcommand follows:

1. **Read** both `loop-state.json` and `work-items.json`. Note both revisions.
2. **Validate** preconditions and prepare updated content.
3. **Commit** by piping a transaction to `state-commit`.
4. **Check** the result. If `stale_revision`, re-read and retry.

```bash
echo '<transaction-json>' | <plugin-root>/scripts/state-commit --root <repo-root>
```

## Subcommands

For detailed step-by-step procedures, see `reference/subcommands.md`.

### `enqueue <WI-ID>[,WI-ID,...] --branch <name> --commit <sha>`

Enqueues WIs as a candidate set. Transitions each WI from `implementing` to `candidate_queued`, sets promotion metadata, clears lease fields, and appends the set to `candidate_queue`.

### `activate`

Pops the first set from `candidate_queue` into `active_candidate_set` (FIFO). Transitions each WI from `candidate_queued` to `candidate_validating`. No arguments.

### `clear [--reason completed|demoted]`

Clears the active set. `--reason completed` verifies all WIs are `done` and clears the slot. `--reason demoted` (default) resets all WIs to `ready`, clears promotion metadata, and syncs native tasks back to `pending`.

## Examples

**Enqueue a single WI after implementation:**
```bash
/candidate enqueue WI-014 --branch candidate/WI-014 --commit abc1234
```

**Enqueue a batch of WIs from the same branch:**
```bash
/candidate enqueue WI-018,WI-019,WI-020 --branch feat/phase-2 --commit def5678
```

**Activate the next queued set for validation:**
```bash
/candidate activate
```

**Clear after all WIs pass validation:**
```bash
/candidate clear --reason completed
```

**Clear after validation failure (demote all WIs):**
```bash
/candidate clear --reason demoted
```

## Timestamps

All timestamps are UTC ISO-8601 with `Z` suffix: `2026-04-08T12:00:00Z`

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage or validation error (missing required fields) |
| `2` | Precondition failed (wrong status, slot occupied, queue empty, stale revision) |
| `3` | Work item not found |
| `4` | Runtime or environment failure |

## Input Conventions

- `--json '<inline-json>'` or `--input <path>` for payload
- `--request-id <id>` required on all mutating operations (idempotency tracking)
- Track the current revision of every file you mutate; use matching `expected_revision` per artifact in the transaction (do not reuse a single value for both files)

## Output Contract

All subcommands return JSON to stdout:

```json
{
  "request_id": "REQ-201",
  "accepted": true,
  "committed_revision": 43,
  "changed": true,
  "candidate_set_id": "CS-003",
  "artifacts": [
    ".agent-atelier/loop-state.json",
    ".agent-atelier/work-items.json"
  ]
}
```

`clear --reason completed` and idempotent `clear --reason demoted` may include only `loop-state.json` in artifacts. Diagnostics go to stderr.

## Idempotency

- Same `request_id` + same payload → return previous result with `"changed": false, "replayed": true`
- Same `request_id` + different payload → reject with exit code `1`
- Stale revision → reject with exit code `2`

## Error Handling

| Condition | Exit | Action |
|-----------|------|--------|
| WI not found | `3` | Report missing IDs, list available |
| WI not `implementing` (enqueue) | `2` | Report which WIs have wrong status |
| Slot already occupied (activate) | `2` | Report active set ID and activated_at, suggest clearing first |
| Queue empty (activate) | `2` | Report empty queue, suggest enqueue first |
| Slot is null (clear) | `2` | Report nothing to clear |
| WI already in queue (enqueue) | `2` | Report duplicate and which set contains it |
| WI in active set (enqueue) | `2` | Report WI is under validation |
| Not all WIs `done` (clear completed) | `2` | Report which WIs are not done, suggest `demoted` |
| Stale revision | `2` | Report current vs expected, ask caller to re-read |

## Constraints

- **Exclusive slot:** Only one candidate set can be active at a time (invariant).
- **Fate-sharing:** All WIs in a batch are a unit. Partial demotion is not supported.
- **Lease clearing:** Enqueue clears lease fields because the builder's phase is over.
- **FIFO ordering:** `candidate_queue` is strictly FIFO. No priority reordering.
- See `references/wi-schema.md` for normalization rules on all work item writes.
