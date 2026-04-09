---
name: status
description: "Show the orchestration dashboard — current loop mode, work item summary, active candidate, open gates, and next action. Use when checking progress, understanding what's happening, reviewing the backlog, or when the user says 'status', 'show state', 'what's going on', 'dashboard', or 'where are we'. This is the go-to skill for situational awareness."
---

# Status — Orchestration Dashboard

## When This Skill Runs

- User wants to understand current project state
- Before planning next steps
- After recovering from a crash or long pause
- Routine check-in during development

## Prerequisites

- Orchestration state must be initialized (run `/agent-atelier:init` first if not)

## Allowed Tools

- Read (state files and gate files)
- Bash (git root detection, directory listing)
- Glob (scan open gates directory)

## Execution Steps

1. **Detect root** via `git rev-parse --show-toplevel`.

2. **Read state files.** Read these JSON files directly — no CLI needed:
   - `.agent-atelier/loop-state.json`
   - `.agent-atelier/work-items.json`
   - `.agent-atelier/watchdog-jobs.json`

3. **Scan open gates.** List files in both `.agent-atelier/human-gates/open/` and `.agent-atelier/human-gates/resolved/`. If a gate ID appears in both directories (orphaned from an interrupted resolve), treat it as resolved — the `resolved/` copy is authoritative. Only report gates that exist in `open/` without a matching `resolved/` copy as truly open.

4. **Render the dashboard.** Present a human-readable summary with these sections:

### Loop State
```
Mode:             IMPLEMENT
Active Spec:      docs/product/behavior-spec.md (rev 7)
Active Candidate: WI-014 on candidate/WI-014 @ abc1234
Next Action:      orchestrator → dispatch_vrm_evidence_run → WI-014
```

### Work Items Summary
```
Total: 8 items
  pending:              2  (WI-018, WI-019)
  ready:                1  (WI-015)
  implementing:         1  (WI-014 — lease expires in 47min)
  blocked_on_human_gate: 1  (WI-012 — HDR-002)
  done:                 3  (WI-010, WI-011, WI-013)
```

### Open Gates
```
HDR-002: "API shape: preserve current or allow breaking change?"
  Blocking: WI-012
  Created: 2026-04-07T14:30:00Z (18h ago)
```

### Watchdog Status
```
Last tick: 2026-04-08T11:00:00Z (35min ago)
Open alerts: none
```

If any items have expired leases, flag them prominently — the user needs to know about stuck work.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `3` | State files not found (not initialized) |
| `4` | Runtime failure (malformed JSON in state files) |

## Output Contract

Returns JSON to stdout:

```json
{
  "mode": "IMPLEMENT",
  "active_spec": "docs/product/behavior-spec.md",
  "active_spec_revision": 7,
  "open_gates": ["HDR-002"],
  "active_candidate": {
    "work_item_id": "WI-014",
    "branch": "candidate/WI-014",
    "commit": "abc1234"
  },
  "candidate_queue": [],
  "work_items_summary": {
    "total": 8,
    "by_status": {
      "pending": 2,
      "ready": 1,
      "implementing": 1,
      "blocked_on_human_gate": 1,
      "done": 3
    },
    "expired_leases": ["WI-014"]
  },
  "watchdog": {
    "last_tick_at": "2026-04-08T11:00:00Z",
    "open_alerts": 0
  }
}
```

When presenting to a human user, additionally render the readable dashboard format shown in the execution steps above. Diagnostic messages go to stderr.

## Error Handling

- If state files don't exist: suggest running `/agent-atelier:init`.
- If JSON is malformed: report which file is broken and suggest manual inspection.
