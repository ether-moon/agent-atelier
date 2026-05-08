# Orchestration Paths

All paths are relative to the repository root (detected via `git rev-parse --show-toplevel`).

## State Files

| File | Purpose |
|------|---------|
| `.agent-atelier/loop-state.json` | Control plane: mode, active candidate, open gates, next action |
| `.agent-atelier/work-items.json` | Work item store: all WIs with status, lease, promotion |
| `.agent-atelier/watchdog-jobs.json` | Watchdog thresholds and open alerts |
| `.agent-atelier/plan-conversations/<cycle-id>.jsonl` | Per-cycle ping-pong conversation log (Orchestrator-only writer) |

## Human Gates

| Path | Purpose |
|------|---------|
| `.agent-atelier/human-gates/_index.md` | Dashboard (markdown table) |
| `.agent-atelier/human-gates/open/` | Pending decisions (HDR-NNN.json) |
| `.agent-atelier/human-gates/resolved/` | Completed decisions |
| `.agent-atelier/human-gates/templates/human-decision-request.json` | Template for new gates |

## Attempt Artifacts

| Path | Purpose |
|------|---------|
| `.agent-atelier/attempts/<WI-ID>/` | Per-WI attempt directory |
| `.agent-atelier/attempts/<WI-ID>/attempt-NN.json` | Individual attempt record |

## Validation Artifacts

| Path | Purpose |
|------|---------|
| `.agent-atelier/validation/` | Root directory for validation evidence |
| `.agent-atelier/validation/<run-id>/` | Per-run validation directory |
| `.agent-atelier/validation/<run-id>/manifest.json` | Machine-readable validation run manifest |
| `.agent-atelier/validation/<run-id>/report.md` | Human-readable validation report |

## Product Documents

| Path | Purpose |
|------|---------|
| `docs/product/behavior-spec.md` | Feature specification (PM-owned) |
| `docs/product/success-metrics.md` | Business metrics |
| `docs/product/assumptions.md` | Impact x Uncertainty matrix |
| `docs/product/open-questions.md` | Unresolved items |
| `docs/product/decision-log.md` | Decision rationale log |

## Monitor Scripts

| Path | Purpose |
|------|---------|
| `plugins/agent-atelier/scripts/monitors/heartbeat-watch.sh` | Lease expiry early warning |
| `plugins/agent-atelier/scripts/monitors/gate-watch.sh` | Gate state change detection |
| `plugins/agent-atelier/scripts/monitors/event-tail.sh` | Semantic event stream tail |
| `plugins/agent-atelier/scripts/monitors/ci-status.sh` | CI/PR status polling |
| `plugins/agent-atelier/scripts/monitors/branch-divergence.sh` | Base branch divergence detection |

## Mechanical Scripts (scripts/)

| Path | Purpose |
|------|---------|
| `plugins/agent-atelier/scripts/state-commit` | Atomic multi-file writer for `.agent-atelier/**` (sole writer) |
| `plugins/agent-atelier/scripts/init-helpers.sh` | Bootstrap and migrate state files |
| `plugins/agent-atelier/scripts/wi` | Work item planning (list/show/upsert) |
| `plugins/agent-atelier/scripts/lifecycle` | WI execution lifecycle (claim/heartbeat/requeue/complete/attempt) |
| `plugins/agent-atelier/scripts/gate` | Human gate lifecycle (list/open/resolve) |
| `plugins/agent-atelier/scripts/watchdog` | Mechanical recovery tick |
| `plugins/agent-atelier/scripts/candidate` | Candidate set lifecycle (enqueue/activate/clear) |
| `plugins/agent-atelier/scripts/validate` | Validation evidence recording |
| `plugins/agent-atelier/scripts/_plan_hash.py` | Plan-level hash helpers (used by state-commit and wi) |

All scripts emit JSON to stdout. Mutating scripts include a `native_task_sync` hint that callers (Orchestrator/SM) must execute as `TaskCreate`/`TaskUpdate` after success. See spec section "Native Task Sync 패턴".
