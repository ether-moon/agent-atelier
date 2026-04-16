---
name: execute
description: "Work item execution lifecycle — claim a work item to start implementation, send heartbeats to keep the lease alive, requeue if stuck, mark complete with evidence, or record an attempt. Use when an executor needs to start work, renew a lease, return work to the queue, record a failed attempt, or finalize a work item. Triggers on 'claim', 'heartbeat', 'requeue', 'complete', 'record attempt', 'I'm done with WI-NNN', 'start working on', or 'mark as done'."
argument-hint: "claim <id> | heartbeat <id> | requeue <id> | complete <id> | attempt <json>"
---

# Execute — Work Item Execution Lifecycle

## When This Skill Runs

- An executor claims a work item to begin implementation
- An executor extends its lease (heartbeat)
- An executor cannot continue and needs to requeue
- A work item passes validation and is ready to mark done
- Recording a failed attempt with findings

## Prerequisites

- Orchestration must be initialized
- For `claim`: work item must be in `ready` status
- For `heartbeat`: work item must be `implementing` with a valid lease
- For `complete`: work item must be in `reviewing` status and still belong to the current `active_candidate_set`

## Allowed Tools

- Read (state files, evidence), Bash (git root, state-commit), Glob, TaskList, TaskUpdate

## Write Protocol

All mutations go through the `state-commit` script — the sole writer for `.agent-atelier/**`. Every subcommand below follows the same pattern:

1. **Read** the current store and note its `revision`.
2. **Validate** preconditions and prepare the updated content.
3. **Commit** by piping a transaction to `state-commit`:
   ```bash
   echo '<transaction-json>' | <plugin-root>/scripts/state-commit --root <repo-root>
   ```
4. **Check** the result. If `stale_revision`, re-read and retry.

Revision checking is always enforced — every transaction includes `expected_revision` set to the store's current revision at read time. The `attempt` subcommand writes both an attempt file and work-items.json in a single transaction to maintain consistency.

## Subcommands

### `claim <WI-ID>`

Claims a work item for implementation, establishing a lease.

**Caller authorization:** This subcommand is Orchestrator-authorized and State-Manager-executed. The Orchestrator decides which Builder should receive a WI, then directs the State Manager to run `claim` with that Builder's session ID. Builders must NOT call `claim` directly. They message the Orchestrator when available, and the Orchestrator routes the assignment. Self-served claims bypass the coordination path and create phantom state. The TeammateIdle hook therefore lets Builders go idle and wait for Orchestrator dispatch instead of calling this subcommand.

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
5. **Sync native task.** Look up the native task for this WI (see Native Task Lookup below). If found, call `TaskUpdate` with `status: "in_progress"`.

