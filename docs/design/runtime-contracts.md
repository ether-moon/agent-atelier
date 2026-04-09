# Agent-Atelier — Runtime Contracts

**Date**: 2026-04-08
**Status**: Draft v1
**Scope**: Cross-component runtime behavior for the multi-agent implementation

---

## 1. Purpose

This document turns the high-level architecture in [system-design.md](./system-design.md) into implementation contracts.

- `system-design.md` defines the architecture and operating principles.
- `runtime-contracts.md` defines cross-role ownership and invariants.
- [state-schemas.md](./state-schemas.md) defines canonical machine-readable shapes.
- [agent-lifecycle.md](./agent-lifecycle.md) defines runtime state transitions over time.
- [cli-surface.md](./cli-surface.md) defines the executable control surface.
- [recovery-spec.md](./recovery-spec.md) defines crash recovery and watchdog recovery behavior.

If an example in `system-design.md` conflicts with one of the implementation docs above, the implementation docs win.

---

## 2. Runtime Components

| Component | Responsibility | Writes |
|---|---|---|
| Orchestrator | Global routing, role activation, human communication, promotion judgment | No direct orchestration file writes |
| State Manager | Sole writer for `.agent-atelier/**`; validates and commits requests | `.agent-atelier/**` |
| Executor | Implements a claimed WI inside an isolated worktree | Product code, self-test output, request files/messages |
| Validator | Produces authoritative validation evidence for a candidate | `.agent-atelier/validation/**`, validation manifests, request files/messages |
| Reviewers | Interpret evidence and submit findings | Review findings only |
| Watchdog | Detects stale orchestration state and proposes limited safe recovery | No direct durable writes; recovery and alert commits still route through State Manager |
| PM | Product meaning, behavior spec, synthesis | `docs/product/**` |
| Architect | Decomposition, file ownership, merge/conflict handling | `docs/engineering/file-ownership.md`, request files/messages |

---

## 3. Source Of Truth

### 3.1 Durable State

The runtime must be recoverable from disk alone.

Required durable sources:

- `.agent-atelier/loop-state.json`
- `.agent-atelier/work-items.json`
- `.agent-atelier/attempts/**`
- `.agent-atelier/human-gates/**`
- `.agent-atelier/watchdog-jobs.json`
- `docs/product/behavior-spec.md`
- `git` commit graph for committed worktree progress
- `.agent-atelier/validation/**`

### 3.2 Write Ownership

Only one component may own each durable area:

- `.agent-atelier/**` (except `validation/`) → State Manager only (via `state-commit`)
- `.agent-atelier/validation/**` → Validator only (direct Write, not via `state-commit`)
- `docs/product/**` → PM only
- `docs/engineering/file-ownership.md` → Architect only
- Product code → Executor / Architect inside assigned worktrees only

The Validator writes manifests directly to `.agent-atelier/validation/<run-id>/` and then routes the orchestration state update (WI status transition) through State Manager via `state-commit`. Any other component must communicate intent through a request, not by editing the durable file directly.

---

## 4. Global Invariants

These are non-negotiable runtime rules.

1. There is exactly one active writer for orchestration state: State Manager.
2. A WI may be in `implementing` or `candidate_validating` only when it has a valid active lease.
3. Only one `active_candidate` may exist at a time.
4. A WI may not become `done` without required evidence references.
5. A validator may not read builder narrative, builder diffs, or architect interpretation.
6. Only Orchestrator may communicate with the human.
7. Watchdog may only perform mechanical, reversible orchestration-state recovery.
8. Product code and product meaning must never be changed by watchdog recovery.
9. All state-changing requests must be idempotent by `request_id`.
10. Every request that mutates orchestration state must include `based_on_revision`.

---

## 5. Request / Ack Contract

Every orchestration write follows the same pattern:

1. Caller creates a request payload.
2. Caller sends the request to State Manager via `write()` or CLI.
3. State Manager validates the request against the latest committed revision.
4. State Manager either:
   - commits the change and returns `ack`
   - rejects the change and returns `reject`
