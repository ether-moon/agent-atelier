# Event Classification and Orchestrator Response Protocol

## Table of Contents

- [Event Classification Table](#event-classification-table)
- [Orchestrator Response Protocol](#orchestrator-response-protocol)

## Event Classification Table

When `check` parses NDJSON output from monitors, each event is classified by urgency:

| Event Type | Condition | Urgency |
|------------|-----------|---------|
| `heartbeat_warning` | `severity == "expired"` | IMMEDIATE |
| `heartbeat_warning` | `severity == "warning"` | WARNING |
| `gate_resolved` | -- | IMMEDIATE |
| `gate_opened` | -- | IMMEDIATE |
| `ci_status` | `conclusion == "success"` | IMMEDIATE |
| `ci_status` | `conclusion == "failure"` or `"cancelled"` | IMMEDIATE |
| `ci_status` | `conclusion == null` (in-progress) | INFO |
| `branch_divergence` | `severity == "critical"` | IMMEDIATE |
| `branch_divergence` | `severity == "warning"` | WARNING |
| `state_committed` | -- | INFO |

## Orchestrator Response Protocol

This protocol defines what the Orchestrator does when the CronCreate polling prompt receives classified events from `check`:

**IMMEDIATE events -- act within this polling cycle:**

- `heartbeat_warning` (expired) -- trigger `/agent-atelier:watchdog tick`
- `heartbeat_warning` (warning) -- message Builder via `SendMessage` to send `execute heartbeat` (non-blocking; log if Builder is unresponsive)
- `gate_resolved` -- re-read gate state, resume blocked WIs
- `gate_opened` -- present HDR to user immediately
- `ci_status` (success) -- evaluate fast-track, then transition to IMPLEMENT or REVIEW_SYNTHESIS
- `ci_status` (failure/cancelled) -- record validation failure, candidate demotion
- `branch_divergence` (critical) -- inform user, strongly recommend rebase

**WARNING events -- act on a best-effort basis this cycle:**

- `heartbeat_warning` (warning) -- nudge Builder; if unresponsive, log for next status report
- `branch_divergence` (warning) -- log for next human-visible status report

**INFO events:** Update situational awareness, no action required.

**Dead monitors:** Re-spawn via `/agent-atelier:monitors spawn` (or `spawn-ci` for ci-status). If same monitor has died 3+ times in a session, escalate to user instead of retrying.
