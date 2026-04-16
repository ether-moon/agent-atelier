---
name: validate
description: "Validation evidence recording — register a validation run manifest with check results and link it to the work item. Use when a validator finishes a validation run, when recording test evidence, or when the orchestrator needs to formally register a validation outcome. Triggers on 'validate', 'record validation', 'register run', 'validation complete', 'validation failed', 'record evidence', 'VRM done', or 'validation manifest'."
argument-hint: "record <json-or-fields>"
---

# Validate — Validation Evidence Recording

Validation runs produce evidence — test results, screenshots, check outcomes. This skill formally registers that evidence by writing a machine-readable manifest and updating the work item's status based on the outcome. It is the bridge between a validator finishing its work and the orchestration system knowing the result.

## When This Skill Runs

- Validator finishes running checks against a candidate
- Evidence needs to be formally registered before completion can proceed
- Orchestrator needs to record a validation outcome (passed, failed, or environment error)

## Prerequisites

- Orchestration must be initialized
- All work items must be in `candidate_validating` status
- All work items must be in the current `active_candidate_set` in loop-state
- Candidate branch and commit in the manifest must match the active set's branch/commit

## Allowed Tools

- Read (state files, evidence files), Write (validation manifest), Bash (git root, state-commit, mkdir), Glob

## Write Protocol

This skill uses a two-phase write because the validation manifest and the orchestration state live in different directories with different ownership rules.

**Phase 1 — Write the manifest** to `.agent-atelier/validation/<run-id>/manifest.json`. This subdirectory is Validator-owned (see runtime-contracts.md §3.2), so it goes through the Write tool directly, not state-commit. Create the directory if it does not exist.

**Phase 2 — Update orchestration state** via state-commit. Read both stores, validate preconditions, prepare the update, and commit atomically.

```bash
echo '<transaction-json>' | <plugin-root>/scripts/state-commit --root <repo-root>
```

**Ordering guarantee:** Phase 1 must succeed before Phase 2 begins. If Phase 2 fails (stale revision), the manifest from Phase 1 is a harmless orphan — re-read and retry Phase 2 only. The manifest is idempotent by run ID.

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

3. **Validate preconditions.**
   - `active_candidate_set` is not null
   - `candidate_set_id` matches `active_candidate_set.id`
   - `work_item_ids` matches `active_candidate_set.work_item_ids` (same set)
   - All WIs exist and have status `candidate_validating`
   - `candidate_branch` matches `active_candidate_set.branch`
   - `candidate_commit` matches `active_candidate_set.commit`

4. **Verify evidence.** If `evidence_refs` are provided, verify each path resolves to an existing file on disk. Warn (but do not block) if evidence refs are empty — the evidence may be generated separately.

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
   - **loop-state.json:** No change — the candidate set stays active for the review and completion phase.
   - Commit work-items.json only.

   **If `failed`:** (atomic demotion + candidate set clear — fate-sharing)
   - **work-items.json** (for each WI in the set):
     - `status` → `ready`
     - `promotion.candidate_branch` → null
     - `promotion.candidate_commit` → null
     - `promotion.status` → `demoted`
     - Bump item `revision`
   - **loop-state.json:** `active_candidate_set` → null. Bump `revision`, set `updated_at`.
   - Commit **both** files in one transaction. The candidate set is atomically cleared alongside the WI demotion — no separate `candidate clear` call is needed.
   - **Sync native tasks.** For each WI, look up the native task and call `TaskUpdate` with `status: "pending"`.

   **If `environment_error`:**
   - **work-items.json:** No status change — WIs stay `candidate_validating`. The environment issue is not the code's fault. Bump item `revision` only if adding a note.
   - **loop-state.json:** No change — the candidate set stays active.
   - The orchestrator decides next steps (retry validation, escalate, or open a gate).
   - If no state changes are needed, skip the commit and report the environment error to the caller.

7. **Check commit result.** If stale revision, re-read and retry Phase 2 only.

**Arguments:**
- `<json-or-fields>` — the validation run manifest data, as inline JSON or structured fields
- `--manifest-path <path>` — alternative: read an already-written manifest from disk and perform only the Phase 2 linkage/status update

## Timestamps

All timestamps are UTC ISO-8601 with `Z` suffix: `2026-04-08T12:00:00Z`

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage or validation error (missing required fields, invalid manifest status, evidence file missing) |
| `2` | Precondition failed (wrong WI status, branch/commit mismatch, not active candidate) or stale revision |
| `3` | Work item not found |
| `4` | Runtime or environment failure (disk write failure, manifest directory creation failure) |

## Input Conventions

The `record` subcommand accepts payload via:
- `--json '<inline-json>'` — inline JSON string
- `--input <path>` — path to a JSON file
- `--manifest-path <path>` — read an already-written manifest from disk (Phase 2 only)

Required flags:
- `--request-id <id>` — unique request identifier for idempotency tracking
- `--based-on-revision <N>` — the store revision observed at read time

## Output Contract

Returns JSON to stdout:

```json
{
  "request_id": "REQ-401",
  "accepted": true,
  "committed_revision": 13,
  "changed": true,
  "artifacts": [
    ".agent-atelier/validation/RUN-2026-04-08-01/manifest.json",
    ".agent-atelier/work-items.json"
  ]
}
```

When validation fails, `artifacts` includes both `.agent-atelier/work-items.json` and `.agent-atelier/loop-state.json` (atomic demotion + set clear). For `environment_error` with no state changes: `"changed": false`. Diagnostic messages go to stderr.

## Idempotency

- Same `request_id` + same payload → return previous result with `"changed": false, "replayed": true`
- Same `request_id` + different payload → reject with exit code `1`
- Stale `based_on_revision` → reject with exit code `2`
- Manifest file is idempotent by run ID — re-writing the same manifest to the same path produces the same result

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| WI not found | `3` | Report missing WI, list available IDs |
| Any WI not in `candidate_validating` | `2` | Report current status, explain expected status |
| WIs not in `active_candidate_set` | `2` | Report which set is active, suggest waiting |
| `candidate_set_id` mismatch | `2` | Report the mismatch between manifest and active set |
| Branch/commit mismatch | `2` | Report the mismatch between manifest and active set |
| Evidence file missing | `1` | List which evidence_refs were not found on disk |
| Manifest already exists for this run ID | `0` | Report existing manifest path, suggest checking for duplicate runs |
| Invalid manifest status | `1` | Report the invalid value, list valid statuses (`passed`, `failed`, `environment_error`) |
| Stale revision | `2` | Report current vs expected, ask caller to re-read |

## Constraints

- The validation information barrier must be respected: the validator does not read builder narrative, diffs, or implementation explanations. The manifest contains only objective check results.
- The manifest is the source of truth for validation outcomes. The WI status transition is derived from the manifest status, not from any other signal.
- Evidence refs in the manifest should point to real files. The skill verifies their existence before committing.
- Only terminal statuses are accepted: `passed`, `failed`, `environment_error`. The `running` status is valid for in-progress manifests but should not be recorded through this skill — use it only after the run finishes.
- Read `references/wi-schema.md` for normalization rules that apply to all work item writes.
