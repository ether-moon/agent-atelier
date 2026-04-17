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

All mutations go through the `state-commit` script — the sole writer for `.agent-atelier/**`. Pattern: read current store (note its `revision`), validate preconditions, pipe transaction JSON to `state-commit`, check result (retry on `stale_revision`). Every transaction includes a revision field (`expected_revision` or `based_on_revision` for verb commands like `heartbeat`) set to the store's current revision at read time.

```bash
echo '<transaction-json>' | <plugin-root>/scripts/state-commit --root <repo-root>
```

## Subcommands

Detailed step-by-step procedures for each subcommand are in `reference/subcommands.md`. Below are summaries, arguments, and examples.

### `claim <WI-ID>`

Claims a work item for implementation. Sets status to `implementing`, establishes a lease, and syncs the native task to `in_progress`. Only the Orchestrator authorizes claims (via the State Manager) — Builders must NOT call this directly.

**Arguments:** `<WI-ID>` (required), `--owner-session-id <id>` (required), `--lease-minutes <N>` (optional, default 90)

**Example:**
```
execute claim WI-014 --owner-session-id exec-WI-014-1 --lease-minutes 90 --request-id REQ-100
```

### `heartbeat <WI-ID>`

Extends the lease on an `implementing` work item. Uses verb mode (direct state-commit call, no SM roundtrip).

**Example:**
```
execute heartbeat WI-014 --request-id REQ-101
```

### `requeue <WI-ID>`

Returns a work item to the queue. Clears lease fields. If requeuing from `reviewing`, also clears promotion metadata. Cannot requeue `done` items.

**Arguments:** `--owner-session-id <id>` (optional), `--reason <text>` (optional), `--increment-stale-requeue` (optional flag)

**Example — implementation dead end:**
```
execute requeue WI-014 --reason "dependency not available" --request-id REQ-102
```

**Example — AUTOFIX after failed review:**
```
execute requeue WI-014 --reason autofix --request-id REQ-103
```

### `complete <WI-ID>`

Marks a work item as done with evidence. Requires a passed validation manifest matching the active candidate set. When the last WI in the set completes, the candidate set is atomically cleared.

**Arguments:** `--validation-manifest <path>` (required), `--evidence-ref <path>` (required, repeatable), `--verify-check <name>` (required, repeatable)

**Example:**
```
execute complete WI-014 \
  --validation-manifest .agent-atelier/validation/RUN-2026-04-08-01/manifest.json \
  --evidence-ref .agent-atelier/validation/RUN-2026-04-08-01/report.md \
  --verify-check "pnpm test checkout" \
  --request-id REQ-104
```

### `attempt <json>`

Records a failed implementation attempt. Writes the attempt file and updates the work item reference in a single transaction.

**Example:**
```
execute attempt --json '{"work_item_id":"WI-014","summary":"API returned 403","findings":["auth scope missing"]}' --request-id REQ-105
```

## Timestamps

All timestamps are UTC ISO-8601 with `Z` suffix: `2026-04-08T12:00:00Z`. Lease expiry = current time + lease minutes, microseconds truncated.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage or validation error (missing required fields, invalid payload) |
| `2` | Precondition failed (wrong status, lease owner mismatch) or stale revision |
| `3` | Work item not found |
| `4` | Runtime or environment failure |

## Input Conventions

Mutating subcommands (`claim`, `requeue`, `complete`, `attempt`) accept payload via `--json '<inline-json>'` or `--input <path>`. Read-only subcommands do not require payload. Required for all mutating operations: `--request-id <id>`. The `heartbeat` verb command uses only positional arguments and `--lease-duration`.

Revision handling:
- Single-file commands (`claim`, `requeue`, `attempt`) use the current `work-items.json` revision
- Verb commands (`heartbeat`) pass `based_on_revision` equal to the current `work-items.json` revision
- Multi-file commands (`complete`) track the current revision of every file they write

## Output Contract

All subcommands return JSON to stdout:

```json
{
  "request_id": "REQ-104",
  "accepted": true,
  "committed_revision": 13,
  "changed": true,
  "artifacts": [".agent-atelier/work-items.json"]
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
| Candidate set / branch / commit mismatch | `2` | Report the mismatch, require `validate record` for the active candidate |
| Evidence file missing | `1` | List which files were not found |
| WI not found | `3` | Report missing WI, list available IDs |
| Stale revision | `2` | Report current vs expected, ask caller to re-read |

## Constraints

- Lease fields only exist on `implementing` items — always clear them on status transitions away from `implementing`.
- The `complete` subcommand exists to ensure no work item becomes `done` without real evidence. Do not bypass the evidence checks.
- Read `references/wi-schema.md` for normalization rules that apply to all work item writes.
