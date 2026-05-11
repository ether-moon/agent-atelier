# Agent-Atelier — CLI Surface

**Date**: 2026-04-08 (revised 2026-05-08)
**Status**: Draft v1
**Scope**: Required runtime command interface

## Surface Overview

The runtime exposes two distinct surfaces:

- **User-facing skills (3):** `/agent-atelier:plan`, `/agent-atelier:execute`, `/agent-atelier:status` — the only commands a user is expected to invoke directly. `monitors` exists as a fourth skill but is internal-by-usage (invoked by the orchestrator/cron, not the user).
- **Mechanical scripts (`plugins/agent-atelier/scripts/*`):** `state-commit`, `init-helpers.sh`, `wi`, `lifecycle`, `gate`, `watchdog`, `candidate`, `validate`. These implement the verbs documented below; orchestrator and roles invoke them. All emit JSON; mutating scripts include a `native_task_sync` hint for the LLM-side Agent Teams sync.

Sections 4.1–4.9 below describe the verbs, regardless of whether they are implemented as scripts or skills.

---

## 1. Command Design Rules

The CLI is the first implementation surface for the runtime.

Rules:

- commands must be scriptable and non-interactive
- success output goes to stdout as JSON
- diagnostic output goes to stderr
- state-mutating commands require a request id
- commands must be idempotent where possible

---

## 2. Exit Codes

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | usage or validation error |
| `2` | precondition failed or stale revision |
| `3` | requested object not found |
| `4` | runtime/environment failure |

---

## 3. Input Conventions

State-mutating commands should accept either:

- `--input <path-to-json>`
- `--json '<inline-json>'`

Required common flags for mutating commands:

- `--request-id`
- `--based-on-revision` for single-file writes
- per-file revision basis for multi-file transactions

---

## 4. Required Command Groups

### 4.1 Bootstrap

#### `scripts/init-helpers.sh` (formerly `agent-atelier init-state`)

Creates the initial orchestration directory and bootstrap files. Invoked transparently by `/agent-atelier:plan` and `/agent-atelier:execute` when the workspace is missing.

Required outputs:

- `.agent-atelier/loop-state.json`
- `.agent-atelier/work-items.json`
- `.agent-atelier/watchdog-jobs.json`
- `.agent-atelier/human-gates/{open,resolved}/`
- `.agent-atelier/attempts/`

### 4.2 Read Commands

#### `agent-atelier state show`

Returns the current `loop-state.json`.

#### `agent-atelier wi list`

Returns all work items.

#### `agent-atelier wi show --wi-id WI-014`

Returns one work item.

### 4.3 Work Item Commands

#### `scripts/wi upsert`

Creates or replaces a WI definition.

#### `scripts/lifecycle claim`

Preconditions:

- WI exists
- WI status is `ready`
- no valid lease exists

Effects:

- transitions WI to `implementing`
- writes `owner_session_id`, `last_heartbeat_at`, `lease_expires_at`

#### `scripts/lifecycle heartbeat`

Preconditions:

- caller owns the active lease

Effects:

- updates heartbeat timestamp
- extends lease expiry

#### `scripts/lifecycle requeue`

Preconditions:

- WI is not `done`

Effects:

- clears ownership
- moves WI to `ready` or `pending`
- optionally appends a reason

#### `scripts/lifecycle complete`

Preconditions:

- evidence refs exist
- validator run exists
- WI is in `reviewing`
- manifest candidate set / branch / commit match the active candidate set
- requested revision is current

Effects:

- moves WI to `done`

### 4.4 Attempt Commands

#### `scripts/lifecycle attempt`

Appends an attempt artifact and updates WI attempt counters.

### 4.5 Candidate Commands

#### `scripts/candidate enqueue`

Adds a WI candidate to the queue.

#### `scripts/candidate activate`

Moves one queued candidate set into `active_candidate_set`.

#### `scripts/candidate clear`

Clears the active candidate set after completion or demotion.

### 4.6 Validation Commands

#### `scripts/validate record`

Registers a validation run manifest for a candidate set and links it to one or more WIs.

### 4.7 Human Gate Commands

#### `scripts/gate open`

Creates an HDR and blocks the affected WIs.

#### `scripts/gate list`

Returns all open and resolved gates.

#### `scripts/gate resolve`

Resolves an HDR and restores blocked WIs to `ready`.

### 4.8 Watchdog

#### `scripts/watchdog tick`

Evaluates orchestration state, performs allowed mechanical recovery, and writes alerts.

The command must be safe to run repeatedly.

`watchdog tick` is mechanical only. Owner reachability checks, teammate respawn, and work re-dispatch belong to the Orchestrator's resume sweep after the tick.

### 4.9 Orchestration Runner

#### `/agent-atelier:execute`

Top-level user-facing entry point for the autonomous development loop. If no valid `plan_approval` exists, the execute skill first runs the `/agent-atelier:plan` cycle (DISCOVER → BUILD_PLAN with ping-pong + approval gate); after a valid plan is recorded, it spawns the agent team, drives work items through IMPLEMENT → VALIDATE → REVIEW → DONE, and manages role activation/shutdown by phase.

This is the highest-level command — it orchestrates all the script-level verbs internally. It is not a state-mutating command in the traditional sense; it is a long-running coordinator.

`/agent-atelier:execute` also owns the lifecycle of session-scoped runtime infrastructure:

- creates fresh monitors (via the internal `monitors` shim)
- creates the `*/2` monitor poll cron job
- creates the `*/15` watchdog recovery cron job
- after crash recovery, runs one startup resume sweep so stranded `implementing` WIs are reclaimed immediately instead of waiting for lease expiry

Required preconditions:

- orchestration initialized (`scripts/init-helpers.sh` completed; auto-run on first invocation)
- behavior spec exists at the configured path

---

## 5. Output Contract

Mutating commands should return:

```json
{
  "request_id": "REQ-104",
  "accepted": true,
  "committed_revision": 42,
  "changed": true,
  "artifacts": [
    ".agent-atelier/work-items.json"
  ]
}
```

If the command is idempotently replayed, it may return:

```json
{
  "request_id": "REQ-104",
  "accepted": true,
  "committed_revision": 42,
  "changed": false,
  "replayed": true
}
```

---

## 6. Idempotency Rules

- same `request_id` + same payload -> replay success
- same `request_id` + different payload -> reject
- stale revision basis -> reject with exit code `2`

---

## 7. Implementation Sequence

The CLI should be implemented in this order:

1. `scripts/init-helpers.sh`
2. `scripts/wi list` / `wi show`
3. `scripts/wi upsert`, `scripts/lifecycle claim|heartbeat|requeue|complete`
4. `scripts/lifecycle attempt`
5. `scripts/candidate enqueue|activate|clear`
6. `scripts/validate record`
7. `scripts/gate open|resolve`
8. `scripts/watchdog tick`
9. `/agent-atelier:plan` and `/agent-atelier:execute` (orchestration loop — depend on all of the above)

This sequence matches the v0 runtime path.
