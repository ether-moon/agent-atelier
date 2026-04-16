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

- Read, Write, Bash, Glob, Agent (for team spawning), CronCreate, CronDelete, CronList

## Phase 1: Pre-Flight Check

1. **Read state.** Load `.agent-atelier/loop-state.json`, `.agent-atelier/work-items.json`, `.agent-atelier/watchdog-jobs.json`.
2. **WAL recovery.** If `.agent-atelier/.pending-tx.json` exists, replay it first (see `references/recovery-protocol.md`).
3. **Check for stale work.** Run a watchdog tick to recover any stale leases or candidates from a previous session. This is the mechanical half only — still-valid `implementing` leases from a crashed runtime are reclaimed later by the startup resume sweep after the core team exists again.
4. **Prepare the status snapshot.** Do not present the startup dashboard yet if recovery is in progress; show it after the startup resume sweep so the user sees recovered state rather than stale ownership.

## Phase 2: Spawn Team

Use Agent Teams to create one flat team for the development loop.

### Core Team (Always-On — 4 Roles)

Create the team and spawn teammates using subagent definitions from `.claude/agents/`:

Derive the team name from the git repository root:

```bash
root=$(git rev-parse --show-toplevel)
base=$(basename "$root" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-20)
hash=$(printf '%s' "$root" | shasum -a 256 | cut -c1-8)
team_name="atelier-${base}-${hash}"
```

Sanitization: lowercase → replace `[^a-z0-9_-]` with `-` → collapse consecutive `-` → strip leading/trailing `-` → then truncate to 20 chars.

Examples (illustrative — hashes depend on full absolute path): `/Users/ether/.../lahore` → `atelier-lahore-a3f2b1c9`, `/Users/ether/.../karrot-tms` → `atelier-karrot-tms-7b1e4d08`.

Before creating the team, check for a stale team with the same name. If `~/.claude/teams/<team_name>/` exists:

1. Try `TeamDelete` to remove it cleanly.
2. If `TeamDelete` fails (e.g., stale members from a crashed session), force-remove with a safety guard:
   ```bash
   if [[ -n "$team_name" && "$team_name" == atelier-* ]]; then
     rm -rf "$HOME/.claude/teams/$team_name/"
     rm -rf "$HOME/.claude/tasks/$team_name/"
   else
     echo "Refusing cleanup: invalid team_name '$team_name'" >&2
   fi
   ```

Then create the team:

```text
TeamCreate(team_name=<team_name>, description="Autonomous product development loop")
```

After team creation, persist the derived team name to loop-state via `state-commit` directly (State Manager is not yet spawned): set `team_name` to the derived value. This allows hooks and cleanup verification to locate team resources without hardcoding.

Then spawn each core teammate by referencing their agent type:

| Role | Agent Type | Mode | Model | Key Tool Differences |
|------|-----------|------|-------|---------------------|
| State Manager | `state-manager` | `acceptEdits` | `sonnet` | Bash (for state-commit) but no Write/Edit |
| PM | `pm` | `acceptEdits` | `opus` | Write/Edit (for docs) but no Bash |
| Architect | `architect` | `acceptEdits` | `opus` | Write/Edit (for docs) but no Bash |

Spawn with: `"Spawn a teammate using the state-manager agent type"` (etc. for each role). The agent definition's `model` and `tools` fields are applied automatically. The role prompt body from `references/prompts/` is appended as additional instructions.

The **Orchestrator** role is played by the lead agent (you) — do not spawn a separate teammate for it. Read `references/prompts/orchestrator.md` as your own operating guide. Orchestrator, PM, and Architect use Opus (judgment-heavy roles); all other teammates use Sonnet (execution-focused roles).

### Conditional Specialists (Spawned On-Demand)

