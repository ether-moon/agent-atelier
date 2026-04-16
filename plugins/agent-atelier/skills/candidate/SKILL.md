---
name: candidate
description: "Candidate lifecycle — enqueue work items as a candidate set for validation, activate the next queued set into the exclusive validation slot, or clear the active set after completion or demotion. Supports single and batch candidates. Use when a builder finishes implementation, when the orchestrator needs to start validation, or when validation is done. Triggers on 'candidate', 'enqueue candidate', 'activate candidate', 'clear candidate', 'promote to candidate', 'candidate queue', 'next candidate', or 'demote candidate'."
argument-hint: "enqueue <WI-ID>[,WI-ID,...] | activate | clear [--reason completed|demoted]"
---

# Candidate — Candidate Pipeline Lifecycle

Candidates are the bridge between implementation and validation. When a builder finishes work items, the results are enqueued as a **candidate set** — a group of one or more WIs sharing a branch and commit. The orchestrator then activates the next set into the exclusive validation slot, where exactly one set is validated at a time. After validation, the set is cleared — either because all WIs passed and are done, or because validation failed and all WIs return to rework (fate-sharing).

## Candidate Set Schema

A candidate set is a first-class object:

```json
{
  "id": "CS-001",
  "work_item_ids": ["WI-018", "WI-019", "WI-020", "WI-021"],
  "branch": "feat/phase-2",
  "commit": "abc1234",
  "type": "batch",
  "activated_at": "2026-04-08T14:10:00Z"
}
```

- `id`: `CS-NNN` format, auto-generated on enqueue (next available number in queue + active set)
- `work_item_ids`: always an array, even for single WIs (`["WI-014"]`)
- `type`: `"single"` (1 WI) or `"batch"` (2+ WIs)
- `activated_at`: set when the set moves from queue to active slot; null while queued

Loop-state stores:
- `active_candidate_set`: the set currently under validation (null when empty)
- `candidate_queue`: array of candidate sets awaiting activation (FIFO)

## When This Skill Runs

- Builder finishes implementation and has a candidate branch/commit ready (enqueue)
- Orchestrator is ready to start validation on the next queued candidate set (activate)
- All WIs in the set pass validation and are complete (clear with completed)
- Validation fails — all WIs in the set return to rework (clear with demoted)

## Prerequisites

- Orchestration must be initialized
- For `enqueue`: all specified work items must be in `implementing` status
- For `activate`: `active_candidate_set` must be null and `candidate_queue` must be non-empty
- For `clear`: `active_candidate_set` must be non-null

## Allowed Tools

- Read (state files), Bash (git root, state-commit), Glob, TaskList, TaskUpdate

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

### `enqueue <WI-ID>[,WI-ID,...]`

Enqueues one or more work items as a candidate set for validation. For batch enqueue, provide comma-separated WI IDs. All WIs in the set share the same branch and commit.

1. Read both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. Parse the WI IDs (split by comma if batch). Find each work item. Verify:
   - **All** WIs have status `implementing`. If any WI is not `implementing`, reject the entire enqueue.
   - `--branch` and `--commit` are provided
   - None of the WIs appear in any existing `candidate_queue` entry (check by `work_item_ids`)
   - None of the WIs are in the current `active_candidate_set`
3. Generate the next `CS-NNN` ID by scanning existing IDs in `active_candidate_set` and `candidate_queue`.
4. Prepare all changes in memory:
   - **work-items.json** (for each WI in the set):
     - `status` → `candidate_queued`
     - `promotion.candidate_branch` → the provided branch
     - `promotion.candidate_commit` → the provided commit
     - `promotion.status` → `queued`
     - Clear lease fields: `owner_session_id` → null, `last_heartbeat_at` → null, `lease_expires_at` → null
     - Bump item `revision`
   - **loop-state.json:**
     - Append candidate set to `candidate_queue`:
       ```json
       {
         "id": "CS-003",
         "work_item_ids": ["WI-018", "WI-019"],
         "branch": "feat/phase-2",
         "commit": "abc1234",
         "type": "batch",
         "activated_at": null
       }
       ```
     - Bump `revision`, set `updated_at`
5. Commit both files in one transaction.

**Arguments:**
- `<WI-ID>[,WI-ID,...]` — required (single ID or comma-separated for batch)
- `--branch <name>` — required (e.g., `candidate/WI-014` or `feat/phase-2`)
- `--commit <sha>` — required (e.g., `abc1234`)

### `activate`

Pops the first candidate set from the queue into the exclusive validation slot. Only one set can be active at a time.

