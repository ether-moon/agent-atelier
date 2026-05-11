---
name: execute
description: "Run the development loop end-to-end. Auto-runs plan cycle if no valid plan_approval exists; otherwise drives IMPLEMENT → VALIDATE → REVIEW_SYNTHESIS → AUTOFIX → DONE. Use when starting or resuming work after planning. Triggers on 'execute', 'run', 'go', 'start', 'continue', 'pick up where we left off'."
argument-hint: "(no args)"
---

# Execute -- Full Development Loop Entry Point

Single user-facing entry point for the autonomous development loop. Verifies plan approval (auto-runs the plan cycle if missing or invalidated), then spawns the team, restores monitors, and drives work items through implementation, validation, review, and completion.

Reference spec: `docs/superpowers/specs/2026-05-08-plan-execute-workflow-design.md` — sections "사용자 멘탈 모델", "호출별 동작 매트릭스", "Atomicity 요구", "state-commit Semantic Enforcement".

## When This Skill Runs

- User wants to start or resume the development loop
- After a session crash (cold resume)
- Continuing after `/agent-atelier:plan` produced an approval
- "Just go" — skill handles plan gate internally

## Prerequisites

- Git repository (skill auto-runs init helpers in Phase 0)
- Behavior spec at `docs/product/behavior-spec.md` (created/updated during plan cycle if absent)

## Allowed Tools

Read, Write, Bash, Glob, AskUserQuestion (during embedded plan flow), Agent (for team spawning), SendMessage, TaskCreate, TaskUpdate, CronCreate, CronDelete, CronList

## Examples

```
/agent-atelier:execute     # Start or resume the loop (plan gate enforced)
```

There is no `--mode` escape hatch — plan is never bypassed. To re-plan, run `/agent-atelier:plan` (which opens a new gate even with valid `plan_approval`).

## Phase 0: Plan Gate Check

This phase enforces the user invariant "execute never bypasses plan". The IMPLEMENT-mode gate is also mechanically enforced inside `state-commit` (caller cannot bypass), but this phase makes the gate user-visible.

1. **Bootstrap.** Detect repo root and plugin root, then run init helpers (idempotent — only creates missing files):
   ```bash
   repo=$(git rev-parse --show-toplevel)
   plugin_root="$repo/plugins/agent-atelier"
   bash "$plugin_root/scripts/init-helpers.sh" --root "$repo"
   ```

2. **Read state.** Load `.agent-atelier/loop-state.json` and `.agent-atelier/work-items.json`. Compute current plan-side hashes via `${plugin_root}/scripts/_plan_hash.py`:
   - `wi_plan_hash(items)` over `work-items.json` items
   - `spec_hash("docs/product/behavior-spec.md")` (returns string `"null"` when the file is missing)

3. **Compare to stored `loop-state.plan_approval`.**

   | Stored `plan_approval` | Current hashes vs stored | Action |
   |------------------------|--------------------------|--------|
   | `null` (or missing) | (irrelevant) | Invoke embedded plan flow |
   | non-null | `wi_plan_hash` mismatch OR `spec_hash` mismatch | Invoke embedded plan flow (plan invalidated) |
   | non-null | both hashes match | Skip to Phase 1 (Pre-Flight) |

4. **Invoke embedded plan flow.** Two equivalent paths (pick one — they produce the same end state):
   - **Inline:** Run all of `skills/plan/SKILL.md` Phases 1–5 here, with the same JSONL append rules and AskUserQuestion routing. Use the same active_plan_cycle_id semantics (resume if non-null, create new if null).
   - **Chain:** Set `loop-state.active_plan_cycle_id` (if null) and proceed into Phase 4 of the plan skill body. Re-enter Phase 0 of execute after the gate `y` transaction commits.

