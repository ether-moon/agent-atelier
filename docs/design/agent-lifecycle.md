# Agent-Atelier — Agent Lifecycle

**Date**: 2026-04-08
**Status**: Draft v1
**Scope**: Runtime behavior over time for agents, leases, and candidates

---

## 1. Lifecycle Model

The system uses short-lived workers with durable state.

- agents are disposable
- orchestration state is durable
- leases, not memory, determine current ownership

This model allows session restarts and crash recovery without relying on conversation history.

---

## 2. Session Identity

Every spawned runtime participant must have a stable session id for the duration of its task.

Examples:

- `orch-20260408-001`
- `state-20260408-001`
- `exec-WI-014-02`
- `vrm-WI-014-01`

Session ids are written into durable state only where ownership or auditability matters.

---

## 3. Work Item Lifecycle

### 3.1 Claim

Preconditions:

- WI status is `ready`
- no active unexpired lease exists

On claim:

- State Manager sets `status = implementing`
- sets `owner_session_id`
- sets `last_heartbeat_at`
- sets `lease_expires_at`

### 3.2 Heartbeat

The lease holder must periodically renew the lease.

Heartbeat rules:

- only current lease holder may heartbeat
- heartbeat extends `lease_expires_at`
- stale heartbeat from old session is rejected

### 3.3 Yield Or Requeue

If the worker cannot continue safely:

- it appends an attempt entry
- requests a transition back to `ready` or `pending`
- clears lease ownership

Requeue supports any non-terminal status including `reviewing`. When requeuing from `reviewing` (e.g., AUTOFIX cycle after review findings), promotion metadata is additionally cleared (`candidate_branch`, `candidate_commit`, `promotion.status` → null) because the current candidate is invalid.

### 3.4 Candidate Ready

When self-tests pass and the worker has a candidate commit:

- worker requests `candidate_queued`
- includes branch and commit metadata
- clears active implementation lease

### 3.5 Done

A WI becomes `done` only after:

- validator has produced evidence
- required review/synthesis has happened
- State Manager has accepted the completion request

---

## 4. Validator Lifecycle

### 4.1 Activation

Validator may start only when:

- WI is `candidate_validating`
- WI is the current `active_candidate`

### 4.2 Execution

Validator:

- reads WI/spec/verification input only
- writes validation artifacts
- records run manifest

### 4.3 Timeout

If validation exceeds `candidate_timeout_minutes` (default 30) without producing a manifest:

- watchdog detects via `candidate_activated_at` timestamp in `loop-state.json`
- watchdog demotes the candidate: clears `active_candidate`, returns WI to `ready`
- next candidate in the FIFO queue is activated

### 4.4 Finish

Validator requests one of:

- `reviewing` if validation passed
- demotion if validation failed — `validate record` updates work-items.json only (status → `ready`, promotion cleared, `promotion.status` → `demoted`). Loop-state cleanup (`active_candidate` → null) is **not** validate's responsibility — the Orchestrator calls `candidate clear --reason demoted` separately.
- environment-error escalation if tooling failed in a non-code way (WI stays `candidate_validating`)

---

## 5. Reviewer Lifecycle

Reviewers are spawned per validation cycle.

Rules:

- read only the evidence bundle
- submit first-pass findings before reading peer findings
- exit after synthesis is complete

Reviewers do not own leases on work items.

---

## 6. Human Gate Lifecycle

### Open

When a gate opens:

- State Manager writes HDR
- affected WI statuses become `blocked_on_human_gate`
- unaffected WI execution continues

### Resolve

When the human answers:

- State Manager updates HDR resolution
- affected WIs are restored to `ready`
- Orchestrator routes them to `resume_target`

---

## 7. Lease Policy

### Default Lease Durations

- executor: 90 minutes
- validator: 30 minutes
- reviewer synthesis expectation: 30 minutes

### Lease Loss

The lease is lost when:

- `lease_expires_at` passes
- State Manager explicitly clears ownership
- watchdog demotes or requeues the WI

After lease loss, the old holder must be treated as read-only and must not be allowed to complete the WI.

---

## 8. Candidate Lifecycle

1. executor produces candidate branch / commit
2. candidate is queued
3. State Manager promotes one queued candidate to `active_candidate`
4. validator runs on the active candidate
5. candidate either:
   - advances to review / completion
   - is demoted back to implementation due to findings
   - is re-queued or cleared by watchdog if validation stalls

Demotion responsibility split: `validate record` handles work-items.json (WI status and promotion metadata); `candidate clear --reason demoted` handles loop-state.json (active_candidate slot). The `candidate clear` demoted path is idempotent — if validate has already demoted the WI, candidate clear skips the WI write and only clears the loop-state slot.

---

## 9. Crash Resume Lifecycle

Cold-start resume algorithm:

1. read `loop-state.json`
2. read `work-items.json`
3. read open HDR files
4. read outstanding validation manifests
5. read review findings (`.agent-atelier/reviews/<WI-ID>/findings.json`) — if a WI is in `reviewing` status, this file is the source of truth for review state recovery. If absent, re-initiate from REVIEW_SYNTHESIS.
6. read watchdog state
7. classify every WI:
   - valid active lease -> continue only if lease holder still exists
   - expired lease -> requeue
   - blocked gate -> keep blocked
   - active candidate without validator progress -> watchdog policy
8. spawn fresh runtime participants
9. continue from committed state only

Uncommitted worktree code is explicitly non-authoritative.

---

## 10. Escalation Thresholds

Escalate to Orchestrator when:

- same finding fingerprint repeats 3 times
- same WI is watchdog-requeued more than 2 times
- validator reports `environment_error`
- stale write conflicts repeat without progress
- gate resolution would invalidate multiple in-flight WIs

---

## 11. Non-Goals

This document does not define prompt copy or product decisions. It defines runtime sequencing only.
