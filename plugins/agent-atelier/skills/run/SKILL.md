---
name: run
description: "Start the autonomous development loop — spawn the agent team, begin the orchestration state machine, and drive work items through the full lifecycle from DISCOVER to DONE. Use when the user says 'run', 'start', 'begin', 'launch the loop', 'start the team', 'run the development loop', or 'go'. This is the entry point for the entire agent-atelier system."
argument-hint: "[--mode <phase>]"
---

# Run — Orchestration Loop Entry Point

This skill starts the full autonomous development loop. It spawns the agent team, reads the current orchestration state, and drives work items through the development lifecycle.

## When This Skill Runs

- User wants to start or resume the development loop
- After a session crash (cold resume)
- After initialization (`/agent-atelier:init`)

## Prerequisites

- Orchestration must be initialized (`/agent-atelier:init`)
- A behavior spec must exist at `docs/product/behavior-spec.md`
- The user should have reviewed and approved the spec before launching

## Allowed Tools

- Read, Write, Bash, Glob, Agent (for team spawning), CronCreate, CronDelete

## Phase 1: Pre-Flight Check

1. **Read state.** Load `.agent-atelier/loop-state.json`, `.agent-atelier/work-items.json`, `.agent-atelier/watchdog-jobs.json`.
2. **WAL recovery.** If `.agent-atelier/.pending-tx.json` exists, replay it first (see `references/recovery-protocol.md`).
3. **Check for stale work.** Run a watchdog tick to recover any stale leases or candidates from a previous session.
4. **Report current state.** Show the user a status dashboard before proceeding.

## Phase 2: Spawn Team

Use Agent Teams to create one flat team for the development loop.

### Core Team (Always-On — 4 Roles)

Read the role prompts from `references/prompts/` and spawn teammates. Use Sonnet for every teammate:

```
spawnTeam("agent-atelier-dev")
```

Then spawn each core teammate with their prompt (specify `model="sonnet"` for each):

| Role | Prompt Source | Mode | Model |
|------|-------------|------|-------|
| State Manager | `references/prompts/state-manager.md` | `acceptEdits` | `sonnet` |
| PM | `references/prompts/pm.md` | `acceptEdits` | `opus` |
| Architect | `references/prompts/architect.md` | `acceptEdits` | `opus` |

The **Orchestrator** role is played by the lead agent (you) — do not spawn a separate teammate for it. Read `references/prompts/orchestrator.md` as your own operating guide. Orchestrator, PM, and Architect use Opus (judgment-heavy roles); all other teammates use Sonnet (execution-focused roles).

### Conditional Specialists (Spawned On-Demand)

| Role | When to Spawn | Prompt Source | When to Shutdown | Model |
|------|--------------|-------------|------------------|-------|
| Builder(s) | WI enters `ready` and BUILD_PLAN/IMPLEMENT phase | `references/prompts/builder.md` | After WI completion or requeue | `sonnet` |
| VRM | Candidate enters `active_candidate` | `references/prompts/vrm.md` | After evidence bundle produced | `sonnet` |
| QA Reviewer | REVIEW_SYNTHESIS phase begins | `references/prompts/qa-reviewer.md` | After findings submitted | `sonnet` |
| UX Reviewer | REVIEW_SYNTHESIS phase begins | `references/prompts/ux-reviewer.md` | After findings submitted | `sonnet` |

Spawn conditional roles with `Agent(team_name="agent-atelier-dev", model="sonnet", run_in_background=true)`.
Shut down via `requestShutdown` when their phase ends.

### Team Roster Injection

When spawning each teammate, append a `## TEAM ROSTER` section to the role prompt with the canonical names of all other active teammates and their roles. Example:

```markdown
## TEAM ROSTER

Your teammates in this session:
- **state-manager** — exclusive writer for .agent-atelier/ state files
- **pm** — spec owner, writes docs/product/
- **architect** — decomposes spec into work items

Send messages to teammates using their exact name above. Do not guess names.
```

When conditional specialists are spawned (Builder, VRM, reviewers), include the current full roster in their prompt AND broadcast the new teammate's name and role to all existing teammates via `write()`.

### Monitor Infrastructure

After spawning the team, start background monitors for continuous state observation:

1. **Spawn monitors.** Invoke `/agent-atelier:monitors spawn` — returns a JSON mapping of monitor names to background task IDs (heartbeat, gate, events, divergence).
2. **Create poll job.** Use `CronCreate` with cron `"*/2 * * * *"` (fires roughly every 2 minutes when idle). The prompt should invoke `/agent-atelier:monitors check` with the task ID mapping and follow the response protocol documented in the monitors skill.
3. **Store handles.** Keep the CronCreate job ID and the task ID mapping in conversation context for later cleanup. These are session-scoped — they do not survive restarts.