5. **Atomic gate transition for `/execute` context.** When the user picks `y` at the final gate, the state-commit transaction includes per spec "Atomicity 요구":
   - `plan_approval` object (with `approved_at`, `wi_plan_hash`, `spec_hash`, `approved_by: "user"`)
   - `mode: BUILD_PLAN → IMPLEMENT`
   - `active_plan_cycle_id: null`
   - `plan_gate: null`

   This single transaction is what `state-commit`'s mechanical IMPLEMENT gate validates: the transaction MUST contain a `plan_approval` whose `wi_plan_hash` and `spec_hash` match the values recomputed at commit time. If they don't, state-commit rejects with `implement_gate_violation`.

6. **After Phase 0 succeeds**, `loop-state.mode == "IMPLEMENT"`, no active plan cycle, no open plan gate. Original execute behavior takes over from Phase 1.

## Phase 1: Pre-Flight Check

1. **Read state.** Re-load `.agent-atelier/loop-state.json`, `.agent-atelier/work-items.json`, `.agent-atelier/watchdog-jobs.json` (state may have changed during Phase 0).
2. **WAL recovery.** If `.agent-atelier/.pending-tx.json` exists, replay it first:
   ```bash
   cat .agent-atelier/.pending-tx.json | "$plugin_root/scripts/state-commit" --root "$repo" --replay
   ```
   See `../../references/recovery-protocol.md`.
3. **Check for stale work.** Run a watchdog tick to recover stale leases or candidates from a previous session:
   ```bash
   bash "$plugin_root/scripts/watchdog" tick
   ```
   Still-valid `implementing` leases from a crashed runtime are reclaimed later by the startup resume sweep.
4. **Defer dashboard.** Do not present the startup dashboard if recovery is in progress; show it after the startup resume sweep so the user sees recovered state.

## Phase 2: Spawn Team

Create one flat team and spawn teammates. Full details in `reference/team-lifecycle.md`.

**Summary:** Derive a deterministic team name from the repo root, clean up stale teams, then spawn the three always-on core teammates (State Manager, PM, Architect) from the plugin's `agents/` definitions (scoped as `agent-atelier:<role>`). The Orchestrator role is played by the lead agent. Conditional specialists (Builders, VRM, reviewers) are spawned on-demand as work progresses.

After the team is running:
1. Start background monitors via `/agent-atelier:monitors spawn` (the `monitors` skill is a thin shim — see `../../references/monitor-runtime.md`).
2. Create monitor poll job. Schedule a `*/2 * * * *` cron to invoke `/agent-atelier:monitors check`.
3. Create watchdog recovery job. Schedule a `*/15 * * * *` cron to invoke `bash <plugin-root>/scripts/watchdog tick` + resume sweep.
4. Run the **startup resume sweep** -- reclaim stranded work, resume recoverable state, then present the startup dashboard

### Cron Prompt Substitution Rule

When this skill creates cron jobs via `CronCreate`, prompts MUST embed the **absolute** plugin root and any task-id mapping resolved at creation time. Do NOT leave `<plugin-root>` or `${CLAUDE_PLUGIN_ROOT}` as a placeholder in the prompt body — cron fires on a fresh subprocess that may not have the same env, and `${CLAUDE_PLUGIN_ROOT}` substitution does not happen at fire time.

Procedure (Bash) before `CronCreate`:

```bash
plugin_root_abs=$(realpath "$plugin_root")  # absolute, symlinks resolved
# Build prompt with literal absolute path, substituted at this moment:
poll_prompt="Read $plugin_root_abs/references/monitor-runtime.md and execute a check tick with task IDs {\"heartbeat\":\"$T1\",\"gate\":\"$T2\",\"events\":\"$T3\",\"divergence\":\"$T4\"}."
recovery_prompt="Run: bash $plugin_root_abs/scripts/watchdog tick. Then re-read $repo/.agent-atelier/loop-state.json and run the Orchestrator resume sweep."
```

Pass each `*_prompt` to `CronCreate` as the `prompt` argument verbatim. The fired cron run will see the absolute path even if env vars are unset.

### Startup Resume Sweep (Run Once After Team Spawn)

