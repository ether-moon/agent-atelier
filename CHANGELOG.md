# Changelog

## [0.1.3] - 2026-04-14

### Added

- **run**: DONE phase completion report with single recommended next action (PR creation, validation, CI check)
- **run**: native Agent Teams task integration — dual-layer WI/task model with automatic dependency wiring
- **run**: plan approval workflow — complex WIs spawn Builders in plan mode, Orchestrator reviews via structured protocol

### Improved

- **hooks**: TaskCompleted (artifact verification), TeammateIdle (auto-assignment), TaskCreated (budget validation)
- **bumping-version**: plugin.json added to version bump file list

## [0.1.1] - 2026-04-13

### Added

- **monitors**: 4 always-on background monitor scripts (heartbeat-watch, gate-watch, event-tail, branch-divergence) with CronCreate polling integration
- **run**: team roster injection at spawn time with rebroadcast on specialist joins

### Improved

- **orchestrator**: OUTPUT DISCIPLINE section — ban insight blocks, status tables only at phase transitions, silent 0-event polls, task hygiene for completed-task notifications
- **pm**: complete-before-reporting rule — finish deliverables before sending completion reports
- **architect**: submit-on-ready rule — submit payloads to State Manager immediately
- **state-defaults**: HDR contract notes — null revision for new files, immutable HDRs, authoritative schema

### Fixed

- **state-commit**: reorder cleanup ops, decouple replay from stdin, harden WAL parsing
- **state-commit**: pin distillery checkout to immutable SHA, use WAL as replay source-of-truth
- **state-commit**: address peer review findings — security, correctness, and doc consistency
- **tests**: suite expanded from 47 to 52 assertions (monitor script integration tests)

## [0.1.0] - 2026-04-09

### Added

- **skills**: 9 orchestration skills — init, status, wi, execute, candidate, validate, gate, watchdog, run
- **hooks**: 4 lifecycle hooks — UserPromptSubmit (signal collector), PreToolUse (destructive command blocking), Stop (dangling obligation check), SubagentStop
- **scripts**: `state-commit` (atomic multi-file writer with WAL and revision checking), `build-vrm-prompt` (VRM evidence input builder with information barrier)
- **prompts**: 10 production role prompts — orchestrator, state-manager, pm, architect, builder, vrm, qa-reviewer, ux-reviewer, ui-designer, aesthetic-ux-reviewer
- **references**: paths, state-defaults, wi-schema, recovery-protocol, success-metrics-routing
- **schema**: `vrm-evidence-input.schema.json`
- **state machine**: Mode Transition Protocol with 12-row valid transition table, IMPLEMENT/VALIDATE overlap support
- **validation**: validate writes work-items.json only; candidate clear handles loop-state with idempotent demoted guard
- **review**: Review Findings Persistence at `.agent-atelier/reviews/<WI-ID>/findings.json` for cold resume
- **requeue**: execute requeue supports any non-terminal status including `reviewing` with promotion metadata cleanup
- **docs**: 7 design documents (system-design, runtime-contracts, state-schemas, agent-lifecycle, cli-surface, recovery-spec, human-gate-ops), 5 product templates
- **tests**: 47-assertion test suite covering plugin structure, hook wiring, script executability, role prompt completeness, state schema validation, mutation flow
