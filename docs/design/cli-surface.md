# Agent-Atelier — CLI Surface

**Date**: 2026-04-08
**Status**: Draft v1
**Scope**: Required `agent-atelier` command interface for the runtime

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

#### `agent-atelier init-state`

Creates the initial orchestration directory and bootstrap files.

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

#### `agent-atelier wi upsert`

Creates or replaces a WI definition.

#### `agent-atelier wi claim`

Preconditions:

- WI exists
- WI status is `ready`
- no valid lease exists

Effects:

- transitions WI to `implementing`
- writes `owner_session_id`, `last_heartbeat_at`, `lease_expires_at`

#### `agent-atelier wi heartbeat`

Preconditions:

- caller owns the active lease

Effects:

- updates heartbeat timestamp
- extends lease expiry

#### `agent-atelier wi requeue`

Preconditions:

- WI is not `done`

Effects:

- clears ownership
- moves WI to `ready` or `pending`
- optionally appends a reason

#### `agent-atelier wi complete`

Preconditions:

- evidence refs exist
- validator run exists
- WI is in `reviewing`
- manifest candidate set / branch / commit match the active candidate set
- requested revision is current

Effects:

- moves WI to `done`

### 4.4 Attempt Commands

#### `agent-atelier attempt append`

Appends an attempt artifact and updates WI attempt counters.

### 4.5 Candidate Commands

#### `agent-atelier candidate enqueue`

Adds a WI candidate to the queue.

#### `agent-atelier candidate activate`

Moves one queued candidate set into `active_candidate_set`.

#### `agent-atelier candidate clear`

Clears the active candidate set after completion or demotion.

### 4.6 Validation Commands

#### `agent-atelier validate record`

Registers a validation run manifest for a candidate set and links it to one or more WIs.

### 4.7 Human Gate Commands

#### `agent-atelier gate open`

Creates an HDR and blocks the affected WIs.

#### `agent-atelier gate list`

Returns all open and resolved gates.

#### `agent-atelier gate resolve`

Resolves an HDR and restores blocked WIs to `ready`.

### 4.8 Watchdog

#### `agent-atelier watchdog tick`

Evaluates orchestration state, performs allowed mechanical recovery, and writes alerts.

The command must be safe to run repeatedly.

`watchdog tick` is mechanical only. Owner reachability checks, teammate respawn, and work re-dispatch belong to the Orchestrator's resume sweep after the tick.

### 4.9 Orchestration Runner

#### `agent-atelier run`

Top-level entry point for the autonomous development loop. Spawns the agent team, drives work items through the full lifecycle (spec → implement → validate → review → done), and manages role activation/shutdown by phase.

This is the highest-level command — it orchestrates all other commands internally. It is not a state-mutating command in the traditional sense; it is a long-running coordinator.

`run` also owns the lifecycle of session-scoped runtime infrastructure:

- creates fresh monitors
- creates the `*/2` monitor poll cron job
- creates the `*/15` watchdog recovery cron job
- after crash recovery, runs one startup resume sweep so stranded `implementing` WIs are reclaimed immediately instead of waiting for lease expiry

Required preconditions:

- orchestration initialized (`init-state` completed)
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

1. `init-state`
2. `state show`
3. `wi upsert`, `wi claim`, `wi heartbeat`, `wi requeue`, `wi complete`
4. `attempt append`
5. `candidate enqueue`, `candidate activate`, `candidate clear`
6. `validate record`
7. `gate open`, `gate resolve`
8. `watchdog tick`
9. `run` (orchestration loop — depends on all of the above)

This sequence matches the v0 runtime path.
