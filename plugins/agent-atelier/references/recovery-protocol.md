# Cold Resume — Recovery Protocol

When a session crashes or the orchestration loop restarts, follow this protocol to resume from persisted state. Agent Teams cannot restore teammates on resume — recovery relies entirely on committed state.

## Principle

**Commit-as-savepoint + attempt journals.** All state is file-based. Uncommitted worktree code is discardable. Operational knowledge survives in attempt journals committed by State Manager.

## Cold Resume Algorithm

### Step 1: Read Disk State

Read these files (all under `.agent-atelier/`):

- `loop-state.json` — current mode, active candidate, candidate queue, open gates
- `work-items.json` — all WI statuses, leases, promotion, completion
- `watchdog-jobs.json` — thresholds, open alerts
- `human-gates/open/*.json` — pending human decisions
- `attempts/*/attempt-*.json` — failure context per WI

Also scan `git log` for recent commits (candidate branches, Builder atomic commits).

### Step 2: WAL Recovery

If `.pending-tx.json` exists, a previous state-commit was interrupted:

```bash
cat .agent-atelier/.pending-tx.json | <plugin-root>/scripts/state-commit --root <repo-root> --replay
```

This completes partially applied transactions before any other recovery.

Cold resume assumes the previous runtime is gone. Reachable-owner resume applies only to the in-session 15-minute recovery pulse, not to this protocol.

### Step 3: Classify Each Work Item

For each WI, determine its recoverable state:

| Current Status | Lease | Action |
|---|---|---|
| `implementing` | Expired | Requeue to `ready`, clear lease, increment `stale_requeue_count` |
| `implementing` | Still valid from the crashed runtime | Mark for immediate reclaim in the startup resume sweep started by `/agent-atelier:run`; do not wait for lease expiry |
| `candidate_validating` | Stale (> timeout) | Demote candidate, requeue WI to `ready` |
| `candidate_validating` | Recent | Resume — VRM can pick up active candidate |
| `reviewing` | Stale (> timeout) | Re-dispatch reviewers |
| `blocked_on_human_gate` | N/A | Keep blocked — scan open gates to restore awareness |
| `done` | N/A | No action needed |
| `pending` / `ready` | N/A | Available for claiming |

### Step 3b: Candidate–WI Consistency Check

If `active_candidate_set` is non-null, verify ALL referenced WIs (from `work_item_ids`) are in `candidate_validating` status. If any WI has been reset to `ready` (e.g., crash between `validate record` and the atomic clear), run `candidate clear --reason demoted` to reconcile loop-state. With the v0.2 atomic validate-clear, this scenario should be rare — `validate record` now includes `active_candidate_set → null` in the same transaction on failure.

### Step 4: Restore Gate Awareness

Scan `human-gates/open/` for pending HDRs. Cross-reference with `loop-state.json.open_gates` and `work-items.json` `blocked_by_gate` fields. Report any inconsistencies.

### Step 5: Commit Recovery Changes

Apply all mechanical recovery changes (stale lease expiry, candidate demotion) in a single `state-commit` transaction via the watchdog `tick` subcommand.

Still-valid `implementing` leases from the crashed runtime are not cleared by `watchdog tick`. They are reclaimed in the startup resume sweep that runs immediately after `/agent-atelier:run` restores the core team.

### Step 6: Spawn Fresh Team

Start a new orchestration loop (`/agent-atelier:run`). The orchestrator reads the recovered state and spawns fresh teammates based on the current mode and WI states.

### Step 6b: Run-Owned Runtime Restoration

Do not separately invoke `/agent-atelier:monitors spawn` after calling `/agent-atelier:run`. The run skill owns restoration of session-scoped runtime infrastructure:

- it recreates fresh always-on monitors
- it recreates the monitor poll job (`*/2`) wired to `/agent-atelier:monitors check`
- it recreates the watchdog recovery pulse job (`*/15`) wired to `/agent-atelier:watchdog tick` plus the Orchestrator resume sweep
- it runs one startup resume sweep before steady-state dispatch

During that startup resume sweep:

- any WI still in `implementing` is treated as stranded from the previous runtime and requeued immediately through State Manager
- `ready` WIs return to the normal Builder dispatch path
- `active_candidate_set` validation work resumes with a fresh or reachable VRM as appropriate
- `reviewing` WIs resume from persisted review artifacts with fresh or reachable reviewers as appropriate
- if CI validation was already in progress when the session crashed, the Orchestrator re-creates the ci-status monitor for the active candidate set if needed

Previous session's monitors and cron jobs are gone — they were session-scoped and died with the crashed session. `/agent-atelier:run` is the only component that should recreate them.

### Step 7: Resume From Committed State Only

Fresh teammates receive context only from:
- Persisted state files (loop-state, work-items)
- Behavior spec (`docs/product/behavior-spec.md`)
- Attempt journals (failure context from previous sessions)
- Git log (what was committed, candidate branches)

They do NOT receive:
- Previous session's conversation history
- Builder summaries or narratives from crashed sessions
- Memory of "what we were doing"

## Corrupted State Files

If a state file contains invalid JSON (disk corruption, manual edit, encoding error), `state-commit` will fail with exit code 4 and block all further writes. Manual recovery:

1. Identify the corrupted file from the error message.
2. Check `git log` for the last known-good version and restore it: `git checkout HEAD -- .agent-atelier/<file>`.
3. If no git history exists (file was never committed), delete it and re-run `/agent-atelier:init` to regenerate defaults.
4. If `.pending-tx.json` is itself corrupted, delete it — the incomplete transaction is lost but state files remain at their last consistent revision.

## Mandatory Test Scenarios

These scenarios must work correctly (from recovery-spec.md):

1. **Executor dies mid-implementation** — Lease expires, watchdog requeues, new Builder re-claims
2. **Validator hangs** — Candidate times out, watchdog demotes, candidate returns to queue
3. **Missing evidence on completion attempt** — `execute complete` rejects without manifest/refs
4. **Repeated failure (3x same fingerprint)** — Watchdog escalates to orchestrator review
5. **Open gate survives restart** — HDR files persist, gate awareness restored from disk
6. **Stale revision rejected** — Concurrent writes detected and rejected by state-commit
7. **Cold resume from disk** — Full state reconstruction from files + git log without conversation history
8. **Valid lease from crashed runtime** — Startup resume sweep requeues stranded `implementing` work immediately instead of waiting for lease expiry