| Role | Agent Type | When to Spawn | When to Shutdown | Model |
|------|-----------|--------------|------------------|-------|
| Builder(s) | `builder` | WI enters `ready` and BUILD_PLAN/IMPLEMENT phase | After WI completion or requeue | `sonnet` |
| VRM | `vrm` | Candidate enters `active_candidate_set` | After evidence bundle produced | `sonnet` |
| QA Reviewer | `qa-reviewer` | REVIEW_SYNTHESIS phase begins | After findings submitted | `sonnet` |
| UX Reviewer | `ux-reviewer` | REVIEW_SYNTHESIS phase begins | After findings submitted | `sonnet` |

Spawn conditional roles by referencing agent type: `"Spawn a teammate using the builder agent type to implement WI-014"`.
Shut down via `SendMessage({type: "shutdown_request"})` when their phase ends.

> **Note:** `skills` and `mcpServers` frontmatter in subagent definitions are NOT applied when running as a teammate (known limitation). Teammates load skills and MCP servers from project settings. The `tools` allowlist and role prompt body ARE applied.

### Builder Spawn Policy

When spawning a Builder for a work item, check the WI's `complexity` field in `work-items.json`:

- **`null`**: Complexity not yet set. The Architect must set it before the WI can proceed. If encountered at spawn time, reject with an error directing the Architect to set complexity.
- **`simple`**: Spawn with `mode: "acceptEdits"`. Builder implements immediately.
- **`complex`**: Spawn with `mode: "plan"`. The Builder starts in read-only plan mode — Write/Edit tools are blocked by the harness. The Builder proposes a plan, calls `ExitPlanMode`, which sends a structured `plan_approval_request` to the Orchestrator. After `plan_approval_response(approve: true)`, the Builder's permission mode auto-transitions to `bypassPermissions` for implementation.

For complex WIs: `"Spawn a teammate using the builder agent type to implement WI-014"` with `mode: "plan"`. The plan approval flow is mechanical — no prompt instruction needed. See the Orchestrator's Plan Review Protocol for approval criteria.

> **Why `mode: "plan"` and not prompt instructions?** Empirically verified: prompt-only plan approval produces plain text plans without structured messaging. Only `mode: "plan"` triggers the `ExitPlanMode` → `plan_approval_request` → `plan_approval_response` protocol that the Orchestrator can process programmatically.

### TeammateIdle Auto-Assignment

The `TeammateIdle` hook (`on-teammate-idle.sh`) automatically detects when a teammate is about to go idle and feeds back role-appropriate guidance. This eliminates the ~2 minute polling delay for work assignment:

- **Builders:** Always allowed to go idle (exit 0). The Orchestrator receives the idle notification and dispatches work via `SendMessage`. Builders never receive exit 2 (keep working) feedback — this prevents unbreakable idle loops where the agent becomes unresponsive to team lead commands.
- **VRM:** Directed to the active candidate for validation
- **Reviewers:** Directed to WIs in `reviewing` status during REVIEW_SYNTHESIS
- **Core team (SM, PM, Architect):** Kept alive while orchestration is active in their relevant phases

If no work is available for the teammate's role, the hook allows idle (exit 0) and the teammate shuts down gracefully.

**Builder claim flow:** Builder idle → Orchestrator receives idle notification → Orchestrator evaluates `work-items.json` for `ready` WIs → Orchestrator directs SM to call `/agent-atelier:execute claim` → SM writes state → Orchestrator dispatches Builder via `SendMessage`. This prevents both phantom claims (Builders self-serving) and idle loops (exit 2 feedback trapping agents).

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

When conditional specialists are spawned (Builder, VRM, reviewers), include the current full roster in their prompt AND broadcast the new teammate's name and role to all existing teammates via `SendMessage`.

### Monitor Infrastructure

After spawning the team, start background monitors for continuous state observation:

1. **Spawn monitors.** Invoke `/agent-atelier:monitors spawn` — returns a JSON mapping of monitor names to background task IDs (heartbeat, gate, events, divergence).
2. **Create monitor poll job.** Use `CronCreate` with cron `"*/2 * * * *"` (fires roughly every 2 minutes when idle). The prompt should invoke `/agent-atelier:monitors check` with the task ID mapping and follow the response protocol documented in the monitors skill.
3. **Create watchdog recovery job.** Use `CronCreate` with cron `"*/15 * * * *"` (fires roughly every 15 minutes when idle). The prompt should:
   - invoke `/agent-atelier:watchdog tick`
   - re-read `loop-state.json` and `work-items.json`
   - run the Orchestrator resume sweep for teammate respawn, work re-dispatch, and early recovery of unreachable owners
   - stay silent if no recovery or dispatch action is needed
4. **Store handles.** Keep both CronCreate job IDs and the task ID mapping in conversation context for later cleanup. These are session-scoped — they do not survive restarts.

The monitors provide early warning (10–60 second detection) while the watchdog provides mechanical recovery (15-minute ticks). Both layers operate concurrently.

### Startup Resume Sweep (Run Once After Team Spawn)

After the core team and monitor infrastructure are restored, run one immediate resume sweep before entering the steady-state loop. This sweep is required on every `/agent-atelier:run`; on a clean start it should be a no-op.

1. Re-read `loop-state.json` and `work-items.json`.
2. Apply the same routing rules as the watchdog recovery pulse, with one cold-resume override:
   - any WI that was already `implementing` when this `/run` invocation began is presumed stranded from the previous runtime
   - reclaim it immediately through State Manager with reason `cold-resume: owner session unavailable`
   - do not wait for lease expiry
3. Resume other recoverable work from durable state:
   - `ready` → follow the normal Builder claim and dispatch flow
   - `active_candidate` / `candidate_validating` → re-message a reachable VRM or spawn a fresh VRM and continue validation without demotion
   - `reviewing` → re-message reachable reviewers or respawn them from persisted review artifacts
   - if CI was already running for the active candidate, recreate the ci-status monitor if needed
4. Only after this sweep completes, present the startup status dashboard and continue into the normal orchestration loop.

### Active Worktree Hygiene

During an active loop, `.agent-atelier/**` is live runtime state. Do not treat it like ordinary dirty git state.

- Never use `git checkout`, `git restore`, `git stash`, or `git clean` on `.agent-atelier/**`
- Never stash or revert teammate-owned WIP just to make your own commit easier
- If you need a narrow commit, stage only the files you own with explicit pathspecs
- If runtime state appears corrupted, recover through State Manager, watchdog, or the recovery protocol — not git cleanup commands

For incident reporting during the loop, separate:

- **Confirmed facts** — direct observations from logs, state, or command output
- **Hypotheses** — likely causes that still need confirmation
- **Next actions** — the immediate safe step you will take

This keeps recovery decisions grounded and reduces accidental state destruction during fast triage.

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
| IMPLEMENT | VALIDATE | `active_candidate_set` set |
| VALIDATE | IMPLEMENT | VRM passed + fast-track conditions met → skip review |
| VALIDATE | REVIEW_SYNTHESIS | VRM passed + fast-track not met → full review |
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
- **Verify hard gate:** Before transitioning to IMPLEMENT, verify ALL `ready` WIs have `verify.length >= 1`. If any WI has an empty verify array, reject the transition and report the WI IDs. The Architect must add verify items before the loop can proceed.
- **Complexity requirement:** The Architect must set `complexity` on every WI (default is `null`). WIs with `null` complexity cannot qualify for fast-track review.
- **Transition:** → IMPLEMENT when all WIs are created, at least one is `ready`, and the verify hard gate passes

### IMPLEMENT
- **Actors:** Builder(s), Architect (support)
- **Activity:** Builders claim WIs, implement in worktrees, produce atomic commits
- **On candidate ready:** Builder signals completion → `candidate enqueue` → continue to next WI
- **Transition:** → VALIDATE when `active_candidate_set` is set (can overlap with ongoing implementation)

### VALIDATE
- **Actors:** VRM
- **Activity:** VRM runs full validation suite against `active_candidate_set`, produces evidence bundle
- **Information barrier:** VRM input from `build-vrm-prompt` only — no Builder context
- **On result:** `validate record` → if passed, evaluate fast-track; if failed, → back to IMPLEMENT