5. Callers must treat only the acked revision as committed truth.

### Request Model

The full SUR (State Update Request) schema is defined in [state-schemas.md §4](./state-schemas.md). It includes `request_id`, `requested_by`, `based_on_revision`, `operation`, `payload`, and `causation_id`.

In v1, skills expose only the two mechanically enforced fields as CLI flags:

- `--request-id` — idempotency key
- `--based-on-revision` — optimistic concurrency

The remaining fields (`requested_by`, `operation`, `causation_id`) are implicit: `requested_by` is the invoking role, `operation` is the subcommand name, and `causation_id` is not tracked in v1.

### Ack Output

Skills return:

- `request_id`
- `accepted`
- `committed_revision`
- `changed` — `true` if state was mutated, `false` on idempotent replay
- `artifacts` — list of files written

On idempotent replay, `replayed: true` is additionally returned.

### Reject Output

Skills reject via exit code (2 = stale revision, 1 = validation error) and return:

- `request_id`
- `accepted: false`
- `reason` — human-readable explanation

### V1 Enforcement Model

In v1, the request/ack contract is enforced at two layers:

- **Mechanical (state-commit)**: `based_on_revision` → optimistic concurrency via `expected_revision` checks. Stale revisions are rejected with exit code 2. WAL-based crash recovery ensures atomicity.
- **Prompt-level (skills)**: `request_id` idempotency, `requested_by`, and `causation_id` tracking are enforced by skill instructions. Each SKILL.md specifies `--request-id` and `--based-on-revision` as required flags and defines replay semantics.

V1 does **not** implement a persistent request journal. This means crash-then-replay-by-request-id cannot be mechanically guaranteed — it depends on the LLM re-reading state and honoring the skill's idempotency rules. A persistent journal is deferred until pilot evidence shows prompt-level enforcement is insufficient.

---

## 6. Evidence-Required Completion

Completion is a runtime contract, not a social convention.

A WI completion request must reference:

- the WI id
- at least one validation run id (via `--validation-manifest`)
- machine-readable evidence manifest refs (via `--evidence-ref`)
- the verification checks claimed as passed (via `--verify-check`)

Candidate branch/commit matching is validated upstream by the `validate record` skill (Phase 2 preconditions), not re-validated at completion.

The `execute complete` skill pre-validates that evidence ref paths exist on disk before routing the state update through `state-commit`. State-commit itself enforces only revision atomicity — evidence validation is the skill's responsibility.

---

## 7. Concurrency Model

### 7.1 Work Item Concurrency

- One WI has one active owner at a time.
- Ownership is represented by a lease.
- Losing the lease invalidates further heartbeats or completion requests from the old owner.

### 7.2 Candidate Concurrency

- Multiple WIs may become candidate-ready.
- Only one candidate may occupy `active_candidate`.
- Others are serialized into `candidate_queue` in FIFO order.
- `candidate activate` always pops the first entry from the queue.

### 7.3 Human-Gate Concurrency

- Human gates block only the affected WI set.
- Unblocked WIs continue independently.
- Gate resolution clears only the linked WI blocks.

---

## 8. Pilot Topology vs Full Topology

### Pilot Topology (Required First)

- Orchestrator
- State Manager
- Executor
- Independent Validator
- Watchdog

This is the minimum acceptable topology for implementation start.

### Full Topology (Expansion After Proof)

- Orchestrator
- State Manager
- PM
- Architect
- Executor pool
- Validator
- Reviewers
- Optional design roles

Expansion is allowed only after the pilot proves:

- crash recovery works
- completion requires evidence
- stale work is automatically recovered
- coordination cost stays inside budget

---

## 9. Non-Goals

This document does not define:

- prompt wording for each role
- product behavior acceptance criteria
- UI design rules
- business metric targets

Those belong in the other design and product documents.