**Arguments:**
- `<WI-ID>` — required
- `--owner-session-id <id>` — required (executor's session identity)
- `--lease-minutes <N>` — optional, default 90

### `heartbeat <WI-ID>`

Extends the lease on a work item the executor is actively working on. Heartbeats prove the executor is alive. Without them, the watchdog will eventually reclaim the item.

**This subcommand uses verb mode** — it calls state-commit directly without SM roundtrip, bypassing the control-plane path for this data-plane-only operation.

1. Read `.agent-atelier/work-items.json`. Note the current store revision.
2. Verify the WI exists and is in `implementing` status with a matching `owner_session_id`.
3. Pipe a verb to state-commit:
   ```bash
   echo '{"verb":"heartbeat","target":"<WI-ID>","based_on_revision":<current-revision>,"fields":{"last_heartbeat_at":"<now>","lease_expires_at":"<now+lease>"}}' | <plugin-root>/scripts/state-commit --root <repo-root>
   ```
3. Check the result. If `stale_revision`, re-read the store and retry with the new revision.

### `requeue <WI-ID>`

Returns a work item to the queue when the executor cannot continue. This might happen because the executor hit a dead end, needs different information, or the session is ending.

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
5. **Sync native task.** Look up the native task for this WI (see Native Task Lookup below). If found, call `TaskUpdate` with `status: "pending"`.

**Common Use Cases:**
- **Implementation requeue** — Builder hit a dead end during `implementing`. Standard requeue to `ready`.
- **AUTOFIX requeue** — Review found bugs, WI is in `reviewing`. The Orchestrator requeues with `--reason autofix` so a Builder can claim it for the fix cycle. Promotion metadata is cleared because the current candidate is invalid.

### `complete <WI-ID>`

Marks a work item as done. This is a high-bar operation — it requires evidence that the work actually passed validation. When the last WI in the active candidate set completes, the set is atomically cleared in the same transaction.

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
8. **Sync native task.** Look up the native task for this WI (see Native Task Lookup below). If found, call `TaskUpdate` with `status: "completed"`.

**Arguments:**
- `--validation-manifest <path>` — required
- `--evidence-ref <path>` — required, can repeat
- `--verify-check <name>` — required, can repeat

### `attempt <json>`

Records an implementation attempt — useful for tracking what was tried, what failed, and why. The attempt is stored as a separate file, and the work item is updated to reference it.

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

## Timestamps

All timestamps are UTC ISO-8601 with `Z` suffix: `2026-04-08T12:00:00Z`

To calculate lease expiry: current time + lease minutes. Truncate microseconds.

## Native Task Lookup

All native task sync operations use the same lookup pattern:

1. Call `TaskList` to get all tasks.
2. Collect all tasks whose subject starts with `"WI-NNN:"` (matching the target WI's ID prefix).
3. Apply the deduplication rule:
   - **0 matches:** Log a warning to stderr and skip sync.
   - **1 match:** Use it as the canonical native task.
   - **2+ matches:** Log a warning to stderr listing duplicates. Use the task with the highest ID (newest) as canonical.

**Native task sync is best-effort.** Failures do not affect the WI state-commit outcome. `work-items.json` is the authoritative source of truth; native tasks are a visibility and dependency-resolution layer.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage or validation error (missing required fields, invalid payload) |
| `2` | Precondition failed (wrong status, lease owner mismatch) or stale revision |
| `3` | Work item not found |
| `4` | Runtime or environment failure |

## Input Conventions

All subcommands accept payload via:
- `--json '<inline-json>'` — inline JSON string
- `--input <path>` — path to a JSON file

Required flags for all mutating operations:
- `--request-id <id>` — unique request identifier for idempotency tracking

Revision handling:
- Single-file commands (`claim`, `requeue`, `attempt`) use the current `work-items.json` revision
- Verb commands (`heartbeat`) must pass `based_on_revision` equal to the current `work-items.json` revision
- Multi-file commands (`complete`) must track the current revision of every file they write (`work-items.json` and, when auto-clearing, `loop-state.json`)

## Output Contract

All subcommands return JSON to stdout:

```json
{
  "request_id": "REQ-104",
  "accepted": true,
  "committed_revision": 13,
  "changed": true,
  "artifacts": [
    ".agent-atelier/work-items.json"
  ]
}
```

The `attempt` subcommand additionally includes the attempt file in `artifacts`. Diagnostic messages go to stderr.

## Idempotency

- Same `request_id` + same payload → return previous result with `"changed": false, "replayed": true`
- Same `request_id` + different payload → reject with exit code `1`
- Stale `based_on_revision` → reject with exit code `2`

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| WI not in expected status | `2` | Report current status, suggest correct action |
| Lease owner mismatch | `2` | Report who holds the lease and when it expires |
| Lease already expired | `2` | Suggest requeue first, then re-claim |
| Validation manifest not passed | `2` | Report manifest status, block completion |
| Candidate set / branch / commit mismatch | `2` | Report the manifest mismatch and require `validate record` for the active candidate |
| Evidence file missing | `1` | List which files weren't found |
| WI not found | `3` | Report missing WI, list available IDs |
| Stale revision | `2` | Report current vs expected, ask caller to re-read |

## Constraints

- Lease fields only exist on `implementing` items — always clear them on status transitions away from `implementing`.
- The `complete` subcommand exists to ensure no work item becomes `done` without real evidence. Do not bypass the evidence checks.
- Read `references/wi-schema.md` for normalization rules that apply to all work item writes.