Scan all WIs with status `implementing` whose owner is unreachable. For each, requeue with reason `cold-resume: owner session unavailable`. This reclaims stranded work from a previous crashed runtime without waiting for a watchdog tick. Present the startup dashboard only after the sweep completes so the user sees recovered state.

## Phase 3: State Machine Loop

Drive work items through phases stored in `loop-state.json.mode`. Full phase details, transition rules, and review findings schema in `reference/state-machine.md`.

**Phase summary:**

| Phase | Actors | What Happens |
|-------|--------|-------------|
| DISCOVER | Orchestrator, PM | (Reached only via re-plan or `수정` gate response — typically owned by `/agent-atelier:plan`) |
| SPEC_DRAFT | PM, Architect | (Same — typically plan cycle territory) |
| SPEC_HARDEN | PM, Architect | (Same) |
| BUILD_PLAN | Architect | (Same — Phase 0 ends here on plan-approve, then atomic transition to IMPLEMENT) |
| IMPLEMENT | Builder(s) | Claim WIs, implement, produce candidates |
| VALIDATE | VRM | Validate candidate with evidence bundle |
| REVIEW_SYNTHESIS | QA, UX, PM | Independent review, PM synthesizes findings |
| AUTOFIX | Builder(s) | Fix review bugs, produce new candidate |
| DONE | Orchestrator | Cleanup team, report results, recommend next step |

**Key rules:**
- All transitions are explicit via State Manager — no implicit transitions
- IMPLEMENT and VALIDATE can overlap (Builder works next WI while VRM validates current)
- BUILD_PLAN → IMPLEMENT requires the mechanical plan-approval gate enforced by `state-commit` (in addition to the existing verify-array and complexity hard gates)
- VRM-passed candidates are evaluated for fast-track (skip review if simple + small diff + no sensitive paths)
- Invalid transitions are rejected by State Manager

### Lifecycle Script Calls (Replaces Old `/agent-atelier:execute` Slash Subcommands)

The OLD lifecycle (claim/heartbeat/requeue/complete/attempt) lives in `bash <plugin-root>/scripts/lifecycle <subcommand>` now. After invoking a mutating script, the caller (Orchestrator or State Manager) MUST process the `native_task_sync` hint in the script's stdout JSON by calling `TaskCreate` / `TaskUpdate` accordingly (single-writer model: script writes state files, LLM writes Agent Teams tasks).

Common patterns (run from State Manager teammate):

```bash
# Claim
bash "$plugin_root/scripts/lifecycle" claim WI-014 --owner-session-id exec-WI-014-1 --lease-minutes 90

# Heartbeat
bash "$plugin_root/scripts/lifecycle" heartbeat WI-014

# Requeue
bash "$plugin_root/scripts/lifecycle" requeue WI-014 --reason "stale-lease"

# Complete (with evidence)
bash "$plugin_root/scripts/lifecycle" complete WI-014 --manifest <path>

# Attempt (record failure)
echo '<attempt-json>' | bash "$plugin_root/scripts/lifecycle" attempt WI-014
```

Other migrated calls:

| Old slash | New script call |
|-----------|----------------|
| `/agent-atelier:wi list` | `bash "$plugin_root/scripts/wi" list` |
| `/agent-atelier:wi upsert <json>` | `bash "$plugin_root/scripts/wi" upsert <json>` |
| `/agent-atelier:gate list` | `bash "$plugin_root/scripts/gate" list` |
| `/agent-atelier:gate resolve HDR-NNN --chosen <opt>` | `bash "$plugin_root/scripts/gate" resolve HDR-NNN --chosen <opt>` |
| `/agent-atelier:watchdog tick` | `bash "$plugin_root/scripts/watchdog" tick` |
| `/agent-atelier:candidate enqueue WI-014 WI-015` | `bash "$plugin_root/scripts/candidate" enqueue WI-014 WI-015` |
| `/agent-atelier:candidate activate` | `bash "$plugin_root/scripts/candidate" activate` |
| `/agent-atelier:candidate clear --reason demoted` | `bash "$plugin_root/scripts/candidate" clear --reason demoted` |
| `/agent-atelier:validate record` | `bash "$plugin_root/scripts/validate" record` (manifest via stdin) |
| `/agent-atelier:monitors *` | **unchanged** — `monitors` is a thin shim, slash form is still the canonical caller for cron/orchestrator |

