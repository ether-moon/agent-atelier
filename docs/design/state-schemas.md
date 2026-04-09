# Agent-Atelier — State Schemas

**Date**: 2026-04-08
**Status**: Draft v1
**Scope**: Canonical machine-readable shapes for runtime state

---

## 1. Conventions

- All timestamps are UTC ISO-8601 strings, e.g. `2026-04-08T14:10:00Z`
- All ids are stable strings with prefixes:
  - `WI-` work item
  - `SUR-` state update request
  - `HDR-` human decision request
  - `ATT-` attempt
  - `VAL-` validation finding
  - `RUN-` validation run
  - `WDA-` watchdog alert
- Unknown fields must be ignored by readers unless explicitly marked forbidden
- Missing required fields are validation errors

---

## 2. `loop-state.json`

### Root Shape

```json
{
  "revision": 41,
  "updated_at": "2026-04-08T14:10:00Z",
  "mode": "VALIDATE",
  "active_spec": "docs/product/behavior-spec.md",
  "active_spec_revision": 7,
  "open_gates": ["HDR-002"],
  "active_candidate": {
    "work_item_id": "WI-014",
    "branch": "candidate/WI-014",
    "commit": "abc1234"
  },
  "candidate_activated_at": "2026-04-08T14:10:00Z",
  "candidate_queue": [],
  "next_action": {
    "owner": "orchestrator",
    "type": "dispatch_vrm_evidence_run",
    "target": "WI-014"
  }
}
```

### Required Fields

| Field | Type | Notes |
|---|---|---|
| `revision` | integer | Monotonic, committed by State Manager |
| `updated_at` | string | Commit timestamp |
| `mode` | enum | `DISCOVER`, `SPEC_DRAFT`, `SPEC_HARDEN`, `BUILD_PLAN`, `IMPLEMENT`, `VALIDATE`, `REVIEW_SYNTHESIS`, `AUTOFIX`, `DONE` |
| `active_spec` | string | Path to current behavior spec |
| `active_spec_revision` | integer | Monotonic spec revision |
| `open_gates` | string[] | Open HDR ids |
| `active_candidate` | object or null | Exclusive validation slot |
| `candidate_activated_at` | string or null | UTC timestamp set when a candidate enters the active slot; cleared on `candidate clear`. Used by watchdog for timeout detection. |
| `candidate_queue` | object[] | FIFO queue — `candidate activate` always pops the first entry |
| `next_action` | object | Scheduler hint only; not authoritative by itself |

### Invariants

- `revision` must increase by exactly 1 on every committed mutation
- `active_candidate` may be null, but if non-null it must not also appear in `candidate_queue`
- every id in `open_gates` must exist under `.agent-atelier/human-gates/open/`

---

## 3. `work-items.json`

### Root Shape

```json
{
  "revision": 12,
  "updated_at": "2026-04-08T14:10:00Z",
  "items": [
    {
      "id": "WI-014",
      "revision": 4,
      "behavior_spec_revision": 7,
      "title": "Checkout page empty/loading/error states",
      "why_now": "Checkout validation is blocked by missing empty/loading/error states in the current candidate.",
      "non_goals": [
        "Guest checkout policy changes"
      ],
      "decision_rationale": [
        "Preserve the current public checkout API contract."
      ],
      "relevant_constraints": [
        "Must keep the existing checkout response shape."
      ],
      "success_metric_refs": [
        "docs/product/success-metrics.md#guardrail-metrics"
      ],
      "owner_role": "builder",
      "owner_session_id": "exec-WI-014-02",
      "depends_on": ["WI-003"],
      "behaviors": ["B3", "B4"],
      "input_artifacts": [
        "docs/product/behavior-spec.md#B3"
      ],
      "owned_paths": [
        "apps/web/src/pages/checkout/"
      ],
      "verify": [
        "test: checkout loading state shows spinner"
      ],
      "status": "implementing",
      "blocked_by_gate": null,
      "resume_target": null,
      "attempt_count": 2,
      "last_heartbeat_at": "2026-04-08T14:05:00Z",
      "lease_expires_at": "2026-04-08T15:35:00Z",
      "stale_requeue_count": 1,
      "last_attempt_ref": ".agent-atelier/attempts/WI-014/attempt-02.json",
      "last_finding_fingerprint": "VAL-031/retry-button-not-clickable",
      "promotion": {
        "candidate_branch": null,
        "candidate_commit": null,
        "status": "not_ready"
      }
    }
  ]
}
```

### Required WI Fields

| Field | Type | Notes |
|---|---|---|
| `id` | string | Stable WI id |
| `revision` | integer | Monotonic WI-local revision |
| `behavior_spec_revision` | integer | Binding to spec snapshot |
| `title` | string | Human-readable |
| `why_now` | string | Required context for intent preservation |
| `non_goals` | string[] | Explicitly out of scope |
| `decision_rationale` | string[] | Why this implementation path exists |
| `relevant_constraints` | string[] | Must-stay-true constraints |
| `success_metric_refs` | string[] | Product-signal refs only; not executable verify checks |
| `owner_role` | enum | Usually `builder` or `validator` depending on state |
| `depends_on` | string[] | WI ids |
| `behaviors` | string[] | Behavior ids |
| `input_artifacts` | string[] | Paths or anchors |
| `owned_paths` | string[] | File ownership boundaries |
| `verify` | string[] | Binary verification checks |
| `status` | enum | See status table below |
| `attempt_count` | integer | Monotonic retry count |
| `stale_requeue_count` | integer | Watchdog intervention count |
| `handoff_count` | integer | Number of times the WI has been claimed |

### Optional WI Fields

