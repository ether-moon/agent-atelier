---
name: run
description: "Start the autonomous development loop -- spawn the agent team, begin the orchestration state machine, and drive work items through the full lifecycle from DISCOVER to DONE. Use when the user says 'run', 'start', 'begin', 'launch the loop', 'start the team', 'run the development loop', 'go', 'pick up where we left off', or 'kick it off'. This is the entry point for the entire agent-atelier system."
argument-hint: "[--mode <phase>]"
---

# Run -- Orchestration Loop Entry Point

Starts the full autonomous development loop. Spawns the agent team, reads orchestration state, and drives work items through the development lifecycle.

## When This Skill Runs

- User wants to start or resume the development loop
- After a session crash (cold resume)
- After initialization (`/agent-atelier:init`)

## Prerequisites

- Orchestration initialized (`/agent-atelier:init`)
- Behavior spec exists at `docs/product/behavior-spec.md`
- User has reviewed and approved the spec

## Allowed Tools

Read, Write, Bash, Glob, Agent (for team spawning), CronCreate, CronDelete, CronList

## Examples

```
/agent-atelier:run                  # Start or resume the loop
/agent-atelier:run --mode IMPLEMENT # Resume directly into IMPLEMENT phase
```

On a clean start, the loop begins at DISCOVER and drives through to DONE. On cold resume after a crash, the loop reads persisted state and picks up where it left off -- stranded work is reclaimed, monitors are recreated, and the startup dashboard shows recovered state.

## Phase 1: Pre-Flight Check

1. **Read state.** Load `.agent-atelier/loop-state.json`, `.agent-atelier/work-items.json`, `.agent-atelier/watchdog-jobs.json`.
2. **WAL recovery.** If `.agent-atelier/.pending-tx.json` exists, replay it first (see `references/recovery-protocol.md`).
3. **Check for stale work.** Run a watchdog tick to recover stale leases or candidates from a previous session. Still-valid `implementing` leases from a crashed runtime are reclaimed later by the startup resume sweep.
4. **Defer dashboard.** Do not present the startup dashboard if recovery is in progress; show it after the startup resume sweep so the user sees recovered state.

## Phase 2: Spawn Team

Create one flat team and spawn teammates. Full details in `reference/team-lifecycle.md`.

**Summary:** Derive a deterministic team name from the repo root, clean up stale teams, then spawn the three always-on core teammates (State Manager, PM, Architect) from `.claude/agents/` definitions. The Orchestrator role is played by the lead agent. Conditional specialists (Builders, VRM, reviewers) are spawned on-demand as work progresses.

After the team is running:
1. Start background monitors via `/agent-atelier:monitors spawn`
2. Create a monitor poll cron job (`*/2 * * * *`)
3. Create a watchdog recovery cron job (`*/15 * * * *`)
4. Run the **startup resume sweep** -- reclaim stranded work, resume recoverable state, then present the startup dashboard

## Phase 3: State Machine Loop

Drive work items through phases stored in `loop-state.json.mode`. Full phase details, transition rules, and review findings schema in `reference/state-machine.md`.

**Phase summary:**

| Phase | Actors | What Happens |
|-------|--------|-------------|
| DISCOVER | Orchestrator, PM | PM reviews behavior spec, identifies gaps |
| SPEC_DRAFT | PM, Architect | PM drafts verifiable behaviors |
| SPEC_HARDEN | PM, Architect | Mutual auditing until spec is stable |
| BUILD_PLAN | Architect | Decompose spec into work items (`wi upsert`) |
| IMPLEMENT | Builder(s) | Claim WIs, implement, produce candidates |
| VALIDATE | VRM | Validate candidate with evidence bundle |
| REVIEW_SYNTHESIS | QA, UX, PM | Independent review, PM synthesizes findings |
| AUTOFIX | Builder(s) | Fix review bugs, produce new candidate |
| DONE | Orchestrator | Cleanup team, report results, recommend next step |

**Key rules:**
- All transitions are explicit via State Manager -- no implicit transitions
- IMPLEMENT and VALIDATE can overlap (Builder works next WI while VRM validates current)
- BUILD_PLAN -> IMPLEMENT requires two hard gates: all WIs have `verify.length >= 1` and non-null `complexity`
- VRM-passed candidates are evaluated for fast-track (skip review if simple + small diff + no sensitive paths)
- Invalid transitions are rejected by State Manager

## Phase 4: Continuous Monitoring

Two concurrent monitoring mechanisms run alongside the state machine loop:

**Monitor polling (every ~2 min):** Invokes `/agent-atelier:monitors check`. Handles heartbeat warnings, gate resolutions, CI status events, and branch divergence alerts. Re-spawns dead monitors (escalates to user after 3 crashes). Silent when nothing to report.

**Watchdog recovery (every ~15 min):** Invokes `/agent-atelier:watchdog tick` for mechanical recovery (stale leases, expired candidates, budget enforcement), then runs an Orchestrator resume sweep (respawn missing teammates, dispatch Builders, requeue unreachable owners). Silent when nothing to recover.

**CI monitor (on-demand):** Spawned when entering VALIDATE with a CI run. Self-terminates on terminal CI state. Events picked up by monitor polling.

## Human Gate Protocol

1. Present the HDR to the user immediately (Orchestrator is sole communicator)
2. Continue all unblocked work -- gates are non-blocking by default
3. When the user responds, resolve via `gate resolve`
4. Resume blocked WIs

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Loop completed -- all WIs done |
| `1` | Usage error |
| `2` | Loop interrupted -- user requested stop |
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
  "mode": "DONE",
  "recommended_next": "create_pr",
  "issues": []
}
```

`recommended_next` values: `"run_validation"` (missing evidence), `"create_pr"` (unmerged feature branch), `"check_ci"` (PR exists, CI unknown), `null` (everything clean).

`issues` -- array of strings describing validation gaps or warnings. Empty when clean.

## Error Handling

| Scenario | Recovery |
|----------|---------|
| Teammate crashes | Watchdog detects stale lease, requeues mechanically |
| Loop stuck | Budget checks flag before it becomes a problem |
| WI fails 3x (same fingerprint) | Escalate to human review |
| User interrupts | Save state, requeue active work, stop monitors, cancel cron jobs, report status |
| Monitor crashes | Polling detects dead monitor, Orchestrator re-spawns |
| Monitor crashes 3+ times | Escalate to user instead of retrying |
| Rate limit stalls team | Next watchdog pulse re-runs recovery and resume sweep |
| Lead dies before cron exists | Cold resume via `references/recovery-protocol.md`, then `/run` recreates infrastructure |

## Constraints

- Orchestrator NEVER implements code directly except as last resort (all executors idle + single trivial fix)
- All orchestration writes route through State Manager teammate
- Information barrier between implementation and validation enforced at every phase boundary
- Success metrics inform routing but never become executable acceptance checks (see `references/success-metrics-routing.md`)
- Recovery from any crash follows `references/recovery-protocol.md`