The monitors provide early warning (10–60 second detection) while the watchdog provides mechanical recovery (15-minute ticks). Both layers operate concurrently.

## Phase 3: State Machine Loop

Drive the development loop through these phases. The current phase is stored in `loop-state.json.mode`.

### Mode Transition Protocol

All mode transitions are explicit — the Orchestrator directs the State Manager to update `loop-state.json.mode` via `state-commit`. No implicit transitions.

**Valid transitions:**

| From | To | Trigger |
|------|----|---------|
| DISCOVER | SPEC_DRAFT | PM confirms spec ready for hardening |
| SPEC_DRAFT | SPEC_HARDEN | First complete draft exists |
| SPEC_HARDEN | BUILD_PLAN | Spec stable — no open challenges |
| BUILD_PLAN | IMPLEMENT | WIs created, at least one `ready` |
| IMPLEMENT | VALIDATE | `active_candidate` set |
| VALIDATE | REVIEW_SYNTHESIS | Validation passed |
| VALIDATE | IMPLEMENT | Validation failed |
| REVIEW_SYNTHESIS | AUTOFIX | Bugs found |
| REVIEW_SYNTHESIS | SPEC_DRAFT | Spec gaps found |
| REVIEW_SYNTHESIS | IMPLEMENT | Review clean — continue next WI |
| AUTOFIX | VALIDATE | New candidate produced |
| AUTOFIX | IMPLEMENT | Builder needs to re-implement (not just patch) |
| SPEC_HARDEN | SPEC_DRAFT | Spec fundamentally inadequate — needs rewrite |
| Any | DONE | All WIs `done` with evidence |

**Overlap:** IMPLEMENT and VALIDATE may be active concurrently — a Builder can work on the next WI while VRM validates the current candidate.

**Invalid transitions:** Any transition not in the table above is rejected. The State Manager must refuse the write and report the invalid pair.

### DISCOVER
- **Actors:** Orchestrator, PM
- **Activity:** PM reads/reviews the behavior spec, identifies gaps, updates open questions
- **Transition:** → SPEC_DRAFT when PM confirms spec is ready for hardening

### SPEC_DRAFT
- **Actors:** PM, Architect (consultation)
- **Activity:** PM drafts or revises the behavior spec with verifiable behaviors
- **Transition:** → SPEC_HARDEN when first complete draft exists

### SPEC_HARDEN
- **Actors:** PM, Architect (mutual auditing)
- **Activity:** Architect challenges spec, PM revises. Multiple rounds until both agree.
- **Transition:** → BUILD_PLAN when spec is stable (no open challenges)

### BUILD_PLAN
- **Actors:** Architect
- **Activity:** Architect decomposes spec into vertical-slice work items via `wi upsert`
- **Transition:** → IMPLEMENT when all WIs are created and at least one is `ready`

### IMPLEMENT
- **Actors:** Builder(s), Architect (support)
- **Activity:** Builders claim WIs, implement in worktrees, produce atomic commits
- **On candidate ready:** Builder signals completion → `candidate enqueue` → continue to next WI
- **Transition:** → VALIDATE when `active_candidate` is set (can overlap with ongoing implementation)

### VALIDATE
- **Actors:** VRM
- **Activity:** VRM runs full validation suite against `active_candidate`, produces evidence bundle
- **Information barrier:** VRM input from `build-vrm-prompt` only — no Builder context
- **On result:** `validate record` → if passed, → REVIEW_SYNTHESIS; if failed, → back to IMPLEMENT

### REVIEW_SYNTHESIS
- **Actors:** QA Reviewer, UX Reviewer, PM
- **Activity:**
  1. Reviewers independently assess evidence bundle (first-pass)
  2. PM synthesizes findings and initiates debate if needed
  3. PM classifies each finding: `bug` | `spec_gap` | `ux_polish` | `product_level_change`
  4. Orchestrator cross-verifies PM's classification
- **On result:** Bugs → AUTOFIX; spec gaps → back to SPEC_DRAFT; product changes → human gate; polish → log for later; review clean → back to IMPLEMENT (continue next WI)

### AUTOFIX
- **Actors:** Builder(s)
- **Activity:** Fix bugs identified in review, produce new candidate
- **Transition:** → VALIDATE with new candidate (loop until clean)

### Review Findings Persistence

Review findings are persisted to disk so they survive cold resume and session crashes. This is the source of truth for review state recovery.

**Path:** `.agent-atelier/reviews/<WI-ID>/findings.json`

**Schema:**

