# Agent-Atelier — Session-Limit Retry Design

**Date**: 2026-04-16
**Status**: Draft v1
**Scope**: Automatic recovery from temporary Claude session/rate limits while an orchestration loop is already running

---

## 1. Review Outcome

The attached proposal is directionally correct in three places:

- session limits should be treated as a runtime-wide stall, not a per-role incident
- a durable `rate_limit_pause` schema is unnecessary
- recovery should ride on an independent 15-minute watchdog pulse, not on user intervention

Two corrections are required against the current repository design:

1. The system already intends to have a 15-minute watchdog lane in `run/SKILL.md`; the missing piece is not "add a new concept" but "make the CronCreate contract explicit and operational."
2. A plain watchdog tick is not enough. `implementing` work items use 90-minute leases, so session-limit recovery must include a post-tick resume sweep that either recontacts the current owner or reclaims the work without waiting for lease expiry.

This document defines that missing contract.

---

## 2. Problem Statement

When Claude reports a session/rate-limit error, the current turn stops making forward progress. In practice this can affect:

- a Builder or VRM first, then the rest of the team shortly after
- the Orchestrator directly while managing the team

The repository already has two recovery ideas:

- a 2-minute monitor poll loop for fast event handling
- a 15-minute watchdog lane for mechanical recovery

What is not yet specified well enough is:

- where the 15-minute CronCreate job is created and cleaned up
- what the Orchestrator must do when that pulse fires after limits have cleared
- how to recover `implementing` work that still has a valid lease but no reachable owner

---

## 3. Design Goals

- Recover automatically after temporary session/rate limits without user prompts.
- Avoid new durable state unless it changes recovery decisions.
- Preserve the existing single-writer state model.
- Resume quickly after limits clear; do not wait for a 90-minute lease to expire when the owner session is gone.
- Keep crash recovery and session-limit recovery separate: session-limit recovery is for a still-running lead session; cold resume remains the answer for full session loss.

## 4. Non-Goals

- No persistent global cron created during `init`.
- No per-role or per-error `rate_limit_pause` object in `.agent-atelier/**`.
- No attempt to detect the exact role that hit the limit first.
- No guarantee of exact 15-minute timing; approximate idle-time retries are acceptable.

---

## 5. Core Decisions

### 5.1 Session Limit Is Treated As A Runtime-Wide Stall

The system assumes account-level limits. The first visible failure may come from any role, but recovery behavior is the same:

- do not persist a special paused mode
- do not send explicit "pause" commands
- let agents naturally idle or fail
- rely on the next successful watchdog pulse to resume orchestration

### 5.2 The Runtime Has Two Independent Cron Lanes

`run` must explicitly create and manage both jobs:

- `*/2 * * * *` — monitor poll lane
- `*/15 * * * *` — watchdog recovery pulse

The 15-minute lane is not a side note in prose. It is a first-class runtime handle with the same operational status as the monitor poll job.

### 5.3 No Schema Change

No new fields are required in:

- `loop-state.json`
- `work-items.json`
- `watchdog-jobs.json`

The existing state already contains the information needed for recovery:

- mode
- active candidate
- candidate queue
- WI status
- owner session id
- heartbeat and lease timestamps

### 5.4 Recovery Is Two-Step: Mechanical Tick, Then Resume Sweep

The 15-minute lane must do both:

1. run `/agent-atelier:watchdog tick`
2. run an Orchestrator-owned resume sweep

The watchdog remains mechanical and state-focused. The Orchestrator remains responsible for routing, respawning, and re-dispatch.

---

## 6. Runtime Topology

### 6.1 `run` Phase 2 Contract

`plugins/agent-atelier/skills/run/SKILL.md` should be tightened so Phase 2 explicitly does:

1. spawn monitors
2. create monitor poll CronCreate job
3. create watchdog recovery CronCreate job
4. store both cron job ids plus monitor task ids in session context

Cleanup must explicitly delete both cron jobs.

The run skill currently documents the 15-minute watchdog concept but does not operationally define the second CronCreate handle. This is the primary design gap.

### 6.2 Suggested Watchdog Pulse Prompt

The prompt injected by the 15-minute CronCreate lane should instruct the lead to:

1. run `/agent-atelier:watchdog tick`
2. read current `loop-state.json` and `work-items.json`
3. perform the resume sweep defined in Section 7
4. stay silent if no recovery or dispatch action is needed

This makes the pulse useful both for lease-based recovery and for post-limit reactivation.

---

## 7. Resume Sweep Algorithm

The resume sweep runs only in the Orchestrator context, immediately after a successful watchdog pulse.

### 7.1 Preconditions

- the lead session is alive enough to process the cron prompt
- `watchdog tick` completed or reported no-op
- current state files can be read successfully

### 7.2 Global Rules

- If mode is `DONE`, do nothing.
- If a human gate blocks all remaining work, do not fabricate progress.
- Prefer resuming existing ownership before reassigning.
- Stay silent on fully quiet ticks.

