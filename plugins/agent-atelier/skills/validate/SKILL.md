---
name: validate
description: "Validation evidence recording — register a validation run manifest with check results and link it to the work item. Use when a validator finishes a validation run, when recording test evidence, or when the orchestrator needs to formally register a validation outcome. Triggers on 'validate', 'record validation', 'register run', 'validation complete', 'validation failed', 'record evidence', 'VRM done', or 'validation manifest'."
argument-hint: "record <json-or-fields>"
---

# Validate — Validation Evidence Recording

Registers a validation run manifest (test results, check outcomes) and updates work item status based on the outcome. Bridges the validator finishing its work and the orchestration system knowing the result.

## When This Skill Runs

- Validator finishes checks against a candidate and needs to formally register the outcome
- Orchestrator needs to record a validation result (passed, failed, or environment error)

## Prerequisites

- Orchestration must be initialized
- All work items must be in `candidate_validating` status
- All work items must be in the current `active_candidate_set` in loop-state
- Candidate branch and commit in the manifest must match the active set's branch/commit

## Allowed Tools

- Read (state files, evidence files), Write (validation manifest), Bash (git root, state-commit, mkdir), Glob

## Write Protocol

Two-phase write — the manifest and orchestration state have different ownership.

**Phase 1 — Write manifest** to `.agent-atelier/validation/<run-id>/manifest.json` via Write tool (Validator-owned directory, not state-commit). Create the directory if needed.

**Phase 2 — Update orchestration state** via state-commit:

```bash
echo '<transaction-json>' | <plugin-root>/scripts/state-commit --root <repo-root>
```

Phase 1 must succeed before Phase 2. If Phase 2 fails (stale revision), the manifest is a harmless orphan — re-read and retry Phase 2 only.

## Subcommand

### `record`

Registers a validation run manifest and updates the work item status based on the outcome.

1. **Parse the validation payload.** Required fields:
   - `id` — run identifier (e.g., `RUN-2026-04-08-01`). Generate from date if not provided.
   - `candidate_set_id` — required (must match `active_candidate_set.id`)
   - `work_item_ids` — required array of WI IDs (must match `active_candidate_set.work_item_ids`)
   - `candidate_branch` — required
   - `candidate_commit` — required
   - `started_at` — required (UTC ISO-8601)
   - `finished_at` — required (UTC ISO-8601)
   - `status` — required, must be one of: `passed`, `failed`, `environment_error`
   - `checks` — required array of `{"name": "...", "status": "passed|failed"}` objects
   - `evidence_refs` — array of paths to evidence files (optional but recommended)

2. **Read state.** Read `.agent-atelier/work-items.json` and `.agent-atelier/loop-state.json`. Note both revisions.

3. **Validate preconditions.** Active candidate set must exist; `candidate_set_id`, `work_item_ids`, `candidate_branch`, and `candidate_commit` must all match the active set. All WIs must exist with status `candidate_validating`.

4. **Verify evidence.** If `evidence_refs` provided, verify each path exists on disk. Warn (do not block) if empty — evidence may be generated separately.

5. **Phase 1: Write manifest.** Create directory `.agent-atelier/validation/<run-id>/` if needed. Write the full manifest JSON to `.agent-atelier/validation/<run-id>/manifest.json`.

   ```json
   {
     "id": "RUN-2026-04-08-01",
     "candidate_set_id": "CS-001",
     "work_item_ids": ["WI-018", "WI-019", "WI-020", "WI-021"],
     "candidate_branch": "feat/phase-2",
     "candidate_commit": "abc1234",
     "started_at": "2026-04-08T14:10:00Z",
     "finished_at": "2026-04-08T14:17:00Z",
     "status": "passed",
     "checks": [
       {"name": "pnpm test checkout", "status": "passed"}
     ],
     "evidence_refs": [
       ".agent-atelier/validation/RUN-2026-04-08-01/report.md"
     ]
   }
   ```

6. **Phase 2: Update orchestration state.** The update depends on the manifest `status`:

   **If `passed`:**
   - **work-items.json:** All WIs `status` → `reviewing`. Bump each item `revision`.
   - **loop-state.json:** No change — candidate set stays active until the last WI completes.
   - Commit work-items.json only.

   **If `failed`:** (atomic demotion + candidate set clear — fate-sharing)
   - **work-items.json** (for each WI in the set):
     - `status` → `ready`
     - `promotion.candidate_branch` → null
     - `promotion.candidate_commit` → null
     - `promotion.status` → `not_ready`
     - Bump item `revision`
   - **loop-state.json:** `active_candidate_set` → null. Bump `revision`, set `updated_at`.
   - Commit **both** files in one transaction (atomic demotion + set clear — no separate `candidate clear` needed).
   - **Sync native tasks.** For each WI, search `TaskList` for a task whose subject starts with `"WI-NNN:"`. If found, call `TaskUpdate` with `status: "pending"`. If 2+ matches, use the highest-ID task. Sync is best-effort — failures do not block the state commit.

   **If `environment_error`:**
   - **work-items.json:** No status change — WIs stay `candidate_validating`. The environment issue is not the code's fault.
   - **loop-state.json:** No change — the candidate set stays active.
   - Skip the commit entirely. Report the environment error to the caller so the orchestrator can decide next steps (retry validation, escalate, or open a gate).
