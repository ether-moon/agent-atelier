# Team Lifecycle — Spawning, Policies, and Runtime Infrastructure

> Referenced from `SKILL.md` Phase 2. This file covers team creation, spawn policies, roster management, monitor infrastructure, and startup resume procedures.

## Table of Contents

- [Team Name Derivation](#team-name-derivation)
- [Core Team (Always-On)](#core-team-always-on)
- [Conditional Specialists (On-Demand)](#conditional-specialists-on-demand)
- [Builder Spawn Policy](#builder-spawn-policy)
- [TeammateIdle Auto-Assignment](#teammateidle-auto-assignment)
- [Team Roster Injection](#team-roster-injection)
- [Monitor Infrastructure](#monitor-infrastructure)
- [Startup Resume Sweep](#startup-resume-sweep)
- [Active Worktree Hygiene](#active-worktree-hygiene)

## Team Name Derivation

Derive the team name from the git repository root:

```bash
root=$(git rev-parse --show-toplevel)
base=$(basename "$root" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-20)
hash=$(printf '%s' "$root" | shasum -a 256 | cut -c1-8)
team_name="atelier-${base}-${hash}"
```

Sanitization: lowercase, replace `[^a-z0-9_-]` with `-`, collapse consecutive `-`, strip leading/trailing `-`, truncate to 20 chars.

Examples (hashes depend on full absolute path): `/Users/ether/.../lahore` -> `atelier-lahore-a3f2b1c9`, `/Users/ether/.../karrot-tms` -> `atelier-karrot-tms-7b1e4d08`.

### Stale Team Cleanup

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

## Core Team (Always-On)

Spawn each core teammate by referencing their agent type from `.claude/agents/`:

| Role | Agent Type | Mode | Model | Key Tool Differences |
|------|-----------|------|-------|---------------------|
| State Manager | `state-manager` | `acceptEdits` | `sonnet` | Bash (for state-commit) but no Write/Edit |
| PM | `pm` | `acceptEdits` | `opus` | Write/Edit (for docs) but no Bash |
| Architect | `architect` | `acceptEdits` | `opus` | Write/Edit (for docs) but no Bash |

Spawn with: `"Spawn a teammate using the state-manager agent type"` (etc. for each role). The agent definition's `model` and `tools` fields are applied automatically. The role prompt body from the plugin's `references/prompts/` directory is appended as additional instructions.

The **Orchestrator** role is played by the lead agent (you) -- do not spawn a separate teammate for it. Read `plugins/agent-atelier/references/prompts/orchestrator.md` (from repo root) as your own operating guide. Orchestrator, PM, and Architect use Opus (judgment-heavy roles); all other teammates use Sonnet (execution-focused roles).

## Conditional Specialists (On-Demand)

| Role | Agent Type | When to Spawn | When to Shutdown | Model |
|------|-----------|--------------|------------------|-------|
| Builder(s) | `builder` | WI enters `ready` and BUILD_PLAN/IMPLEMENT phase | After WI completion or requeue | `sonnet` |
| VRM | `vrm` | Candidate enters `active_candidate_set` | After evidence bundle produced | `sonnet` |
| QA Reviewer | `qa-reviewer` | REVIEW_SYNTHESIS phase begins | After findings submitted | `sonnet` |
| UX Reviewer | `ux-reviewer` | REVIEW_SYNTHESIS phase begins | After findings submitted | `sonnet` |

Spawn conditional roles by referencing agent type: `"Spawn a teammate using the builder agent type to implement WI-014"`.
Shut down via `SendMessage({type: "shutdown_request"})` when their phase ends.

> **Note:** `skills` and `mcpServers` frontmatter in subagent definitions are NOT applied when running as a teammate (known limitation). Teammates load skills and MCP servers from project settings. The `tools` allowlist and role prompt body ARE applied.

## Builder Spawn Policy

Check the WI's `complexity` field in `work-items.json`:

- **`null`**: Complexity not yet set. Reject the spawn, return the WI to Architect attention, and set complexity before the WI proceeds.
- **`simple`**: Spawn with `mode: "acceptEdits"`. Builder implements immediately.
- **`complex`**: Spawn with `mode: "plan"`. The Builder starts in read-only plan mode -- Write/Edit tools are blocked by the harness. The Builder proposes a plan, calls `ExitPlanMode`, which sends a structured `plan_approval_request` to the Orchestrator. After `plan_approval_response(approve: true)`, the Builder's permission mode auto-transitions to `bypassPermissions` for implementation.

For complex WIs: `"Spawn a teammate using the builder agent type to implement WI-014"` with `mode: "plan"`. The plan approval flow is mechanical -- no prompt instruction needed. See the Orchestrator's Plan Review Protocol for approval criteria.

> **Why `mode: "plan"` and not prompt instructions?** Empirically verified: prompt-only plan approval produces plain text plans without structured messaging. Only `mode: "plan"` triggers the `ExitPlanMode` -> `plan_approval_request` -> `plan_approval_response` protocol that the Orchestrator can process programmatically.

## TeammateIdle Auto-Assignment

The `TeammateIdle` hook (`on-teammate-idle.sh`) automatically detects when a teammate is about to go idle and feeds back role-appropriate guidance. This eliminates the ~2 minute polling delay for work assignment:

- **Builders:** Always allowed to go idle (exit 0). The Orchestrator receives the idle notification and dispatches work via `SendMessage`. Builders never receive exit 2 (keep working) feedback -- this prevents unbreakable idle loops where the agent becomes unresponsive to team lead commands.
- **VRM:** Directed to the active candidate for validation.
- **Reviewers:** Directed to WIs in `reviewing` status during REVIEW_SYNTHESIS.
- **Core team (SM, PM, Architect):** Kept alive while orchestration is active in their relevant phases.

If no work is available for the teammate's role, the hook allows idle (exit 0) and the teammate shuts down gracefully.

**Builder claim flow:** Builder idle -> Orchestrator receives idle notification -> Orchestrator evaluates `work-items.json` for `ready` WIs -> Orchestrator directs SM to call `/agent-atelier:execute claim` -> SM writes state -> Orchestrator dispatches Builder via `SendMessage`. This prevents both phantom claims (Builders self-serving) and idle loops (exit 2 feedback trapping agents).

## Team Roster Injection

When spawning each teammate, append a `## TEAM ROSTER` section to the role prompt with the canonical names of all other active teammates and their roles. Example:

```markdown
## TEAM ROSTER

Your teammates in this session:
- **state-manager** -- exclusive writer for .agent-atelier/ state files
- **pm** -- spec owner, writes docs/product/
- **architect** -- decomposes spec into work items

Send messages to teammates using their exact name above. Do not guess names.
```

When conditional specialists are spawned (Builder, VRM, reviewers), include the current full roster in their prompt AND broadcast the new teammate's name and role to all existing teammates via `SendMessage`.

## Monitor Infrastructure

After spawning the team, start background monitors for continuous state observation:

1. **Spawn monitors.** Invoke `/agent-atelier:monitors spawn` -- returns a JSON mapping of monitor names to background task IDs (heartbeat, gate, events, divergence).
2. **Create monitor poll job.** Use `CronCreate` with cron `"*/2 * * * *"` (fires roughly every 2 minutes when idle). The prompt should invoke `/agent-atelier:monitors check` with the task ID mapping and follow the response protocol documented in the monitors skill.
3. **Create watchdog recovery job.** Use `CronCreate` with cron `"*/15 * * * *"` (fires roughly every 15 minutes when idle). The prompt should:
   - invoke `/agent-atelier:watchdog tick`
   - re-read `loop-state.json` and `work-items.json`
   - run the Orchestrator resume sweep for teammate respawn, work re-dispatch, and early recovery of unreachable owners
   - stay silent if no recovery or dispatch action is needed
4. **Store handles.** Keep both CronCreate job IDs and the task ID mapping in conversation context for later cleanup. These are session-scoped -- they do not survive restarts.

The monitors provide early warning (10-60 second detection) while the watchdog provides mechanical recovery (15-minute ticks). Both layers operate concurrently.

## Startup Resume Sweep

Run once after the core team and monitor infrastructure are restored, before entering the steady-state loop. Required on every `/agent-atelier:run`; on a clean start it should be a no-op.

1. Re-read `loop-state.json` and `work-items.json`.
2. Apply the same routing rules as the watchdog recovery pulse, with one cold-resume override:
   - any WI that was already `implementing` when this `/run` invocation began is presumed stranded from the previous runtime
   - reclaim it immediately through State Manager with reason `cold-resume: owner session unavailable`
   - do not wait for lease expiry
3. Resume other recoverable work from durable state:
   - `ready` -> follow the normal Builder claim and dispatch flow
   - `active_candidate` / `candidate_validating` -> re-message a reachable VRM or spawn a fresh VRM and continue validation without demotion
   - `reviewing` -> re-message reachable reviewers or respawn them from persisted review artifacts
   - if CI was already running for the active candidate, recreate the ci-status monitor if needed
4. Only after this sweep completes, present the startup status dashboard and continue into the normal orchestration loop.

## Active Worktree Hygiene

During an active loop, `.agent-atelier/**` is live runtime state. Do not treat it like ordinary dirty git state.

- Never use `git checkout`, `git restore`, `git stash`, or `git clean` on `.agent-atelier/**`
- Never stash or revert teammate-owned WIP just to make your own commit easier
- If you need a narrow commit, stage only the files you own with explicit pathspecs
- If runtime state appears corrupted, recover through State Manager, watchdog, or the recovery protocol -- not git cleanup commands

For incident reporting during the loop, separate:

- **Confirmed facts** -- direct observations from logs, state, or command output
- **Hypotheses** -- likely causes that still need confirmation
- **Next actions** -- the immediate safe step you will take

This keeps recovery decisions grounded and reduces accidental state destruction during fast triage.