### 7.3 Core Team Availability

For core teammates required by the current mode:

- if they are alive and contactable, keep using them
- if they are gone, respawn them

This applies especially to:

- State Manager
- PM
- Architect

The intent is not to preserve agent identity across a limit event. The intent is to restore required control-plane capacity.

### 7.4 `ready` Work Items

For each `ready` WI:

- follow the normal Builder assignment flow
- claim through State Manager
- dispatch a Builder

No special session-limit logic is needed here.

### 7.5 `implementing` Work Items

This is the critical recovery path.

For each WI in `implementing`:

1. If the recorded `owner_session_id` is still reachable, message that owner to continue the existing WI. Do not mutate state.
2. If the owner is not reachable, or the send fails because the owner session no longer exists:
   - force requeue the WI immediately
   - clear the lease via the normal `execute requeue` path
   - set `last_requeue_reason` to `watchdog: owner session unavailable after recovery pulse`
   - increment `stale_requeue_count`
3. After requeue, treat the WI as normal `ready` work and dispatch a fresh Builder in the same sweep if capacity exists.

This is a mechanical recovery action. It does not require product judgment.

### 7.6 `candidate_validating` / Active Candidate

If `active_candidate` exists:

- if a VRM session is still reachable, instruct it to continue
- otherwise spawn a fresh VRM and instruct it to resume the active candidate

Do not demote a still-valid candidate solely because the previous VRM session disappeared. Candidate timeout rules remain the responsibility of `watchdog tick`.

### 7.7 `reviewing` Work Items

For each WI in `reviewing`:

- if required reviewers are alive, re-message them
- if reviewers are missing, re-spawn them
- if review state is missing on disk, re-initiate review according to the existing recovery protocol

### 7.8 Silent Outcome Rule

If the pulse results in all of the following:

- no watchdog recovery
- no teammate respawn
- no work-item requeue
- no WI dispatch
- no gate event requiring user output

then the Orchestrator should emit no visible message.

---

## 8. Interaction With Existing Recovery Rules

### 8.1 Cold Resume Still Handles Full Session Loss

If the lead session dies before or outside the cron-based recovery pulse, this design does not help. The answer remains:

- run cold resume
- start `/agent-atelier:run`, which recreates monitors and both cron jobs
- let `/agent-atelier:run` perform the one-time startup resume sweep for stranded `implementing` work

Session-limit retry is an in-session resilience layer, not a replacement for crash recovery.

### 8.2 Lease Semantics Are Narrowly Relaxed

Current lifecycle docs say a valid lease can continue only if the lease holder still exists. This design makes that rule operational:

- existence/contactability is checked during the resume sweep
- if the owner cannot be reached, the Orchestrator may requeue before lease expiry

Without this rule, session-limit retry conflicts with the 90-minute default Builder lease.

---

## 9. Required Documentation Changes

The design should be merged into these normative documents during implementation:

- `plugins/agent-atelier/skills/run/SKILL.md`
  - explicitly create the second CronCreate job
  - explicitly clean up both job ids
  - define the watchdog pulse prompt contract
- `plugins/agent-atelier/references/prompts/orchestrator.md`
  - add a "resume sweep after watchdog pulse" responsibility
  - define the `implementing` WI recovery rules
- `docs/design/agent-lifecycle.md`
  - clarify that a valid lease continues only while the owner remains reachable
  - allow early requeue when the owner is unavailable after a recovery pulse
- `docs/design/recovery-spec.md`
  - add session-limit recovery as a separate recovery class
- `plugins/agent-atelier/skills/watchdog/SKILL.md`
  - clarify that watchdog tick is the mechanical half of a larger recovery pulse, not the full resumption logic by itself

No schema document change is required.

---

## 10. Test Scenarios

Implementation should be considered complete only if these scenarios work:

1. A Builder hits a session limit, then the next watchdog pulse re-messages the same Builder and work continues without lease changes.
2. A Builder hits a session limit and the owner session no longer exists, then the next watchdog pulse requeues the WI immediately and assigns a fresh Builder.
3. The Orchestrator hits a session limit after cron jobs already exist, then the next watchdog pulse resumes routing without user input.
4. The Orchestrator dies before cron creation, then cold resume is required and session-limit retry is not falsely claimed as sufficient.
5. An active candidate survives a limit event and a fresh VRM can resume validation without demotion.
6. A fully healthy idle system produces no visible noise on watchdog pulses.

---

## 11. Summary

The correct design is not "add a new paused state." It is:

- make the existing 15-minute watchdog lane explicit
- treat it as a recovery pulse, not just a stale-lease checker
- follow every successful pulse with an Orchestrator resume sweep
- reclaim `implementing` work early when the recorded owner is no longer reachable

That keeps the runtime simple, avoids schema growth, and makes the 15-minute retry behavior materially effective.
