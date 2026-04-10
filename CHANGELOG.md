# Changelog

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