```json
{
  "work_item_id": "WI-014",
  "findings": [
    {
      "id": "F-WI014-01",
      "source": "qa-reviewer | ux-reviewer",
      "severity": "critical | major | minor",
      "classification": "bug | spec_gap | ux_polish | product_level_change",
      "summary": "One-sentence description of the finding",
      "evidence_refs": [".agent-atelier/validation/RUN-.../manifest.json"],
      "disposition": "open | fixed | deferred | wontfix"
    }
  ],
  "synthesis": {
    "classified_by": "pm",
    "classified_at": "2026-04-08T15:30:00Z",
    "cross_verified_by": "orchestrator"
  }
}
```

On cold resume, the Orchestrator reads this file to restore review state. If a WI is in `reviewing` status but no `findings.json` exists, the review must be re-initiated from the REVIEW_SYNTHESIS phase.

### DONE
- All WIs complete with evidence. Report results to user.
- **Monitor cleanup:** Stop all monitors via `/agent-atelier:monitors stop all`. Cancel the CronCreate poll job via `CronDelete` with the stored job ID.
- `cleanup` the team resources.

## Phase 4: Continuous Monitoring

Monitoring runs concurrently with the state machine loop via two mechanisms:

### CronCreate Polling (Every ~2 Minutes)

The poll job created in Phase 2 fires when the REPL is idle. On each tick:

1. Invoke `/agent-atelier:monitors check` with the stored task ID mapping.
2. **IMMEDIATE events** — act within this polling cycle:
   - `heartbeat_warning` (expired) → trigger `/agent-atelier:watchdog tick`
   - `heartbeat_warning` (warning) → message Builder via `write()` to send `execute heartbeat`
   - `gate_resolved` → re-read gate state, resume blocked WIs
   - `gate_opened` → present HDR to user immediately
   - `ci_status` (success) → proceed with VALIDATE → REVIEW_SYNTHESIS transition
   - `ci_status` (failure/cancelled) → record validation failure, candidate demotion
   - `branch_divergence` (critical) → inform user, strongly recommend rebase
3. **WARNING events** — log for next human-visible status report.
4. **Dead monitors** — re-spawn via `/agent-atelier:monitors spawn`. If same monitor has died 3+ times, escalate to user.
5. **Silent ticks.** If the check report contains 0 IMMEDIATE events, 0 WARNING events, 0 dead monitors, and no state changes since the last tick — produce no user-visible output. The Orchestrator should not print "all healthy, 0 events" messages. Only report when there is something to act on or escalate.

### Watchdog Ticks (Every 15 Minutes or at Phase Transitions)

Run `/agent-atelier:watchdog tick` for mechanical recovery independent of monitors:
- Stale lease requeue
- Expired candidate clearing and next-candidate promotion
- Budget enforcement
- Long-open gate warnings

### CI Monitor (On-Demand)

When entering VALIDATE mode and triggering a CI run, spawn a ci-status monitor: `/agent-atelier:monitors spawn-ci --run-id <ID>` (or `--pr <NUM>`). The ci-status monitor self-terminates when CI reaches a terminal state. The CronCreate polling picks up the `ci_status` event and triggers the appropriate phase transition.

## Human Gate Protocol

When a gate is opened (`gate open`):
1. Present the HDR to the user immediately (Orchestrator is sole communicator)
2. Continue all unblocked work — gates are non-blocking by default
3. When the user responds, resolve via `gate resolve`
4. Resume blocked WIs

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Loop completed — all WIs done |
| `1` | Usage error |
| `2` | Loop interrupted — user requested stop |
| `4` | Runtime failure |

## Output Contract

Returns JSON to stdout on completion:

```json
{
  "completed": true,
  "work_items_done": 5,
  "work_items_total": 5,
  "human_gates_resolved": 2,
  "validation_runs": 7,
  "mode": "DONE"
}
```

## Error Handling

- If a teammate crashes: the watchdog detects stale leases and recovers mechanically
- If the loop gets stuck: budget checks flag it before it becomes a problem
- If a WI fails repeatedly (3x same fingerprint): escalate to human review
- If the user interrupts: save state, requeue active work, stop monitors, cancel poll job, report status
- If a monitor crashes: CronCreate polling detects it via dead-monitor report → orchestrator re-spawns
- If same monitor crashes 3+ times in a session: escalate to user instead of retrying

## Constraints

- The Orchestrator (lead) NEVER implements code directly except as a last resort (all executors idle + single trivial fix)
- All orchestration writes route through State Manager teammate
- The information barrier between implementation and validation is enforced at every phase boundary
- Success metrics inform routing decisions but never become executable acceptance checks (see `references/success-metrics-routing.md`)
- Recovery from any crash follows `references/recovery-protocol.md`