| Field | Type | Notes |
|---|---|---|
| `owner_session_id` | string or null | Current lease holder |
| `first_claimed_at` | string or null | Write-once: set on first claim, never updated on re-claim. Used by watchdog for wall-clock budget tracking. |
| `blocked_by_gate` | string or null | HDR id |
| `resume_target` | string or null | Target mode after gate resolution. Valid values: any `mode` enum value (e.g., `BUILD_PLAN`, `IMPLEMENT`). Set by gate opener, consumed by Orchestrator on resolve. |
| `last_heartbeat_at` | string or null | Updated by lease holder |
| `lease_expires_at` | string or null | Active lease deadline |
| `last_attempt_ref` | string or null | Attempt artifact |
| `last_finding_fingerprint` | string or null | Used for loop guardrails |
| `last_requeue_reason` | string or null | Set on requeue by execute or watchdog (e.g., `"watchdog: lease expired"`) |
| `promotion` | object | Candidate metadata (see Promotion sub-object below) |
| `completion` | object or null | Required when `status = done`. See Completion sub-object below. |

### Promotion Sub-Object

```json
{
  "candidate_branch": "candidate/WI-014",
  "candidate_commit": "abc1234",
  "status": "queued"
}
```

| Field | Type | Notes |
|---|---|---|
| `candidate_branch` | string or null | Branch name for the candidate |
| `candidate_commit` | string or null | Commit hash for the candidate |
| `status` | enum | `not_ready`, `queued`, `validating`, `demoted` |

### Completion Sub-Object

Set by `execute complete` when a WI transitions to `done`:

```json
{
  "completed_at": "2026-04-08T15:00:00Z",
  "validation_run_id": "RUN-2026-04-08-01",
  "validation_manifest": ".agent-atelier/validation/RUN-2026-04-08-01/manifest.json",
  "evidence_refs": [".agent-atelier/validation/RUN-2026-04-08-01/report.md"],
  "verify_checks": ["pnpm test checkout"]
}
```

| Field | Type | Notes |
|---|---|---|
| `completed_at` | string | UTC timestamp |
| `validation_run_id` | string | The RUN that validated this WI |
| `validation_manifest` | string | Path to the validation manifest |
| `evidence_refs` | string[] | Paths to evidence artifacts |
| `verify_checks` | string[] | Names of checks that passed |

### Status Enum

- `pending`
- `ready`
- `implementing`
- `candidate_queued`
- `candidate_validating`
- `reviewing`
- `blocked_on_human_gate`
- `done`

### Invariants

- `implementing` requires `owner_session_id` and `lease_expires_at`
- `candidate_validating` requires candidate metadata
- `done` requires evidence refs through completion request
- `blocked_on_human_gate` requires `blocked_by_gate`

---

## 4. `SUR` — State Update Request

```json
{
  "id": "SUR-104",
  "request_id": "REQ-104",
  "requested_by": "architect",
  "based_on_revision": 41,
  "target": "work-items.json",
  "operation": "transition_work_item",
  "payload": {
    "work_item_id": "WI-014",
    "from_status": "implementing",
    "to_status": "candidate_queued"
  },
  "causation_id": "MSG-883"
}
```

### Required Fields

- `id`
- `request_id`
- `requested_by`
- `based_on_revision`
- `target`
- `operation`
- `payload`
- `causation_id`

---

## 5. `HDR` — Human Decision Request

The detailed fields remain aligned with [human-gate-ops.md](./human-gate-ops.md). This document adds the machine invariants:

- `state` must be `open` or `resolved`
- `blocked_work_items` and `unblocked_work_items` must be disjoint
- `resolution.resolved_at` is required when `state = resolved`
- every `blocked_work_items` id must exist in `work-items.json`

---

## 6. Attempt File

### Required Fields

- `id`
- `work_item_id`
- `attempt`
- `hypothesis`
- `repro_steps`
- `commands_run`
- `result`
- `finding_fingerprint`

### Result Enum

- `failed`
- `abandoned`
- `superseded`

---

## 7. Validation Run Manifest

Every validation run must produce a machine-readable manifest in addition to any human-readable report.

Suggested path:

- `.agent-atelier/validation/<run-id>/manifest.json`

### Shape

```json
{
  "id": "RUN-2026-04-08-01",
  "work_item_id": "WI-014",
  "candidate_branch": "candidate/WI-014",
  "candidate_commit": "abc1234",
  "started_at": "2026-04-08T14:10:00Z",
  "finished_at": "2026-04-08T14:17:00Z",
  "status": "passed",
  "checks": [
    {
      "name": "pnpm test checkout",
      "status": "passed"
    }
  ],
  "evidence_refs": [
    ".agent-atelier/validation/RUN-2026-04-08-01/report.md"
  ]
}
```

### Status Enum

- `running`
- `passed`
- `failed`
- `environment_error`

---

## 8. `watchdog-jobs.json`

### Root Shape

```json
{
  "revision": 3,
  "updated_at": "2026-04-08T14:10:00Z",
  "defaults": {
    "implementing_timeout_minutes": 90,
    "candidate_timeout_minutes": 30,
    "review_timeout_minutes": 30,
    "gate_warn_after_hours": 24
  },
  "budgets": {
    "max_wall_clock_minutes_per_wi": 480,
    "max_handoffs_per_wi": 6,
    "max_watchdog_interventions_per_wi": 3,
    "max_attempts_per_wi": 5
  },
  "open_alerts": [],
  "last_tick_at": "2026-04-08T14:10:00Z"
}
```

---

## 9. Watchdog Alert

`recovery_action` is required whenever watchdog performs an automatic state change.

If watchdog only warns, `recovery_action` may be null.

---

## 10. Validation Rules To Encode In Code

Implementers should turn this document into actual schema validation for:

- request parsing
- file read/write validation
- state transition precondition checks
- completion gating

The code should reject malformed inputs early instead of relying on prompt discipline.
