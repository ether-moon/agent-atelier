---
name: candidate
description: "Candidate lifecycle — enqueue a work item as a candidate for validation, activate the next queued candidate into the exclusive validation slot, or clear the active candidate after completion or demotion. Use when a builder finishes implementation, when the orchestrator needs to start validation, or when validation is done. Triggers on 'candidate', 'enqueue candidate', 'activate candidate', 'clear candidate', 'promote to candidate', 'candidate queue', 'next candidate', or 'demote candidate'."
argument-hint: "enqueue <WI-ID> | activate | clear [--reason completed|demoted]"
---

# Candidate — Candidate Pipeline Lifecycle

Candidates are the bridge between implementation and validation. When a builder finishes a work item, the result is enqueued as a candidate. The orchestrator then activates the next candidate into the exclusive validation slot, where exactly one candidate is validated at a time. After validation, the candidate is cleared — either because it passed and is done, or because it failed and needs rework.

## When This Skill Runs

- Builder finishes implementation and has a candidate branch/commit ready (enqueue)
- Orchestrator is ready to start validation on the next queued candidate (activate)
- Validation passes and the work item is complete (clear with completed)
- Validation fails and the work item returns to implementation (clear with demoted)

## Prerequisites

- Orchestration must be initialized
- For `enqueue`: work item must be in `implementing` status
- For `activate`: `active_candidate` must be null and `candidate_queue` must be non-empty
- For `clear`: `active_candidate` must be non-null

## Allowed Tools

- Read (state files), Bash (git root, state-commit), Glob

## Write Protocol

Candidate operations touch multiple files (`loop-state.json` and `work-items.json`). All writes go through a single `state-commit` transaction to prevent partial updates. If the session stops between read and commit, no files change. If it stops after commit, all files are consistent.

```bash
echo '<transaction-json>' | <plugin-root>/scripts/state-commit --root <repo-root>
```

The transaction includes every file that needs to change, with `expected_revision` set for each JSON file's current revision. Every subcommand below follows the same pattern:

1. **Read** both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. **Validate** preconditions and prepare the updated content.
3. **Commit** by piping a transaction to `state-commit`.
4. **Check** the result. If `stale_revision`, re-read and retry.

## Subcommands

### `enqueue <WI-ID>`

Enqueues a work item as a candidate for validation. The builder has finished implementation, committed the result to a candidate branch, and is now handing it off.

1. Read both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. Find the work item. Verify:
   - Status is `implementing`
   - `--branch` and `--commit` are provided
   - The WI does not already appear in `candidate_queue` (check by `work_item_id`)
   - The WI is not the current `active_candidate`
3. Prepare all changes in memory:
   - **work-items.json:**
     - `status` → `candidate_queued`
     - `promotion.candidate_branch` → the provided branch
     - `promotion.candidate_commit` → the provided commit
     - `promotion.status` → `queued`
     - Clear lease fields: `owner_session_id` → null, `last_heartbeat_at` → null, `lease_expires_at` → null
     - Bump item `revision`
   - **loop-state.json:**
     - Append `{"work_item_id": "<WI-ID>", "branch": "<branch>", "commit": "<commit>"}` to `candidate_queue`
     - Bump `revision`, set `updated_at`
4. Commit both files in one transaction:
   ```json
   {"writes": [
     {"path": ".agent-atelier/work-items.json", "expected_revision": 12, "content": {...}},
     {"path": ".agent-atelier/loop-state.json", "expected_revision": 41, "content": {...}}
   ]}
   ```

**Arguments:**
- `<WI-ID>` — required
- `--branch <name>` — required (e.g., `candidate/WI-014`)
- `--commit <sha>` — required (e.g., `abc1234`)

### `activate`

Pops the first candidate from the queue into the exclusive validation slot. Only one candidate can be active at a time.

1. Read both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. Verify:
   - `active_candidate` is null (the slot must be empty)
   - `candidate_queue` is non-empty
3. Pop the first entry from `candidate_queue` (FIFO order).
4. Prepare all changes in memory:
   - **loop-state.json:**
     - `active_candidate` → the popped entry
     - `candidate_activated_at` → now (UTC)
     - Remove the entry from `candidate_queue`
     - Bump `revision`, set `updated_at`
   - **work-items.json:**
     - Find the WI by `work_item_id` from the popped entry
     - `status` → `candidate_validating`
     - `promotion.status` → `validating`
     - Bump item `revision`
