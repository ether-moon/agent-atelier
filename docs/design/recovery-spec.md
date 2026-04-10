# Agent-Atelier — Recovery Specification

**Date**: 2026-04-08
**Status**: Draft v1
**Scope**: Crash recovery, watchdog recovery, and completion safety

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

---

## 4. Cold Resume Algorithm

When the runtime starts after interruption:

1. read orchestration state files
2. verify file integrity and schema validity
3. list open HDRs
4. inspect validation manifests for in-progress runs
5. inspect work items for expired leases
6. inspect git branches / worktrees for committed candidate state
7. apply mechanical recovery where allowed
8. emit a resume summary
9. let Orchestrator choose the next action from the recovered state

---

## 5. Completion Safety

`done` is allowed only if all are true:

- WI has a candidate commit
- validation manifest exists
- validation manifest status is acceptable
- evidence refs exist on disk
- required verification checks are listed
- no open blocking gate remains for that WI

If any condition fails, completion must be rejected.

---

## 6. Repeated-Failure Policy

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

## 7. Human Gate Recovery

Human gates are durable by file, so recovery is simple:

- keep gate open
- keep affected WIs blocked
- report open gates on resume

Automation may never close or answer a gate.

---

## 8. Evidence Retention

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

## 9. Recovery Output

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

## 10. Test Scenarios

At minimum, the runtime must be tested against:

1. executor dies before heartbeat renewal
2. validator hangs after candidate activation
3. completion is attempted without evidence
4. repeated fingerprint causes escalation
5. open gate survives full restart
6. stale `based_on_revision` request is rejected
7. cold resume reconstructs next action from disk only