7. **Check commit result.** If stale revision, re-read and retry Phase 2 only.

**Arguments:**
- `<json-or-fields>` — manifest data as inline JSON or structured fields
- `--manifest-path <path>` — read an already-written manifest; perform Phase 2 only

## Examples

**Record a passed validation run (inline JSON):**
```
validate record --request-id REQ-401 --json '{"id":"RUN-2026-04-08-01","candidate_set_id":"CS-001","work_item_ids":["WI-018"],"candidate_branch":"feat/phase-2","candidate_commit":"abc1234","started_at":"2026-04-08T14:10:00Z","finished_at":"2026-04-08T14:17:00Z","status":"passed","checks":[{"name":"pnpm test","status":"passed"}]}'
```
Result: manifest written, WIs move to `reviewing`, `"changed": true`.

**Record a failed run from an existing manifest:**
```
validate record --request-id REQ-402 --manifest-path .agent-atelier/validation/RUN-2026-04-08-02/manifest.json
```
Result: WIs demoted to `ready`, candidate set cleared, native tasks synced to `pending`.

**Environment error (no state changes):**
```
validate record --request-id REQ-403 --json '{"id":"RUN-2026-04-08-03",...,"status":"environment_error",...}'
```
Result: manifest written, `"changed": false`. Orchestrator decides next steps.

## Timestamps

All timestamps are UTC ISO-8601 with `Z` suffix: `2026-04-08T12:00:00Z`

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage/validation error (missing fields, invalid status, evidence missing) |
| `2` | Precondition failed (wrong WI status, branch/commit mismatch) or stale revision |
| `3` | Work item not found |
| `4` | Runtime failure (disk write, directory creation) |

## Input Conventions

Payload via `--json '<inline>'`, `--input <path>`, or `--manifest-path <path>` (Phase 2 only).

Required: `--request-id <id>` for idempotency tracking.

Revision handling: track the current revision of every JSON file you mutate and use the matching `expected_revision` per file in the `state-commit` transaction. Do not collapse multi-file revisions into one shared value.

## Output Contract

Returns JSON to stdout:

```json
{
  "request_id": "REQ-401",
  "accepted": true,
  "committed_revision": 13,
  "changed": true,
  "artifacts": [".agent-atelier/validation/RUN-.../manifest.json", ".agent-atelier/work-items.json"]
}
```

Artifacts vary by status: `passed` includes `work-items.json`; `failed` includes both `work-items.json` and `loop-state.json` (atomic demotion + set clear); `environment_error` returns `"changed": false` with only the manifest. Diagnostics go to stderr.

## Idempotency

- Same `request_id` + same payload → return previous result with `"changed": false, "replayed": true`
- Same `request_id` + different payload → reject with exit code `1`
- Stale `based_on_revision` → reject with exit code `2`
- Manifest file is idempotent by run ID — re-writing the same manifest to the same path produces the same result

## Error Handling

| Condition | Exit | Action |
|-----------|------|--------|
| WI not found | `3` | Report missing WI, list available IDs |
| WI not `candidate_validating` | `2` | Report current status, explain expected |
| WIs not in active candidate set | `2` | Report active set, suggest waiting |
| `candidate_set_id` mismatch | `2` | Report manifest vs active set mismatch |
| Branch/commit mismatch | `2` | Report manifest vs active set mismatch |
| Evidence file missing | `1` | List missing evidence_refs paths |
| Manifest already exists | `0` | Report path, suggest checking for duplicates |
| Invalid manifest status | `1` | Report value, list valid statuses |
| Stale revision | `2` | Report current vs expected, ask to re-read |

## Constraints

- **Information barrier:** The manifest contains only objective check results — the validator does not read builder narrative, diffs, or implementation explanations.
- **Manifest is source of truth.** WI status transitions derive from manifest status, not from any other signal.
- **Evidence refs must resolve.** The skill verifies each path exists before committing.
- **Terminal statuses only:** `passed`, `failed`, `environment_error`. Do not use `running` — record only after the run finishes.
- Read `references/wi-schema.md` for normalization rules on all work item writes.
