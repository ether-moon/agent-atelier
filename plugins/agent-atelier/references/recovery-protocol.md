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

### Step 3: Classify Each Work Item

For each WI, determine its recoverable state:

| Current Status | Lease | Action |
|---|---|---|
| `implementing` | Expired | Requeue to `ready`, clear lease, increment `stale_requeue_count` |
| `implementing` | Valid | Resume — a Builder can re-claim after fresh spawn |
| `candidate_validating` | Stale (> timeout) | Demote candidate, requeue WI to `ready` |
| `candidate_validating` | Recent | Resume — VRM can pick up active candidate |
| `reviewing` | Stale (> timeout) | Re-dispatch reviewers |
| `blocked_on_human_gate` | N/A | Keep blocked — scan open gates to restore awareness |
| `done` | N/A | No action needed |
| `pending` / `ready` | N/A | Available for claiming |

### Step 3b: Candidate–WI Consistency Check

If `active_candidate` is non-null, verify the referenced WI is actually in `candidate_validating` status. If the WI has already been reset to `ready` (e.g., crash between `validate record` and `candidate clear`), run `candidate clear --reason crash-recovery` to reconcile loop-state.

### Step 4: Restore Gate Awareness

Scan `human-gates/open/` for pending HDRs. Cross-reference with `loop-state.json.open_gates` and `work-items.json` `blocked_by_gate` fields. Report any inconsistencies.

### Step 5: Commit Recovery Changes

Apply all mechanical recovery changes (stale lease expiry, candidate demotion) in a single `state-commit` transaction via the watchdog `tick` subcommand.

### Step 6: Spawn Fresh Team

Start a new orchestration loop (`/agent-atelier:run`). The orchestrator reads the recovered state and spawns fresh teammates based on the current mode and WI states.

### Step 6b: Re-Spawn Monitors

Invoke `/agent-atelier:monitors spawn` to start fresh always-on monitors (heartbeat, gate, events, divergence). Create a new `CronCreate` poll job with the returned task IDs. Previous session's monitors and cron jobs are gone — they were session-scoped and died with the crashed session.

If CI validation was in progress when the session crashed (i.e., `active_candidate` is non-null and mode is VALIDATE), check whether a ci-status monitor needs to be spawned for the active candidate's CI run via `/agent-atelier:monitors spawn-ci`.

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
