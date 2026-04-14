# Work Item Schema and Normalization

This reference defines the canonical work item shape, field defaults, and normalization rules applied on every upsert.

## Canonical Fields

Every work item has these fields. Missing fields get the defaults shown below.

```json
{
  "id": "WI-NNN",
  "revision": 0,
  "behavior_spec_revision": 1,
  "title": "",
  "why_now": "",
  "non_goals": [],
  "decision_rationale": [],
  "relevant_constraints": [],
  "success_metric_refs": [],
  "owner_role": "builder",
  "owner_session_id": null,
  "depends_on": [],
  "complexity": "simple",
  "behaviors": [],
  "input_artifacts": [],
  "owned_paths": [],
  "verify": [],
  "status": "pending",
  "blocked_by_gate": null,
  "resume_target": null,
  "first_claimed_at": null,
  "handoff_count": 0,
  "attempt_count": 0,
  "last_heartbeat_at": null,
  "lease_expires_at": null,
  "stale_requeue_count": 0,
  "last_attempt_ref": null,
  "last_finding_fingerprint": null,
  "promotion": {
    "candidate_branch": null,
    "candidate_commit": null,
    "status": "not_ready"
  },
  "completion": null
}
```

## Valid Statuses

`pending` | `ready` | `implementing` | `candidate_queued` | `candidate_validating` | `reviewing` | `blocked_on_human_gate` | `done`

## Valid Complexity Values

`simple` | `complex`

## Normalization Rules

Apply these rules every time a work item is created or updated:

### 1. Required field
`id` is required. Reject the operation if missing.

### 2. Array fields
These fields must be arrays. If null, default to `[]`. If not an array, reject:
`non_goals`, `decision_rationale`, `relevant_constraints`, `success_metric_refs`, `depends_on`, `behaviors`, `input_artifacts`, `owned_paths`, `verify`

### 3. Promotion object
`promotion` must be an object with three keys: `candidate_branch`, `candidate_commit`, `status`. Default any missing key to `null` (for branch/commit) or `"not_ready"` (for status).

### 4. Lease fields tied to status
When status is NOT `implementing`, clear these fields:
- `owner_session_id` → `null`
- `last_heartbeat_at` → `null`
- `lease_expires_at` → `null`

The reason: lease fields only make sense when someone is actively working on the item. Leaving stale lease data on a non-implementing item creates confusion about ownership.

### 5. Gate field tied to status
When status is NOT `blocked_on_human_gate` and the caller did not explicitly set `blocked_by_gate`, clear it to `null`. This prevents stale gate references.

### 6. Revision bump
Increment the work item's `revision` by 1 on every write.

### 7. Complexity field
`complexity` must be one of `simple` or `complex`. If null or missing, default to `"simple"`. Reject any other value.

### 8. depends_on immutability
`depends_on` is immutable after the initial upsert. If a work item already exists and has a non-empty `depends_on`, reject any upsert that changes its value. This prevents native task dependency drift — the Agent Teams API supports `addBlockedBy` but not removal, so stale blockers cannot be cleaned up. If dependency restructuring is needed, the Architect should create a new WI with the correct dependencies and retire the old one.

## Upsert Merge Logic

On upsert:
1. If a work item with the same `id` exists, merge: start with defaults, overlay existing item, overlay the new payload.
2. If no work item with the same `id` exists, merge: start with defaults, overlay the new payload.
3. Apply all normalization rules above.

## Store-Level Revision

The `work-items.json` file has its own `revision` field (separate from per-WI revisions). On every write to the store:
1. Increment `revision` by 1.
2. Set `updated_at` to the current UTC timestamp.

Before writing, verify the store's current `revision` matches the `based_on_revision` provided by the caller. If they don't match, reject with a stale-revision error. This prevents lost writes from concurrent access.
