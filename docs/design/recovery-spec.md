# Agent-Atelier — Recovery Specification

**Date**: 2026-04-08
**Status**: Draft v1
**Scope**: Crash recovery, session-limit recovery, watchdog recovery, and completion safety

---

## 1. Recovery Goals

The runtime must recover from agent loss without reconstructing state from chat history.

Recovery goals:

- no WI is silently lost
- no WI becomes `done` without evidence
- stale ownership is automatically cleared
- human decisions are never fabricated by automation
- code/spec changes are never performed by watchdog recovery

---

## 2. Recovery Classes

| Failure Class | Example | Auto-Recover? | Action |
|---|---|---|---|
| Executor stalled | No heartbeat, no commit | Yes | Expire lease and requeue WI |
| Validator stalled | `active_candidate` with no run progress | Yes | Demote candidate, clear slot, alert Orchestrator |
| Missing evidence | Completion requested without validation manifest | Yes | Reject completion |
| Repeated implementation loop | Same fingerprint 3 times | No | Escalate to Orchestrator |
| Gate left open too long | HDR open for 24h | No | Alert only |
| Stale state update | Old revision tries to mutate state | Yes | Reject request |
| Session crash | Process exits mid-WI | Yes | Resume from disk and git |
| Session/rate limit stall | Claude rejects prompts temporarily | Partial | Wait for watchdog recovery pulse; if lead is gone, cold resume |
| Product ambiguity | Recovery requires product judgment | No | Human gate or Orchestrator review |

---

## 3. Watchdog Recovery Rules

Watchdog may trigger only these automatic actions through State Manager commits:

- expire an implementation lease
- clear `owner_session_id`
- move a WI from `implementing` to `ready`
- increment `stale_requeue_count`
- demote a stale `active_candidate` back to queue
- reject or flag completion without evidence
- create an alert record

Watchdog must not:

- edit product code
- edit behavior spec
- merge branches
- resolve human gates
- invent validation results

Watchdog is only the mechanical half of the 15-minute recovery pulse. Teammate respawn, owner reachability checks, and work re-dispatch remain the Orchestrator's responsibility after the tick completes.

---

## 4. Session-Limit Recovery

Session/rate-limit recovery is intentionally lightweight:

1. do not persist a dedicated paused mode
2. let the stalled turn fail naturally
3. rely on an already-created 15-minute watchdog recovery cron to try again when the lead session is idle and promptable
4. after a successful `watchdog tick`, the Orchestrator runs a resume sweep:
   - respawn missing teammates required by the current mode
   - resume `ready` work through normal dispatch
   - recontact `implementing` owners that still exist
   - immediately requeue `implementing` WIs whose recorded owner session no longer exists, rather than waiting for lease expiry
   - resume active validation/review with fresh specialists if needed

If the lead session is gone before that recovery pulse can fire, session-limit recovery does not apply; use cold resume instead.

---

## 5. Cold Resume Algorithm

When the runtime starts after interruption:

1. read orchestration state files
2. verify file integrity and schema validity
3. list open HDRs
4. inspect validation manifests for in-progress runs
5. inspect work items for expired leases
6. inspect git branches / worktrees for committed candidate state
7. apply mechanical recovery where allowed
8. start `/agent-atelier:run`, which recreates the monitor poll cron, the watchdog recovery cron, and one startup resume sweep over the recovered state
9. emit a resume summary
10. let Orchestrator choose the next action from the recovered state

Cold resume is distinct from session-limit recovery: teammate sessions from the previous runtime are gone. A still-valid `implementing` lease therefore does not authorize resuming the old owner. The startup resume sweep must reclaim stranded `implementing` WIs immediately rather than waiting for lease expiry.

---

## 6. Completion Safety

`done` is allowed only if all are true:

- WI has a candidate commit
- validation manifest exists
- validation manifest status is acceptable
- evidence refs exist on disk
- required verification checks are listed
- no open blocking gate remains for that WI

If any condition fails, completion must be rejected.

---

## 7. Repeated-Failure Policy

### Finding Fingerprints

Each repeated failure should be normalized into a stable fingerprint such as:

- `VAL-031/retry-button-not-clickable`
- `TEST/auth-timeout-on-refresh`
- `ENV/playwright-browser-launch-failed`

### Thresholds

- same implementation fingerprint 3 times -> Orchestrator review
- same watchdog intervention 2 times on one WI -> Orchestrator review
- same environment error 2 times -> environment escalation, not code retry

---

## 8. Human Gate Recovery

Human gates are durable by file, so recovery is simple:

- keep gate open
- keep affected WIs blocked
- report open gates on resume

Automation may never close or answer a gate.

---

## 9. Evidence Retention

Recovery depends on durable evidence. Implementations must not delete:

- latest attempt artifacts for non-done WIs
- validation manifests linked from active or recently failed candidates
- open HDR files
- watchdog alerts for unresolved incidents

Cleanup is allowed only for:

- resolved HDRs after archival
- completed WIs with archived evidence
- superseded candidate branches after successful promotion

---

## 10. Recovery Output

Every watchdog tick or cold resume should emit a machine-readable summary:

```json
{
  "recovered": [
    {
      "work_item_id": "WI-014",
      "action": "lease_expired_requeued"
    }
  ],
  "alerts": [
    "WDA-004"
  ],
  "manual_attention_required": [
    "WI-021"
  ]
}
```

This makes recovery auditable and testable.

---

## 11. Test Scenarios

At minimum, the runtime must be tested against:

1. executor dies before heartbeat renewal
2. validator hangs after candidate activation
3. completion is attempted without evidence
4. repeated fingerprint causes escalation
5. open gate survives full restart
6. stale `based_on_revision` request is rejected
7. cold resume reconstructs next action from disk only
8. session-limit stall recovers on the next watchdog recovery pulse without user input
9. unreachable `implementing` owner is requeued before lease expiry during recovery