## Phase 4: Continuous Monitoring

Two concurrent monitoring mechanisms run alongside the state machine loop:

**Monitor polling (every ~2 min):** Cron invokes `/agent-atelier:monitors check` (the shim reads `references/monitor-runtime.md` and runs the procedure). Handles heartbeat warnings, gate resolutions, CI status events, and branch divergence alerts. Re-spawns dead monitors (escalates to user after 3 crashes). Silent when nothing to report.

**Watchdog recovery (every ~15 min):** Cron invokes `bash <plugin-root>/scripts/watchdog tick` for mechanical recovery (stale leases, expired candidates, budget enforcement), then runs an Orchestrator resume sweep (respawn missing teammates, dispatch Builders, requeue unreachable owners). Silent when nothing to recover.

**CI monitor (on-demand):** Spawned when entering VALIDATE with a CI run via `/agent-atelier:monitors spawn-ci --run-id <ID>`. Self-terminates on terminal CI state. Events picked up by monitor polling. On `ci_status` (success) → evaluate fast-track, then transition to IMPLEMENT or REVIEW_SYNTHESIS.

## Human Gate Protocol

1. Present the HDR to the user immediately (Orchestrator is sole communicator)
2. Continue all unblocked work — gates are non-blocking by default
3. When the user responds, resolve via `bash "$plugin_root/scripts/gate" resolve HDR-NNN --chosen <opt>`
4. Resume blocked WIs

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Loop completed — all WIs done |
| `1` | Usage error |
| `2` | Loop interrupted — user requested stop, OR plan-gate user-decline during Phase 0 |
| `4` | Runtime failure (state-commit reject including `implement_gate_violation`) |

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
  "issues": [],
  "plan_approval_used": {
    "approved_at": "...",
    "wi_plan_hash": "sha256:...",
    "spec_hash": "sha256:..."
  }
}
```

`recommended_next` values: `"run_validation"` (missing evidence), `"create_pr"` (unmerged feature branch), `"check_ci"` (PR exists, CI unknown), `null` (everything clean).

`issues` -- array of strings describing validation gaps or warnings. Empty when clean.

`plan_approval_used` echoes the active plan_approval object so log diffing can correlate runs to plan revisions.

## Error Handling

| Scenario | Recovery |
|----------|---------|
| Phase 0 plan-gate user declines | Exit 2, leave `active_plan_cycle_id` set so next `/execute` resumes |
| Phase 0 hashes mismatch | Re-enter plan flow inline (treat as plan-invalidated) |
| state-commit returns `implement_gate_violation` | Caller bug — stop, log error, do NOT retry blindly |
| Teammate crashes | Watchdog detects stale lease, requeues mechanically |
| Loop stuck | Budget checks flag before it becomes a problem |
| WI fails 3x (same fingerprint) | Escalate to human review |
| User interrupts | Save state, requeue active work, stop monitors, cancel cron jobs, report status |
| Monitor crashes | Polling detects dead monitor, Orchestrator re-spawns |
| Monitor crashes 3+ times | Escalate to user instead of retrying |
| Rate limit stalls team | Next watchdog pulse re-runs recovery and resume sweep |
| Lead dies before cron exists | Cold resume via `../../references/recovery-protocol.md`, then `/execute` recreates infrastructure |

## Constraints

- Orchestrator NEVER implements code directly except as last resort (all executors idle + single trivial fix)
- All orchestration writes route through State Manager teammate
- Information barrier between implementation and validation enforced at every phase boundary
- Success metrics inform routing but never become executable acceptance checks (see `../../references/success-metrics-routing.md`)
- Recovery from any crash follows `../../references/recovery-protocol.md`
- Plan is never bypassed — Phase 0's gate plus state-commit's mechanical IMPLEMENT-mode gate together enforce the user invariant