1. Read both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. Verify:
   - `active_candidate_set` is null (the slot must be empty)
   - `candidate_queue` is non-empty
3. Pop the first entry from `candidate_queue` (FIFO order).
4. Prepare all changes in memory:
   - **loop-state.json:**
     - `active_candidate_set` → the popped entry with `activated_at` set to now (UTC)
     - Remove the entry from `candidate_queue`
     - Bump `revision`, set `updated_at`
   - **work-items.json** (for each WI in the set's `work_item_ids`):
     - `status` → `candidate_validating`
     - `promotion.status` → `validating`
     - Bump item `revision`
5. Commit both files in one transaction.

**Arguments:** None — always activates the first entry in FIFO order.

### `clear [--reason completed|demoted]`

Clears the active candidate set after validation completes or after demotion due to failure.

1. Read both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. Verify `active_candidate_set` is not null.
3. Find all WIs referenced by `active_candidate_set.work_item_ids`.
4. Based on `--reason`:

   **`completed`** — All WIs have been marked `done` by `execute complete`. Only the loop-state slot needs clearing.
   - Verify **all** WI statuses are `done`. If any WI is not `done`, reject.
   - **loop-state.json:** `active_candidate_set` → null. Bump `revision`, set `updated_at`.
   - Commit loop-state only.

   **`demoted`** (default) — Validation failed. **All WIs in the set return to rework** (fate-sharing: all-or-nothing).
   - **Idempotency guard:** If all WIs are already in `ready` status with promotion metadata fully cleared (`candidate_branch` / `candidate_commit` null and `promotion.status == "not_ready"`), skip the work-items.json write — only clear the loop-state slot.
   - **If any WI still needs demotion** (status is not `ready` or promotion not yet cleared):
     - **work-items.json** (for each WI in the set):
       - `status` → `ready`
       - `promotion.candidate_branch` → null
       - `promotion.candidate_commit` → null
       - `promotion.status` → `not_ready`
       - Bump item `revision`
     - **loop-state.json:** `active_candidate_set` → null. Bump `revision`, set `updated_at`.
     - Commit both files in one transaction.
     - **Sync native tasks.** For each WI, look up the native task (search `TaskList` for subject starting with the WI's ID prefix). If found, call `TaskUpdate` with `status: "pending"`.
   - **If all WIs are already reset to `ready` with cleared promotion metadata:**
     - **loop-state.json:** `active_candidate_set` → null. Bump `revision`, set `updated_at`.
     - Commit loop-state only.

**Arguments:**
- `--reason <completed|demoted>` — optional, defaults to `demoted`

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

Revision handling:
- Candidate lifecycle commands are multi-file writes
- Track the current revision of every file you mutate and use the matching `expected_revision` for each JSON artifact in the `state-commit` transaction
- Do not reuse a single shared revision value for both `loop-state.json` and `work-items.json` unless they actually match on disk

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

The `clear --reason completed` and `clear --reason demoted` (when WIs already demoted by validate) variants may include only `loop-state.json` in artifacts. Diagnostic messages go to stderr.

## Idempotency

- Same `request_id` + same payload → return previous result with `"changed": false, "replayed": true`
- Same `request_id` + different payload → reject with exit code `1`
- Stale `based_on_revision` → reject with exit code `2`

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| Any WI not found | `3` | Report missing WI IDs, list available IDs |
| Any WI not in `implementing` for enqueue | `2` | Report which WIs have wrong status, explain expected status |
| `active_candidate_set` already occupied (activate) | `2` | Report set ID and since when, suggest clearing first |
| `candidate_queue` empty (activate) | `2` | Report empty queue, suggest enqueue first |
| `active_candidate_set` is null (clear) | `2` | Report nothing to clear |
| Any WI already in `candidate_queue` (enqueue) | `2` | Report duplicate, show which set contains it |
| Any WI is in `active_candidate_set` (enqueue) | `2` | Report the WI is already under validation |
| Not all WIs `done` (clear with completed) | `2` | Report which WIs are not done, suggest using `demoted` |
| Stale revision | `2` | Report current vs expected, ask caller to re-read |

## Constraints

- The `active_candidate_set` slot is exclusive — only one candidate set at a time. This is an invariant from the state schema.
- **Fate-sharing:** All WIs in a batch set are treated as a unit. If validation fails, all WIs are demoted. Partial demotion is not supported.
- Enqueue clears lease fields because the builder's implementation phase is over. Stale lease data on a non-implementing item creates confusion about ownership.
- FIFO ordering of `candidate_queue` is preserved. No priority reordering.
- Read `references/wi-schema.md` for normalization rules that apply to all work item writes.