5. Commit both files in one transaction.

**Arguments:** None — always activates the first entry in FIFO order.

### `clear [--reason completed|demoted]`

Clears the active candidate after validation completes or after demotion due to failure.

1. Read both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. Verify `active_candidate` is not null.
3. Find the WI referenced by `active_candidate.work_item_id`.
4. Based on `--reason`:

   **`completed`** — The WI has already been marked `done` by `execute complete`. Only the loop-state slot needs clearing.
   - Verify WI status is `done`
   - **loop-state.json:** `active_candidate` → null, `candidate_activated_at` → null. Bump `revision`, set `updated_at`.
   - Commit loop-state only.

   **`demoted`** (default) — Validation failed or was abandoned. The WI returns to the pool for rework.
   - **Idempotency guard:** If the WI is already in `ready` status with `promotion.status` == `demoted` (i.e., `validate record` already handled the demotion), skip the work-items.json write — only clear the loop-state slot. This prevents a double-write when validate and candidate clear operate on the same failed validation.
   - **If WI still needs demotion** (status is not `ready` or promotion not yet cleared):
     - **work-items.json:**
       - `status` → `ready` (or value of `--demote-to` if provided)
       - `promotion.candidate_branch` → null
       - `promotion.candidate_commit` → null
       - `promotion.status` → `demoted`
       - Bump item `revision`
     - **loop-state.json:** `active_candidate` → null, `candidate_activated_at` → null. Bump `revision`, set `updated_at`.
     - Commit both files in one transaction.
   - **If WI already demoted:**
     - **loop-state.json:** `active_candidate` → null, `candidate_activated_at` → null. Bump `revision`, set `updated_at`.
     - Commit loop-state only.

**Arguments:**
- `--reason <completed|demoted>` — optional, defaults to `demoted`
- `--demote-to <ready|implementing>` — optional, defaults to `ready` (only applies when reason is `demoted`)

## Timestamps

All timestamps are UTC ISO-8601 with `Z` suffix: `2026-04-08T12:00:00Z`

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage or validation error (missing required fields) |
| `2` | Precondition failed (wrong status, slot occupied, queue empty) or stale revision |
| `3` | Work item not found |
| `4` | Runtime or environment failure |

## Input Conventions

The `enqueue` subcommand accepts payload via:
- `--json '<inline-json>'` — inline JSON string
- `--input <path>` — path to a JSON file

Required flags for all mutating operations:
- `--request-id <id>` — unique request identifier for idempotency tracking
- `--based-on-revision <N>` — the store revision observed at read time (applies to both `loop-state.json` and `work-items.json`)

## Output Contract

All subcommands return JSON to stdout:

```json
{
  "request_id": "REQ-201",
  "accepted": true,
  "committed_revision": 43,
  "changed": true,
  "artifacts": [
    ".agent-atelier/loop-state.json",
    ".agent-atelier/work-items.json"
  ]
}
```

The `clear --reason completed` and `clear --reason demoted` (when WI already demoted by validate) variants may include only `loop-state.json` in artifacts. Diagnostic messages go to stderr.

## Idempotency

- Same `request_id` + same payload → return previous result with `"changed": false, "replayed": true`
- Same `request_id` + different payload → reject with exit code `1`
- Stale `based_on_revision` → reject with exit code `2`

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| WI not found | `3` | Report missing WI, list available IDs |
| WI not in expected status for enqueue | `2` | Report current status, explain expected status (`implementing`) |
| active_candidate already occupied (activate) | `2` | Report who holds the slot and since when, suggest clearing first |
| candidate_queue empty (activate) | `2` | Report empty queue, suggest enqueue first |
| active_candidate is null (clear) | `2` | Report nothing to clear |
| WI already in candidate_queue (enqueue) | `2` | Report duplicate, show queue position |
| WI is already active_candidate (enqueue) | `2` | Report the WI is already under validation |
| WI not done (clear with completed) | `2` | Report current status, suggest using `demoted` instead |
| Stale revision | `2` | Report current vs expected, ask caller to re-read |

## Constraints

- The `active_candidate` slot is exclusive — only one candidate at a time. This is an invariant from the state schema.
- Enqueue clears lease fields because the builder's implementation phase is over. Stale lease data on a non-implementing item creates confusion about ownership.
- FIFO ordering of `candidate_queue` is preserved. No priority reordering.
- Read `references/wi-schema.md` for normalization rules that apply to all work item writes.