#### Fast-Track Review

When VRM passes, check whether the candidate set qualifies for fast-track (skip REVIEW_SYNTHESIS). **ALL conditions must be met** (per-batch, conservative):

1. Every WI in `active_candidate_set` has `complexity == "simple"`
2. VRM `status == "passed"`
3. Total diff (from candidate branch) is ≤ 30 lines
4. No WI's `owned_paths` contains auth, payment, schema-migration, or public-api paths

If all conditions met: → IMPLEMENT (skip review, proceed to complete or next WI)
If any condition not met: → REVIEW_SYNTHESIS (full review cycle)

`complexity == null` always disqualifies fast-track — the Architect must explicitly set complexity.

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
All WIs complete with evidence. Execute the team cleanup checklist in order:

1. **Verify completion:** Confirm all WIs have status `done` and `active_candidate_set` is null.
2. **Stop monitors:** Stop all monitors via `/agent-atelier:monitors stop all`.
3. **Cancel cron jobs:** `CronDelete` both the stored monitor poll job ID and the stored watchdog recovery job ID.
4. **Shutdown teammates:** Send `SendMessage({type: "shutdown_request"})` to each active teammate. Wait for all to reach idle/stopped state.
5. **Clean up team:** Call `TeamDelete` to remove team resources. **Only the lead (Orchestrator) may run cleanup** — teammates running cleanup can leave resources inconsistent.
6. **Report results and recommend next step:** Present a concise completion report followed by one recommended action.

   **Completion report** — two parts only:
   - **What was built:** One sentence summarizing the outcome in user terms, derived from WI titles/descriptions (e.g., "번역 키 CRUD + 인라인 편집 + Playwright e2e 테스트 구현 완료"). Never list raw WI counts or commit SHAs — the user cares about capabilities, not bookkeeping.
   - **Issues to flag** (only if present): Validation gaps, failed attempts that were worked around, warnings from the review phase. Omit this section entirely if everything is clean.

   **Recommended next step** — pick the single most logical action based on current state, in this priority order:
   1. Validation gaps exist → flag which WIs lack evidence and offer to run validation
   2. On a feature branch with commits not yet in a PR → offer to create the PR
   3. PR already exists but CI hasn't run → offer to check CI status
   4. Everything clean → report complete, ask if there's anything else

   Present the recommendation as a direct offer (e.g., "PR 생성할까요?" or "WI-003 validation이 빠져있어요. 실행할까요?"), not a menu of options. The user can always redirect. If the user picks the offered action, execute it immediately without further confirmation.

### Cleanup Verification

After executing the cleanup checklist, verify each step actually succeeded before reporting to the user:

**Primary success conditions** (all must pass):
1. Re-read `work-items.json` and `loop-state.json` — confirm zero non-`done` items and `active_candidate_set` is null.
2. Call `CronList` — confirm no remaining orchestration cron jobs (monitor poll or watchdog recovery). If any exist, `CronDelete` them.
3. Team cleanup completed successfully — the lead executed cleanup and no active teammates remain.

**Secondary confirmation** (informational, not blocking):
4. Check whether `~/.claude/teams/<team_name>/` still exists on disk. Directory absence confirms cleanup, but presence alone is not a failure — the canonical signal is step 3 (successful cleanup execution). Log a warning if the directory persists after successful cleanup.

**On failure:**
5. If primary conditions 1–3 fail, retry the shutdown/cleanup sequence once. If still failing, report discrepancies to the user with manual remediation commands.

**Do NOT report "loop completed" until all primary verification checks pass.**

## Phase 4: Continuous Monitoring

Monitoring runs concurrently with the state machine loop via two mechanisms:

### CronCreate Polling (Every ~2 Minutes)

The poll job created in Phase 2 fires when the REPL is idle. On each tick:

1. Invoke `/agent-atelier:monitors check` with the stored task ID mapping.
2. **IMMEDIATE events** — act within this polling cycle:
   - `heartbeat_warning` (expired) → trigger `/agent-atelier:watchdog tick`
   - `heartbeat_warning` (warning) → message Builder via `SendMessage` to send `execute heartbeat`
   - `gate_resolved` → re-read gate state, resume blocked WIs
   - `gate_opened` → present HDR to user immediately
   - `ci_status` (success) → proceed with VALIDATE → REVIEW_SYNTHESIS transition
   - `ci_status` (failure/cancelled) → record validation failure, candidate demotion
   - `branch_divergence` (critical) → inform user, strongly recommend rebase
3. **WARNING events** — log for next human-visible status report.
4. **Dead monitors** — re-spawn via `/agent-atelier:monitors spawn`. If same monitor has died 3+ times, escalate to user.
5. **Silent ticks.** If the check report contains 0 IMMEDIATE events, 0 WARNING events, 0 dead monitors, and no state changes since the last tick — produce no user-visible output. The Orchestrator should not print "all healthy, 0 events" messages. Only report when there is something to act on or escalate.

### Watchdog Recovery Pulse (Every ~15 Minutes or at Phase Transitions)

The watchdog recovery job created in Phase 2 fires when the REPL is idle. On each pulse:

1. Invoke `/agent-atelier:watchdog tick` for mechanical recovery:
   - stale lease requeue
   - expired candidate clearing and next-candidate promotion
   - budget enforcement
   - long-open gate warnings
2. Immediately run an Orchestrator resume sweep:
   - respawn missing core teammates required by the current mode
   - dispatch Builders for `ready` WIs
   - for `implementing` WIs, message the recorded owner if still reachable; if the owner session no longer exists, requeue immediately and dispatch a fresh Builder instead of waiting for lease expiry
   - for `active_candidate`, resume with the current VRM if reachable or spawn a fresh VRM if not
   - for `reviewing` WIs, re-message or re-spawn reviewers as needed
3. **Silent pulses.** If the watchdog reports no recovery and the resume sweep performs no respawn, requeue, dispatch, or user-facing escalation, produce no visible output.

The startup resume sweep described in Phase 2 uses the same rules, except that any WI already in `implementing` when `/run` starts after a crash is presumed stranded and reclaimed immediately.

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
  "mode": "DONE",
  "recommended_next": "create_pr",
  "issues": []
}
```

`recommended_next` — the single highest-priority follow-up action:
- `"run_validation"` — WIs with missing or partial validation evidence
- `"create_pr"` — feature branch with unmerged commits and no open PR
- `"check_ci"` — PR exists but CI status unknown
- `null` — everything clean, no action needed

`issues` — array of strings describing validation gaps or warnings. Empty when clean.

## Error Handling

- If a teammate crashes: the watchdog detects stale leases and recovers mechanically
- If the loop gets stuck: budget checks flag it before it becomes a problem
- If a WI fails repeatedly (3x same fingerprint): escalate to human review
- If the user interrupts: save state, requeue active work, stop monitors, cancel both cron jobs, report status
- If a monitor crashes: CronCreate polling detects it via dead-monitor report → orchestrator re-spawns
- If same monitor crashes 3+ times in a session: escalate to user instead of retrying
- If a session/rate limit temporarily stalls the team but the lead survives: the next watchdog recovery pulse re-runs mechanical recovery and the Orchestrator resume sweep without human input
- If the lead dies before cron jobs exist or can fire: use cold resume (`references/recovery-protocol.md`), then let `/run` recreate runtime infrastructure and perform the startup resume sweep instead of relying on the next 15-minute pulse

## Constraints

- The Orchestrator (lead) NEVER implements code directly except as a last resort (all executors idle + single trivial fix)
- All orchestration writes route through State Manager teammate
- The information barrier between implementation and validation is enforced at every phase boundary
- Success metrics inform routing decisions but never become executable acceptance checks (see `references/success-metrics-routing.md`)
- Recovery from any crash follows `references/recovery-protocol.md`
