# Candidate Subcommands — Detailed Procedures

## Table of Contents

- [enqueue](#enqueue)
- [activate](#activate)
- [clear](#clear)

## enqueue

Enqueues one or more work items as a candidate set for validation. For batch enqueue, provide comma-separated WI IDs. All WIs in the set share the same branch and commit.

**Arguments:**
- `<WI-ID>[,WI-ID,...]` — required (single ID or comma-separated for batch)
- `--branch <name>` — required (e.g., `candidate/WI-014` or `feat/phase-2`)
- `--commit <sha>` — required (e.g., `abc1234`)

**Steps:**

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

## activate

Pops the first candidate set from the queue into the exclusive validation slot. Only one set can be active at a time.

**Arguments:** None — always activates the first entry in FIFO order.

**Steps:**

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

## clear

Clears the active candidate set after validation completes or after demotion due to failure.

**Arguments:**
- `--reason <completed|demoted>` — optional, defaults to `demoted`

### clear --reason completed

All WIs have been marked `done` by `execute complete`. Only the loop-state slot needs clearing.

1. Read both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. Verify `active_candidate_set` is not null.
3. Find all WIs referenced by `active_candidate_set.work_item_ids`.
4. Verify **all** WI statuses are `done`. If any WI is not `done`, reject.
5. **loop-state.json:** `active_candidate_set` → null. Bump `revision`, set `updated_at`.
6. Commit loop-state only.

### clear --reason demoted

Validation failed. **All WIs in the set return to rework** (fate-sharing: all-or-nothing).

1. Read both `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Note both revisions.
2. Verify `active_candidate_set` is not null.
3. Find all WIs referenced by `active_candidate_set.work_item_ids`.
4. **Idempotency guard:** If all WIs are already in `ready` status with promotion metadata fully cleared (`candidate_branch` / `candidate_commit` null and `promotion.status == "not_ready"`), skip the work-items.json write — only clear the loop-state slot (go to step 7).
5. **If any WI still needs demotion** (status is not `ready` or promotion not yet cleared):
   - **work-items.json** (for each WI in the set):
     - `status` → `ready`
     - `promotion.candidate_branch` → null
     - `promotion.candidate_commit` → null
     - `promotion.status` → `not_ready`
     - Bump item `revision`
   - **loop-state.json:** `active_candidate_set` → null. Bump `revision`, set `updated_at`.
   - Commit both files in one transaction.
   - **Sync native tasks.** For each WI, look up the native task (search `TaskList` for subject starting with the WI's ID prefix). If found, call `TaskUpdate` with `status: "pending"`.
6. **If all WIs are already reset to `ready` with cleared promotion metadata:**
7. **loop-state.json:** `active_candidate_set` → null. Bump `revision`, set `updated_at`.
8. Commit loop-state only.
