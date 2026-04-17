---
name: status
description: "Show the orchestration dashboard — current loop mode, work item summary, active candidate set, candidate queue, open gates, and next action. Use when checking progress, understanding what's happening, reviewing the backlog, recovering from a crash, or at the start of any session. Triggers on 'status', 'show state', 'what's going on', 'dashboard', 'where are we', 'progress', 'overview', 'how's it going', 'what's next', or 'orchestration report'. The go-to skill for situational awareness."
---

# Status — Orchestration Dashboard

## When This Skill Runs

- User wants to understand current project state
- Before planning next steps
- After recovering from a crash or long pause
- Start of a new orchestrator session (first action should be status)
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

3. **Scan open gates.** Glob both `.agent-atelier/human-gates/open/` and `.agent-atelier/human-gates/resolved/`. If a gate ID appears in both (orphaned from an interrupted resolve), treat it as resolved — `resolved/` is authoritative.

4. **Derive next action.** Determine what the orchestrator should do next based on state:
   - Open gates with blocked WIs → "resolve gate HDR-NNN or work unblocked items"
   - `ready` WIs exist → "dispatch builder for WI-NNN"
   - Active candidate → "await validation / dispatch VRM"
   - All WIs `done` → "loop complete — report to user"
   - Only `pending` WIs with unmet deps → "unblock dependencies first"
   If `loop-state.json` already contains a `next_action`, prefer that over inference.

5. **Render the dashboard.** Present a human-readable summary. Omit zero-count statuses and empty sections to keep output compact. Flag expired leases and budget warnings prominently.

### Example Dashboard

```
Team:             atelier-sparrow-7
Mode:             IMPLEMENT
Active Spec:      docs/product/behavior-spec.md (rev 7)
Active Candidate: CS-003 (WI-014, WI-015) on candidate/WI-014 @ abc1234
Next Action:      orchestrator → dispatch_vrm_evidence_run → WI-014

Work Items (8 total):
  pending:               2  (WI-018, WI-019)
  ready:                 1  (WI-015)
  implementing:          1  (WI-014 — lease expires in 47min)
  candidate_validating:  1  (WI-016)
  blocked_on_human_gate: 1  (WI-012 — HDR-002)
  done:                  2  (WI-010, WI-011)

  !! EXPIRED LEASE: WI-014 — lease expired 12min ago

Candidate Queue (1 pending):
  CS-004 (WI-017) — queued 2026-04-08T13:00:00Z

Open Gates (1):
  HDR-002: "API shape: preserve current or allow breaking change?"
    Blocking: WI-012  |  Created: 18h ago
    Recommended: Option A

Watchdog:
  Last tick: 35min ago  |  Open alerts: none
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `3` | State files not found (not initialized) |
| `4` | Runtime failure (malformed JSON in state files) |

## Output Contract

Returns JSON to stdout with these top-level keys:

| Key | Type | Description |
|-----|------|-------------|
| `team_name` | string/null | Session-scoped team name from loop-state |
| `mode` | string | Current loop mode (DISCOVER, BUILD_PLAN, IMPLEMENT, etc.) |
| `active_spec` | string | Path to the active behavior spec |
| `active_spec_revision` | number | Spec revision number |
| `next_action` | object | Derived or persisted next action |
| `active_candidate_set` | object/null | Currently active candidate set |
| `candidate_queue` | array | Queued candidate sets awaiting the active slot |
| `open_gates` | array | IDs of open human gates |
| `work_items_summary` | object | `total`, `by_status` (counts), `expired_leases` (IDs) |
| `watchdog` | object | `last_tick_at`, `open_alerts` count |

When presenting to a human user, render the readable dashboard format shown in the execution steps. Diagnostic messages go to stderr.

## Input Conventions

Status takes no arguments and no payload. It is a read-only operation.

## Idempotency

Status is inherently idempotent — it reads state without modifying it. Running it multiple times produces the same output for the same state.

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| State files missing | `3` | Suggest running `/agent-atelier:init` |
| JSON malformed in any state file | `4` | Name the broken file; suggest deleting it and re-running `/agent-atelier:init` to regenerate (init is idempotent and only creates missing files) |
| Gate directory missing | `0` | Render dashboard without gates section; note the absence |
| Watchdog file missing but others present | `0` | Render available sections; warn that watchdog state is absent |
| All WIs empty (initialized but no work yet) | `0` | Render dashboard with "No work items yet" and suggest next step |

## Constraints

- Status never writes to state files. It is strictly read-only.
- When a session restarts or context is compressed, run status first to restore situational awareness before taking any action.
- Prefer the persisted `next_action` from `loop-state.json` over inferred values. Only infer when the field is absent or stale.
