# Changelog

## [0.2.0] - 2026-05-11

### Added

- **plan/execute workflow**: new `/agent-atelier:plan` and `/agent-atelier:execute` user-facing skills with mandatory ping-pong clarifying-question loop before IMPLEMENT (#15)
- **state-commit IMPLEMENT gate**: mechanical enforcement — `mode: BUILD_PLAN → IMPLEMENT` transitions require matching `wi_plan_hash` and `spec_hash` in `plan_approval` (#15)
- **`scripts/` directory**: `wi`, `lifecycle`, `gate`, `watchdog`, `candidate`, `validate`, `init-helpers.sh`, `_plan_hash.py` — 7 internal mechanical scripts emitting JSON with `native_task_sync` hints (#15)
- **schemas**: `clarifying-question.schema.json` and `plan-conversation-entry.schema.json` (#15)
- **state fields**: `loop-state.json` gains `plan_approval`, `active_plan_cycle_id`, `plan_gate`; `watchdog-jobs.json` gains plan-budget defaults (#15)
- **`references/monitor-runtime.md`**: LLM-driven monitor procedure delegated from the `monitors` shim (#15)
- **scenario tests**: 9 end-to-end state-level integration tests (`plan_only`, `execute_no_plan`, `execute_with_valid_plan`, `plan_invalidated`, `pingpong_basic/modify/assume/budget`, `cold_resume_pingpong`) plus `script_contracts.sh`, `plan_hash_test.sh`, `implement_gate_test.sh`, `init_helpers_test.sh` — 70 tests total (#15)

### Improved

- **user surface simplification**: skill discovery now lists only `plan`, `execute`, `status` (user-facing) + `monitors` (internal shim) instead of the previous 10 slash commands (#15)
- **PM / Architect prompts**: must surface uncertainty as `ClarifyingQuestion` during plan phases; signal `no_more_questions` at round end (#15)
- **Orchestrator prompt**: hosts the ping-pong loop, batches up to 3 questions per `AskUserQuestion` call, enforces 30-question budget in real time, is the sole writer of `plan-conversations/<cycle-id>.jsonl` (#15)
- **`init-helpers.sh`**: migrates existing installs by merging missing top-level state keys (no overwrite, no nested touch) (#15)
- **status dashboard**: surfaces Plan State section with hash-match check and recent ping-pong activity (#15)

### Fixed

- **`scripts/watchdog`**: aborts tick when WAL replay fails instead of operating on partially recovered state (#15)
- **`scripts/candidate`**: revalidates queued WI status on activation; preserves `done` WIs during demotion (#15)
- **`scripts/gate`**: validates `blocked_work_items` before rebinding, rejecting unknown WIs and double-bindings (#15)
- **`scripts/wi`**: clears stale `blocked_by_gate` link whenever status is not `blocked_on_human_gate` (#15)
- **`scripts/lifecycle`**: removes unreachable lease-check code after status guard (#15)
- **`scripts/validate`**: folds manifest write into the state-commit transaction for true atomicity (#15)
- **`scripts/init-helpers.sh`**: emits the documented `wal_recovered` field; drops unused `--migrate-only` flag (#15)

## [0.1.5] - 2026-05-07

### Fixed

- **plugin**: ship spawnable subagent definitions inside the plugin's own `agents/` directory so `/agent-atelier:run` no longer requires consumers to author thin `.claude/agents/<role>.md` `@-import` shims (#14)

### Improved

- **dogfooding**: switch dogfooding setup to consume the plugin via the `ether-plugins` hub instead of a project-local copy (#13)

## [0.1.4] - 2026-04-17

### Improved

- **skills**: refine all 10 skills via creating-skills methodology for clarity and consistency (#12)
- **orchestration**: align runtime with orchestration model v0.2 (#11)
- **recovery**: align recovery contracts and add regression tests (#10)
- **subagents**: add OUTPUT DISCIPLINE to role prompts for token efficiency (#9)
- **teams**: session-scoped team names for cross-project isolation (#8)

### Fixed

- **TeammateIdle**: prevent phantom claims and idle loops (#6)

## [0.1.3] - 2026-04-14

### Improved

- **orchestrator/run**: document live runtime-state hygiene for `.agent-atelier/**` and require incident triage to separate facts, hypotheses, and next actions
- **execute**: clarify `claim` as Orchestrator-authorized and State-Manager-executed to reinforce the single-writer coordination path

### Fixed

- **TeammateIdle**: keep Builders idle until the Orchestrator explicitly dispatches work, preventing phantom self-claims and unresponsive feedback loops
- **VRM**: wake validation work only when an `active_candidate` exists, avoiding repeated idle-loop feedback with no actionable task

## [0.1.2] - 2026-04-14

### Added

- **agent teams**: 7 teammate subagent definitions under `.claude/agents/` and project settings to enable Agent Teams in Claude Code
- **hooks**: `TeammateIdle` and `TaskCreated` lifecycle hooks for auto-assignment and task budget validation
- **verification**: manual Agent Teams verification artifacts under `tests/manual/`

### Improved

- **run**: align orchestration flow with the Agent Teams API, including native task coordination, complex-WI plan approval, team cleanup checks, and per-role model guidance
- **wi-schema/architect**: add WI `complexity` and simplicity-first planning guidance so complex work can enter structured plan mode before implementation
- **coordination**: replace older team-control/write references with `SendMessage`-based handoffs and subject-prefix native task lookup compatible with current Agent Teams behavior

### Fixed

- **TeammateIdle**: extract actionable `work_item_id` data for VRM wakeups instead of emitting raw candidate objects
- **on-stop**: handle empty resource globs safely during team cleanup warnings
- **docs/tests**: apply Agent Teams review fixes for code fences, terminology, and version-bump skill coverage

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
