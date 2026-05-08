---
name: plan
description: "Run a planning cycle (DISCOVER → SPEC_DRAFT → SPEC_HARDEN → BUILD_PLAN) with ping-pong clarifying questions and a final approval gate. Use when starting a new feature, when spec or work items need rework, or when the user wants explicit plan review before execution. Triggers on 'plan', 'planning', 'review the plan', 'rework spec', 'redesign work items'."
argument-hint: "(no args)"
---

# Plan — Planning Cycle Entry Point

Run the explicit planning cycle: DISCOVER → SPEC_DRAFT → SPEC_HARDEN → BUILD_PLAN, gated by a ping-pong clarifying-question loop and a final approval gate. Produces an approved spec + WI backlog. Does NOT enter IMPLEMENT — `mode` stays at `BUILD_PLAN` after gate approval; the next `/agent-atelier:execute` performs the atomic transition into IMPLEMENT.

Reference spec: `docs/superpowers/specs/2026-05-08-plan-execute-workflow-design.md` — sections "사용자 멘탈 모델", "계획 단계의 핑퐁 루프", "최종 승인 게이트", "Atomicity 요구".

## When This Skill Runs

Per spec section "사용자 멘탈 모델":

- User wants an explicit planning cycle before implementation (`/agent-atelier:plan`)
- Spec or work items need rework after a previous approval — running `/plan` again with a valid `plan_approval` is a deliberate signal to re-enter DISCOVER and open a new gate
- User wants spec/WI design reviewed via ping-pong before any execution

This skill does NOT auto-trigger from `/agent-atelier:execute`. The execute skill embeds the same planning flow when no valid `plan_approval` exists; users invoke `/plan` directly when they want planning isolated from execution.

## Prerequisites

- Git repository (skill runs `git rev-parse --show-toplevel`)
- `.agent-atelier/` may or may not exist (Phase 1 auto-bootstraps if missing)

## Allowed Tools

- Read (state files, jsonl conversation log, behavior spec)
- Bash (git root detection, init-helpers.sh, state-commit, _plan_hash.py invocation)
- AskUserQuestion (primary path for ClarifyingQuestion presentation per spec)
- Agent (spawn PM, Architect, State Manager teammates)
- SendMessage (route ClarifyingQuestion forwards/back, broadcast roster)
- TaskCreate, TaskUpdate (native Agent Teams task sync after `wi upsert` returns native_task_sync hint)
- CronCreate, CronList (24h plan-gate watchdog awareness — optional during plan cycle)

## Phase 1: Bootstrap

1. Detect repo root: `repo=$(git rev-parse --show-toplevel)`
2. Resolve plugin root: `plugin_root="$repo/plugins/agent-atelier"` (or use `${CLAUDE_PLUGIN_ROOT}` if set; both must point at the same path).
3. Run init helpers (idempotent — only creates missing files, preserves existing values):
   ```bash
   bash "$plugin_root/scripts/init-helpers.sh" --root "$repo"
   ```
4. Confirm `.agent-atelier/loop-state.json`, `work-items.json`, `watchdog-jobs.json`, and `plan-conversations/` exist after the helper completes.

## Phase 2: Resume or Start Cycle

1. Read `.agent-atelier/loop-state.json`.
2. If `loop-state.active_plan_cycle_id` is non-null:
   - **Resume.** Per `references/recovery-protocol.md` Step 2.5, read `.agent-atelier/plan-conversations/<cycle-id>.jsonl`'s last entry and pick up at the resume action implied by its type (clarifying_question → re-present, user_response → forward to role, phase_transition → continue, no_more_questions → check phase advancement, gate_presented → re-present, gate_resolved with `y` but null `plan_approval` → re-check after WAL replay).
   - Skip cycle creation; proceed to Phase 3 with the existing cycle id.
3. If `loop-state.active_plan_cycle_id` is null:
   - **Start.** Generate a new cycle id: `cycle-$(date -u +%Y%m%dT%H%M%SZ)` (e.g., `cycle-20260508T103000Z`).
   - Compute the FINAL_REVIEW timestamp anchor: `opened_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)`.
   - Pipe a single state-commit transaction setting both fields atomically (single transaction, never split):
     ```json
     {
       "based_on_revision": <current loop-state revision>,
       "loop_state": {
         "active_plan_cycle_id": "cycle-20260508T103000Z",
         "plan_gate": {"opened_at": "2026-05-08T10:30:00Z", "phase": "DISCOVER"}
       }
     }
     ```
   - Create the empty jsonl file at `.agent-atelier/plan-conversations/<cycle-id>.jsonl` (append-only from here).

## Phase 3: Spawn Core Team

Per spec scope: only the planning roles. **Do NOT spawn Builders, VRM, or reviewers in this skill** — those belong to the IMPLEMENT phase owned by `/agent-atelier:execute`.

