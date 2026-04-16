# Execute Subcommands — Detailed Procedures

Detailed step-by-step procedures for each execute subcommand. The parent SKILL.md has summaries and examples.

## Table of Contents

- [claim](#claim-wi-id)
- [heartbeat](#heartbeat-wi-id)
- [requeue](#requeue-wi-id)
- [complete](#complete-wi-id)
- [attempt](#attempt-json)
- [Native Task Lookup](#native-task-lookup)

---

## `claim <WI-ID>`

Claims a work item for implementation, establishing a lease.

**Caller authorization:** This subcommand is Orchestrator-authorized and State-Manager-executed. The Orchestrator decides which Builder should receive a WI, then directs the State Manager to run `claim` with that Builder's session ID. Builders must NOT call `claim` directly. They message the Orchestrator when available, and the Orchestrator routes the assignment. Self-served claims bypass the coordination path and create phantom state. The TeammateIdle hook therefore lets Builders go idle and wait for Orchestrator dispatch instead of calling this subcommand.

**Procedure:**

1. Read `.agent-atelier/work-items.json`.
2. Find the work item. Verify:
   - Status is `ready`
   - No active lease exists (or existing lease has expired)
3. Update the item:
   - `status` → `implementing`
   - `owner_session_id` → the provided session ID (or generate one like `exec-<WI-ID>-<attempt+1>`)
   - `last_heartbeat_at` → now (UTC)
   - `lease_expires_at` → now + lease duration (default 90 minutes)
   - `first_claimed_at` → now (UTC), but only if currently null (preserve the original claim time)
   - `handoff_count` → increment by 1 (tracks how many times this WI has been claimed)
   - `revision` → increment by 1
4. Bump store revision and commit via state-commit with `expected_revision` set to the store revision observed in step 1.
5. **Sync native task.** Look up the native task for this WI (see [Native Task Lookup](#native-task-lookup)). If found, call `TaskUpdate` with `status: "in_progress"`.

**Arguments:**
- `<WI-ID>` — required
- `--owner-session-id <id>` — required (executor's session identity)
- `--lease-minutes <N>` — optional, default 90

---

## `heartbeat <WI-ID>`

Extends the lease on a work item the executor is actively working on. Heartbeats prove the executor is alive. Without them, the watchdog will eventually reclaim the item.

**This subcommand uses verb mode** — it calls state-commit directly without SM roundtrip, bypassing the control-plane path for this data-plane-only operation.

**Procedure:**

1. Read `.agent-atelier/work-items.json`. Note the current store revision.
2. Verify the WI exists and is in `implementing` status with a matching `owner_session_id`.
3. Pipe a verb to state-commit:
   ```bash
   echo '{"verb":"heartbeat","target":"<WI-ID>","based_on_revision":<current-revision>,"fields":{"last_heartbeat_at":"<now>","lease_expires_at":"<now+lease>"}}' | <plugin-root>/scripts/state-commit --root <repo-root>
   ```
4. Check the result. If `stale_revision`, re-read the store and retry with the new revision.

---

## `requeue <WI-ID>`

Returns a work item to the queue when the executor cannot continue. This might happen because the executor hit a dead end, needs different information, or the session is ending.

**Procedure:**

1. Read the store.
2. Find the work item. Verify:
   - Status is any non-terminal status including `reviewing` (completed items with status `done` cannot be requeued)
   - If `--owner-session-id` is provided, it matches the current owner (or owner is null)
3. Update:
   - `status` → `ready` (default) or `pending` if specified
   - Clear lease fields: `owner_session_id` → null, `last_heartbeat_at` → null, `lease_expires_at` → null
   - If requeuing from `reviewing`: additionally clear promotion metadata (`promotion.candidate_branch` → null, `promotion.candidate_commit` → null, `promotion.status` → `not_ready`)
   - If `--increment-stale-requeue`: increment `stale_requeue_count`
   - If `--reason`: set `last_requeue_reason`
   - `revision` → increment by 1
4. Bump store revision and write.
5. **Sync native task.** Look up the native task for this WI (see [Native Task Lookup](#native-task-lookup)). If found, call `TaskUpdate` with `status: "pending"`.

**Common Use Cases:**
- **Implementation requeue** — Builder hit a dead end during `implementing`. Standard requeue to `ready`.
- **AUTOFIX requeue** — Review found bugs, WI is in `reviewing`. The Orchestrator requeues with `--reason autofix` so a Builder can claim it for the fix cycle. Promotion metadata is cleared because the current candidate is invalid.

---

## `complete <WI-ID>`

Marks a work item as done. This is a high-bar operation — it requires evidence that the work actually passed validation. When the last WI in the active candidate set completes, the set is atomically cleared in the same transaction.

**Procedure:**

1. Read both `.agent-atelier/work-items.json` and `.agent-atelier/loop-state.json`. Note both revisions.
2. Find the work item. Verify status is `reviewing`.
3. **Verify evidence:**
   - Read the validation manifest file at the provided path
   - `active_candidate_set` is not null and includes `<WI-ID>`
   - Manifest `status` must be `passed`
   - Manifest `candidate_set_id` must match `active_candidate_set.id`
   - Manifest `candidate_branch` / `candidate_commit` must match `active_candidate_set.branch` / `active_candidate_set.commit`
   - Manifest `work_item_ids` must contain `<WI-ID>`
   - All `--evidence-ref` paths must exist on disk
   - At least one `--verify-check` must be provided
4. Build the completion record:
   ```json
   {
     "completed_at": "<now>",
     "validation_run_id": "<from manifest>",
     "validation_manifest": "<relative path>",
     "evidence_refs": ["<relative paths>"],
     "verify_checks": ["<check names>"]
   }
   ```
5. Update work-items.json:
   - `status` → `done`
   - Clear lease fields
   - `completion` → the completion record above
   - `revision` → increment by 1
6. **Auto-clear candidate set:** Check if `active_candidate_set` contains this WI. If so, check all other WIs in `active_candidate_set.work_item_ids`:
   - If **all** WIs (including this one after update) are now `done` → include `active_candidate_set → null` in the same transaction (commit both loop-state.json and work-items.json).
   - If some WIs are not yet done → commit work-items.json only (set stays active for remaining WIs).
7. Bump store revision(s) and commit.
8. **Sync native task.** Look up the native task for this WI (see [Native Task Lookup](#native-task-lookup)). If found, call `TaskUpdate` with `status: "completed"`.

**Arguments:**
- `--validation-manifest <path>` — required
- `--evidence-ref <path>` — required, can repeat
- `--verify-check <name>` — required, can repeat

---

## `attempt <json>`

Records an implementation attempt — useful for tracking what was tried, what failed, and why. The attempt is stored as a separate file, and the work item is updated to reference it.

**Procedure:**

1. Parse the attempt payload. Required field: `work_item_id`.
2. Read the store. Find the work item.
3. Calculate the next attempt number: `attempt_count + 1`.
4. Set defaults:
   - `id` → `ATT-<WI-ID>-<NN>`
   - `attempt` → the calculated number
5. Update the work item:
   - `attempt_count` → new count
   - `last_attempt_ref` → relative path to the attempt file
   - `last_finding_fingerprint` → from payload if provided
   - `revision` → increment by 1
6. Bump store revision.
7. Commit both the attempt file AND the updated work-items.json in a single state-commit transaction. This ensures the attempt record and the work item reference are always consistent.

---

## Native Task Lookup

All native task sync operations use the same lookup pattern:

1. Call `TaskList` to get all tasks.
2. Collect all tasks whose subject starts with `"WI-NNN:"` (matching the target WI's ID prefix).
3. Apply the deduplication rule:
   - **0 matches:** Log a warning to stderr and skip sync.
   - **1 match:** Use it as the canonical native task.
   - **2+ matches:** Log a warning to stderr listing duplicates. Use the task with the highest ID (newest) as canonical.

**Native task sync is best-effort.** Failures do not affect the WI state-commit outcome. `work-items.json` is the authoritative source of truth; native tasks are a visibility and dependency-resolution layer.
