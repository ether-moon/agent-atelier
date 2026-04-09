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

### Step 4: Restore Gate Awareness

Scan `human-gates/open/` for pending HDRs. Cross-reference with `loop-state.json.open_gates` and `work-items.json` `blocked_by_gate` fields. Report any inconsistencies.

### Step 5: Commit Recovery Changes

Apply all mechanical recovery changes (stale lease expiry, candidate demotion) in a single `state-commit` transaction via the watchdog `tick` subcommand.

### Step 6: Spawn Fresh Team

Start a new orchestration loop (`/agent-atelier:run`). The orchestrator reads the recovered state and spawns fresh teammates based on the current mode and WI states.

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

## Mandatory Test Scenarios

These scenarios must work correctly (from recovery-spec.md):

1. **Executor dies mid-implementation** — Lease expires, watchdog requeues, new Builder re-claims
2. **Validator hangs** — Candidate times out, watchdog demotes, candidate returns to queue
3. **Missing evidence on completion attempt** — `execute complete` rejects without manifest/refs
4. **Repeated failure (3x same fingerprint)** — Watchdog escalates to orchestrator review
5. **Open gate survives restart** — HDR files persist, gate awareness restored from disk
6. **Stale revision rejected** — Concurrent writes detected and rejected by state-commit
7. **Cold resume from disk** — Full state reconstruction from files + git log without conversation history