1. Derive team name (per `skills/execute/reference/team-lifecycle.md` "Team Name Derivation"). Persist via state-commit if not already set.
2. Stale team cleanup (if `~/.claude/teams/<team_name>/` exists — same procedure as execute's team-lifecycle reference).
3. `TeamCreate(team_name=<derived>, description="Plan cycle — ping-pong loop")`
4. Spawn three teammates by referencing plugin-scoped agent types:
   - State Manager: `agent-atelier:state-manager` (model `sonnet`, mode `acceptEdits`)
   - PM: `agent-atelier:pm` (model `opus`, mode `acceptEdits`)
   - Architect: `agent-atelier:architect` (model `opus`, mode `acceptEdits`)
5. Inject the team roster into each teammate's prompt (per execute team-lifecycle reference "Team Roster Injection").

## Phase 4: Ping-Pong Loop

Drive phase progression DISCOVER → SPEC_DRAFT → SPEC_HARDEN → BUILD_PLAN per spec section "계획 단계의 핑퐁 루프". The Orchestrator (you, the lead agent) hosts the loop; PM/Architect emit ClarifyingQuestion via SendMessage; you route them through `AskUserQuestion` and back.

Phase progression rules:

| Phase | Active Role(s) | Phase exit signal |
|-------|----------------|-------------------|
| DISCOVER | PM | PM emits `no_more_questions` |
| SPEC_DRAFT | PM (Architect consultation) | PM emits `no_more_questions` |
| SPEC_HARDEN | PM ↔ Architect (mutual) | **Both** emit `no_more_questions` at the same round number |
| BUILD_PLAN | Architect | Architect emits `no_more_questions` |

Per round:

1. Active role(s) emit up to 3 ClarifyingQuestions via SendMessage to the Orchestrator (per spec "질문 출제 단위" — `AskUserQuestion`'s 4-cap leaves a meta slot).
2. Orchestrator appends a `clarifying_question` entry to `plan-conversations/<cycle-id>.jsonl` for each.
3. Orchestrator presents the bundle via `AskUserQuestion`. Each question's options are: `<options array>` + `"네가 결정"` + `"잠깐, 내가 묻고 싶어"` (do NOT add a separate "Other" option — `AskUserQuestion` provides the free-text Other automatically).
4. Orchestrator receives the response, appends a `user_response` entry to the jsonl, and routes per spec table:
   - **Option chosen** → forward to emitting role; role updates spec/WI artifacts.
   - **Other (free text)** → forward as a new answer; role updates artifacts.
   - **네가 결정** → role adopts `recommended` as an assumption; logs to PM's assumptions log with `cycle-<id>/CQ-<NNN>` prefix.
   - **잠깐, 내가 묻고 싶어** → Orchestrator collects the user's follow-up question and forwards it to PM/Architect (real ping-pong reversal).
5. After artifact updates, Orchestrator appends an `artifact_update` entry to jsonl with `{artifact_path, before_revision, after_revision, diff_summary}`. Show the user a short diff summary.
6. Active role decides: more questions → next round, or `no_more_questions` signal.

Real-time question budget enforcement (Orchestrator, not watchdog — per spec "실시간 예산 enforcement"):

- After each round, count cumulative `clarifying_question` entries in the jsonl.
- > 25 cumulative → all NEW ClarifyingQuestions in subsequent rounds are forced to `blocking: false`.
- > 30 cumulative → notify the user "스코프가 너무 큰 것 같습니다 — 분해하시겠어요?" and pause the plan (set `plan_gate.opened_at` to now if not already set; do NOT advance phase). Wait for user input before continuing.

Infinite-pingpong guard (per spec "안전장치"): if a single phase repeats round 5+ times without progress, notify the user "이 phase 진행에 어려움이 있습니다 — spec 명확화 또는 진행 방향 결정 부탁드립니다".

`active_plan_cycle_id` is the authoritative resume anchor. Never infer from filename mtime.

## Phase 5: Final Gate

When BUILD_PLAN's `no_more_questions` signal fires (and SPEC_HARDEN's mutual exit was satisfied earlier):

1. Append a `gate_presented` entry to jsonl with phase `FINAL_REVIEW`.
2. Update `loop-state.plan_gate` via state-commit: `{opened_at: <now>, phase: "FINAL_REVIEW"}`.
3. Build the summary per spec section "최종 승인 게이트":

   ```
   === Plan Stable. Ready for Implementation? ===
   Spec: <N> behaviors (<X> added/changed during plan)
   WIs:  <M> ready (complexity S:<a> / M:<b> / L:<c>, 모두 verify ≥1)
   사용자 결정사항: <K>건 (CQ-001 ~ CQ-<NNN>, 로그 보기: ...)
   가정으로 진행한 항목: <J>건 (사용자가 "네가 결정"한 케이스)

   진행할까요? [y / 더 검토 / 수정 <피드백>]
   ```

   Present via `AskUserQuestion` with options `["y", "더 검토", "수정"]` (Other captures `수정 <text>` free text).

4. Branch on response:

   - **`y`**: Compute the canonical `wi_plan_hash` (via `python3 -c "import sys; sys.path.insert(0, '$plugin_root/scripts'); from _plan_hash import wi_plan_hash; ..."` or run a small wrapper script) and `spec_hash` (`spec_hash("docs/product/behavior-spec.md")` from same module). Pipe one atomic state-commit transaction containing the **`/plan` context** changes per spec "Atomicity 요구" table:

     ```json
     {
       "based_on_revision": <current>,
       "loop_state": {
         "plan_approval": {
           "approved_at": "<UTC ISO>",
           "wi_plan_hash": "sha256:...",
           "spec_hash": "sha256:..." | "null",
           "approved_by": "user"
         },
         "active_plan_cycle_id": null,
         "plan_gate": null
       }
     }
     ```

     **`mode` MUST stay `BUILD_PLAN`.** The next `/agent-atelier:execute` performs the atomic BUILD_PLAN→IMPLEMENT transition (state-commit's mechanical IMPLEMENT-mode gate enforces this — caller cannot bypass).

     Append `gate_resolved` entry to jsonl with `{choice: "y"}` AFTER state-commit succeeds (so a crash mid-resolve replays via WAL and we re-check).

     Exit 0 with the output JSON below.

   - **`더 검토`**: Append `gate_resolved` entry with `{choice: "더 검토"}`. Run one more empty round (active role emits zero questions but is invited to). If still stable, re-present the gate. Loop until `y` or `수정`.

   - **`수정 <피드백>`**: Parse the free text to identify the target phase (Orchestrator judgment — typically "spec" → SPEC_DRAFT, "WI" → BUILD_PLAN, "scope" → DISCOVER, "audit" → SPEC_HARDEN). Set `loop-state.mode` back to that phase via state-commit. Append `phase_transition` entry to jsonl. Restart Phase 4 from that phase. Do NOT clear `active_plan_cycle_id` — same cycle continues.

5. If BUILD_PLAN exits with **0 ready WIs** (per spec "루프 종료 조건"), the gate text reads `진행할까요? [y → DONE 단축]`. On `y`, the atomic transaction is the same `/plan` context (no IMPLEMENT transition; the next `/execute` will short-circuit to DONE since 0 WIs to do).

## Output Contract

On gate-pass exit (after the `y` transaction commits), return JSON to stdout:

```json
{
  "plan_approval": {
    "approved_at": "<UTC ISO>",
    "wi_plan_hash": "sha256:...",
    "spec_hash": "sha256:...",
    "approved_by": "user"
  },
  "cycle_id": "cycle-20260508T103000Z",
  "artifacts": [
    "docs/product/behavior-spec.md",
    ".agent-atelier/work-items.json",
    ".agent-atelier/plan-conversations/cycle-20260508T103000Z.jsonl"
  ]
}
```

On user-declined exit (no `y` choice ever taken; user aborts), exit 2 with `{"plan_approval": null, "cycle_id": "...", "reason": "user_declined"}` and leave `active_plan_cycle_id` set so the next `/plan` resumes.

Diagnostic messages go to stderr.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Plan approved (gate pass `y`) — `plan_approval` recorded, `mode` stays `BUILD_PLAN` |
| `1` | Usage error (skill received unexpected args) |
| `2` | User declined (aborted before approval) |
| `4` | Runtime failure (state-commit reject, IO error, agent spawn failure) |

## Idempotency

- Phase 1 (init-helpers) is idempotent — only creates missing files.
- Phase 2 (resume) is idempotent — same `active_plan_cycle_id` resumes the same jsonl.
- Phase 5 final transaction is single-shot via state-commit's revision check; concurrent attempts get `stale_revision` and retry.
- Re-running `/plan` with an active cycle resumes it; re-running with no active cycle starts a new one (deliberate behavior — user may want to re-plan after approval, which opens a new gate).

## Constraints

- **Single-writer for jsonl.** Only the Orchestrator (lead agent) appends to `.agent-atelier/plan-conversations/<cycle-id>.jsonl`. PM/Architect must NOT write directly — they emit ClarifyingQuestion via SendMessage.
- **All state mutations route through state-commit.** Atomic transactions per spec "Atomicity 요구".
- **No Builder/VRM/reviewer spawn in this skill.** IMPLEMENT-phase roles are spawned only by `/agent-atelier:execute` after the BUILD_PLAN→IMPLEMENT transition.
- **`active_plan_cycle_id` is the authoritative resume anchor** — never infer from filesystem mtime.
- **CQ id format:** `CQ-NNN` zero-padded, monotonically increasing per cycle, resets at cycle start (per spec "Cross-cycle 참조").
- **Cross-cycle citations** in PM's assumptions/decision logs use `cycle-<id>/CQ-NNN` prefix.
