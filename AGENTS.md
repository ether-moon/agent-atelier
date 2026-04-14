# AGENTS.md

agent-atelier — Autonomous product development loop — AI agent team that cycles through spec, implement, validate, and self-correct

## Plugin Structure

- `plugins/agent-atelier/skills/` — 9 skills: init, status, wi, execute, candidate, validate, gate, watchdog, run
- `plugins/agent-atelier/hooks/` — Lifecycle hooks: UserPromptSubmit, PreToolUse (destructive command blocking), Stop, SubagentStop (dangling obligation check), TaskCompleted (artifact verification), TeammateIdle (auto-assignment), TaskCreated (budget validation)
- `plugins/agent-atelier/scripts/` — `state-commit` (atomic multi-file writer), `build-vrm-prompt` (VRM evidence input builder)
- `plugins/agent-atelier/schema/` — `vrm-evidence-input.schema.json`
- `plugins/agent-atelier/references/` — paths, state-defaults, wi-schema, recovery-protocol, success-metrics-routing
- `plugins/agent-atelier/references/prompts/` — 10 production role prompts (orchestrator, state-manager, pm, architect, builder, vrm, qa-reviewer, ux-reviewer, ui-designer, aesthetic-ux-reviewer)
- `.claude/agents/` — 7 subagent definitions (state-manager, pm, architect, builder, vrm, qa-reviewer, ux-reviewer) with model/tools frontmatter referencing role prompts

## Orchestration State

Runtime state lives in `.agent-atelier/` (gitignored). All writes go through `state-commit` script (sole writer guarantee). Key files:
- `.agent-atelier/loop-state.json` — control plane (mode, active candidate, open gates)
- `.agent-atelier/work-items.json` — WI store (status, lease, promotion, completion)
- `.agent-atelier/watchdog-jobs.json` — timeout thresholds and operating budgets

## Agent Teams

Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (set in `.claude/settings.json`). Teammates are spawned using subagent definitions from `.claude/agents/` which declare model and tools per role. Role prompt bodies from `plugins/agent-atelier/references/prompts/` are appended as additional instructions.

Known limitation: `skills` and `mcpServers` frontmatter in agent definitions are ignored for teammates (Issue #30703). Hooks are project-level only.

## Native Task Integration

Work items use a dual-layer model: native Agent Teams tasks provide visibility and automatic dependency resolution, while `work-items.json` maintains detailed state (leases, attempts, promotion, 8 statuses).

Status mapping:

| WI Status | Native Task Status |
|-----------|-------------------|
| pending, ready, blocked_on_human_gate | pending |
| implementing, candidate_queued, candidate_validating, reviewing | in_progress |
| done | completed |

Sync points: `wi upsert` (TaskCreate + dependency wiring), `execute claim/requeue/complete` (TaskUpdate), `candidate clear --demoted` (TaskUpdate). Native tasks use subject prefix matching (`"WI-NNN:"`) for lookup since `TaskList`/`TaskGet` do not return metadata. Metadata is still set on `TaskCreate` for informational purposes. Sync is best-effort; `work-items.json` is always the source of truth.

## Plan Approval

Complex work items spawn Builders with `mode: "plan"` — the Builder starts in read-only plan mode, proposes via `ExitPlanMode`, and the Orchestrator receives a structured `plan_approval_request` with `request_id`. After approval (`plan_approval_response`), the Builder auto-transitions to `bypassPermissions` for implementation. Simple WIs spawn with `mode: "acceptEdits"` (immediate implementation). The Architect sets `complexity` on every WI during BUILD_PLAN. The Orchestrator reviews plans per the Plan Review Protocol in `references/prompts/orchestrator.md`.

## Skill Format

Every skill is a `SKILL.md` with YAML frontmatter:

```yaml
---
name: skill-name
description: "One-line description"
argument-hint: "[optional args]"
---
```

Followed by markdown sections: When This Skill Runs, Prerequisites, Allowed Tools, Write Protocol, Subcommands, Exit Codes, Input Conventions, Output Contract, Idempotency, Error Handling, Constraints.

## Testing

```bash
bash tests/all.sh
```

## Knowledge Vault
- A UserPromptSubmit hook reminds you to query the vault when active entries exist
- When the hook fires and the task involves code modifications, query before planning:
  - Single file: `knowledge-gate query-paths <file-path>` (summary index by default)
  - Multiple files: `knowledge-gate domain-resolve-path <path>` → `knowledge-gate query-domain <domain>` (summary index by default)
  - Topic search: `knowledge-gate search <keyword>` (summary index by default)
  - Fetch full details only for the specific entries you need: `knowledge-gate get <id>` or `knowledge-gate get-many <id...>`
- MUST/MUST-NOT rules from returned entries must be strictly followed
- For structural changes in areas without related rules, confirm with a human first
- Do not directly read files in the .knowledge/ directory

## Memento
- After every git commit, attach a memento session summary as a git note on `refs/notes/commits`
- The summary follows the 7-section format: Decisions Made, Problems Encountered, Constraints Identified, Open Questions, Context, Recorded Decisions, Vault Entries Referenced
- See `/knowledge-distillery:memento-commit` for the full workflow and format specification
- If the PostToolUse hook fires a reminder, follow it — generate the summary and attach the note
