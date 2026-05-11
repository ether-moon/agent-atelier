# plan/execute 워크플로우 + 핑퐁 루프 설계

**Date:** 2026-05-08
**Status:** Approved (design)
**Scope:** agent-atelier 플러그인 사용자 진입점 재설계

## 배경 / 동기

현재 사용자 진입점은 `/agent-atelier:init` (상태 파일 부트스트랩) 과 `/agent-atelier:run` (전체 자율 루프 실행) 두 단계로 나뉘어 있다. 두 가지 문제:

1. `init`이 별도 명령으로 노출돼 있어 워크플로우가 어색하다. 첫 사용자는 init이 무엇인지 모른 채 run을 실행하다 실패한다.
2. `run`은 DISCOVER → BUILD_PLAN → IMPLEMENT 까지 한번에 진행한다. 계획 단계에서 PM/Architect가 가정으로 채운 결정사항이 사용자 검토 없이 그대로 구현으로 흘러간다. 잘못된 분해/스코프가 IMPLEMENT 단계에서 발견되면 비용이 크다.

**목표:** 구현 진입 전에 계획 품질을 사용자와의 핑퐁으로 확실히 다지는 워크플로우.

## 사용자 멘탈 모델

```text
/agent-atelier:plan      ← 계획만 (선택적)
/agent-atelier:execute   ← 끝까지 실행 (필수 게이트 포함)
```

- `plan`은 명시적 계획 사이클을 돌리고 싶을 때 호출.
- `execute`는 항상 "현재 상태부터 끝까지" 책임지는 단일 진입점.
- 두 명령 모두 `.agent-atelier/` 미존재 시 자동 init.
- **`execute`는 plan을 절대 우회하지 않는다.** 승인된 plan이 없으면 자동으로 plan 단계부터 진행.
- 계획 단계에서 PM/Architect는 불확실한 채 진행하지 않는다 — 질문을 던져 사용자와 핑퐁한다.

## 호출별 동작 매트릭스

| 호출 | `plan_approval` 상태 | 동작 |
|------|----------------------|------|
| `/plan` | (무관) | 핑퐁 루프 → 안정화 → 최종 게이트 → y면 승인 기록 후 종료 |
| `/execute` | 없음 / 만료 | 내부적으로 plan 사이클 자동 실행 → 게이트 통과 후 → IMPLEMENT → DONE |
| `/execute` | 유효 | 곧장 IMPLEMENT → DONE |
| `/plan` 두 번째 호출 (승인 유효 상태) | 유효 | 사용자가 spec/WI 손보고 다시 검토 받고 싶다는 의사 → DISCOVER 재진입, 새 게이트 |

## 상태 모델

`loop-state.json`에 4개 필드 추가:

```json
{
  "plan_approval": {
    "approved_at": "2026-05-08T10:30:00Z",
    "wi_plan_hash": "sha256:abc...",
    "spec_hash": "sha256:def...",
    "approved_by": "user"
  },
  "active_plan_cycle_id": "cycle-20260508T103000Z",
  "plan_gate": {
    "opened_at": "2026-05-08T10:25:00Z",
    "phase": "FINAL_REVIEW"
  }
}
```

### `plan_approval` 필드

| 필드 | 의미 |
|------|------|
| `approved_at` | UTC timestamp, ISO 8601 with `Z` |
| `wi_plan_hash` | plan 차원 WI 정의의 hash (아래 산식 참조) |
| `spec_hash` | 승인 시점의 `docs/product/behavior-spec.md` SHA-256 (형식: `sha256:<64-hex>`). **파일 부재 시 `null`** — 첫 호출 invariant. |
| `approved_by` | 식별자 (현 단계는 `"user"` 고정) |

### `wi_plan_hash` 산식

`work-items.json` revision은 IMPLEMENT 단계의 status 전환마다 bump되므로 무효화 trigger로 부적합. 대신 **plan 차원 필드만** hash:

```text
wi_plan_hash = sha256( canonicalized JSON of:
  [ {id, title, description, depends_on, owned_paths, verify, complexity, status_class}
    for wi in items, sorted by id ] )
```

`status_class`는 lifecycle status를 plan 관점의 단일 bucket으로 collapse:

| status (work-items.json) | status_class |
|--------------------------|--------------|
| `pending`, `ready` | `unstarted` |
| `implementing`, `candidate_queued`, `candidate_validating`, `reviewing`, `done` | `in_progress_or_done` |
| `blocked_on_human_gate` | `blocked` |

**효과:** Builder의 status 전환은 hash를 바꾸지 않는다. WI 추가/제거, depends_on/owned_paths/verify/complexity 변경, status_class bucket 간 전환만 hash를 바꿔 plan 무효화 trigger.

### `active_plan_cycle_id`

활성 plan 사이클의 식별자. 형식: `cycle-<UTC-timestamp>` (예: `cycle-20260508T103000Z`).

| 시점 | 동작 |
|------|------|
| `/plan` 또는 `/execute` 첫 호출 (필드가 `null`) | 새 cycle 시작, 필드 기록 |
| `/plan` 또는 `/execute` 후속 호출 (필드가 non-null) | 활성 cycle 이어감 (cold resume 포함) |
| 게이트 통과 | `null`로 클리어 (plan_approval과 동일 transaction) |

이 필드가 cold resume의 권위 있는 anchor — `plan-conversations/<cycle-id>.jsonl` 마지막 이벤트부터 재개.

### `plan_gate` (24h 타이머 anchor)

최종 게이트 또는 핑퐁 라운드가 사용자 응답을 대기 중인 상태를 추적:

| 필드 | 의미 |
|------|------|
| `opened_at` | 게이트 또는 라운드 시작 시각 (UTC) |
| `phase` | 어느 phase의 라운드인지 (`DISCOVER` \| `SPEC_DRAFT` \| `SPEC_HARDEN` \| `BUILD_PLAN` \| `FINAL_REVIEW`) |

watchdog이 `opened_at`을 보고 24h 초과 시 plan을 `paused`로 표시. 사용자 응답 도착 시 클리어.

### 무효화 조건

다음 `/execute` 호출 시 plan 재실행 trigger:

- `plan_approval`이 `null` 또는 부재
- 현재 계산한 `wi_plan_hash`가 저장된 값과 다름
- 현재 계산한 `behavior-spec.md`의 `sha256:<hex>`가 저장된 `spec_hash`와 다름 (또는 한쪽만 `null`)

사용자가 손으로 spec/work-items.json을 수정해도 자동 감지.

### Atomicity 요구

**모든 게이트 통과는 단일 state-commit transaction.** 다음 경우별로 한 transaction 안에서 다음을 함께 기록:

| 게이트 통과 컨텍스트 | 한 transaction에 포함되는 변경 |
|--------------------|-----------------------------|
| `/execute` gate-pass | `plan_approval` 객체 + `mode: BUILD_PLAN → IMPLEMENT` + `active_plan_cycle_id: null` + `plan_gate: null` |
| `/plan` 단독 gate-pass | `plan_approval` 객체 + `active_plan_cycle_id: null` + `plan_gate: null`. **`mode`는 BUILD_PLAN 유지.** 다음 `/execute` 호출이 atomic하게 IMPLEMENT 전환. |

### state-commit Semantic Enforcement

`mode: BUILD_PLAN → IMPLEMENT` 전환은 **state-commit이 거부할 수 있는 mechanical gate**:

- 동일 transaction에 유효한 `plan_approval` 객체가 함께 있어야 함
- transaction 시점에 다시 계산한 `wi_plan_hash` / `spec_hash`가 transaction의 `plan_approval`과 일치해야 함

caller(plan/execute skill)가 게이트를 우회해도 state-commit이 reject. 사용자 의도("plan은 절대 우회되지 않는다")가 mechanical하게 보장됨.

## 계획 단계의 핑퐁 루프

### 원칙

PM과 Architect는 **불확실한 채 진행하지 않는다.** 가정이 필요할 때마다 사용자에게 질문(ClarifyingQuestion)을 발행하고 답을 받아야만 다음으로 진행한다.

### Phase별 질문 발생 지점

| Phase | 활성 역할 | 질문 예시 |
|-------|---------|-----------|
| DISCOVER | PM | spec gap("로그인 실패 횟수 제한 정책 미정"), 모호 요구("이메일 vs 유저네임") |
| SPEC_DRAFT | PM | 검증 가능한 행동 표현 시 경계 케이스("비밀번호 재설정 토큰 만료 시간") |
| SPEC_HARDEN | PM ↔ Architect | 상호 감사 중 모순 발견("spec은 동기인데 NFR은 비동기") |
| BUILD_PLAN | Architect | WI 분해 결정, 의존성 처리(외부 API mock vs 실제), 복잡도 경계 |

### ClarifyingQuestion 메시지 형식

PM/Architect가 Orchestrator에게 SendMessage로 발행:

```json
{
  "id": "CQ-001",
  "from_role": "PM",
  "phase": "DISCOVER",
  "topic": "로그인 실패 횟수 제한",
  "question": "한 IP/계정당 N회 실패 시 어떻게 처리?",
  "options": [
    "5회 후 15분 잠금",
    "지수 백오프",
    "잠금 없음, 모니터링만"
  ],
  "recommended": "5회 후 15분 잠금",
  "reasoning": "OWASP 가이드 + 사용자 락아웃 회복 비용 균형",
  "blocking": true
}
```

| 필드 | 의미 |
|------|------|
| `id` | `CQ-NNN` 형식, plan cycle 내 단조 증가 (cycle 시작마다 `CQ-001`로 리셋) |
| `from_role` | `"PM"` 또는 `"Architect"` |
| `phase` | 발행 시점의 phase |
| `topic` | 짧은 주제(15자 내외) |
| `question` | 사용자에게 보여줄 질문 본문 |
| `options` | 가능하면 multiple choice 제시 (없으면 빈 배열) |
| `recommended` | 권장 답 (`options` 중 하나 또는 자유 텍스트) |
| `reasoning` | 권장 근거(1-2문장) |
| `blocking` | true면 답 받기 전 phase 진행 불가; false면 사용자가 응답에서 이 질문을 건너뛴 경우(Other 입력 비움 또는 "네가 결정" 선택) 권장안을 가정으로 자동 채택. 누적 25 초과 시 모든 신규 질문은 강제 false |

### 사용자 응답 처리 — `AskUserQuestion`을 primary path로

Orchestrator는 라운드의 질문 묶음을 **`AskUserQuestion` 도구**로 사용자에게 제시하는 것을 기본 경로로 한다. 각 CQ가 별개의 question으로, options 배열은 CQ의 `options` + `"네가 결정"` + `"잠깐, 내가 묻고 싶어"` 메타옵션을 포함:

```json
{
  "questions": [
    {
      "question": "[CQ-003] 한 IP/계정당 N회 실패 시 어떻게 처리?",
      "options": ["5회 후 15분 잠금 (권장)", "지수 백오프", "잠금 없음, 모니터링만", "네가 결정", "잠깐, 내가 묻고 싶어"]
    },
    {
      "question": "[CQ-004] 비밀번호 재설정 토큰 만료 시간?",
      "options": ["15분 (권장)", "1시간", "24시간", "네가 결정", "잠깐, 내가 묻고 싶어"]
    }
  ]
}
```

**선택지 외 자유 텍스트가 필요할 땐** `AskUserQuestion`이 자동 제공하는 `Other` 입력으로 받는다 (도구 자체 동작). Orchestrator는 별도 "다른 답" 옵션을 넣지 않는다.

| 사용자 선택 | 처리 |
|-----------|------|
| 본 옵션 중 하나 | 해당 옵션 채택, 발행 role에게 전달 |
| `Other` (자유 텍스트) | 새 답변으로 채택, role이 spec/WI 갱신 |
| `네가 결정` | role이 `recommended`를 가정으로 채택, PM의 assumptions log에 기록 |
| `잠깐, 내가 묻고 싶어` | 메타 응답 — Orchestrator가 후속 질문을 받아 PM/Architect에 forward (진짜 핑퐁) |

질문 답변 후 spec/WI 변경분 diff 요약을 Orchestrator가 사용자에게 보여준다(짧게).

### 질문 출제 단위

한 라운드에서 한 role이 **최대 3개**까지 묶어서 출제 가능. `AskUserQuestion`의 4-question cap에 맞춤 (1슬롯 여유는 향후 확장용). 3개 초과 시 라운드를 나눔.

### 루프 종료 조건

활성 role은 한 phase의 라운드 끝에 **`no_more_questions` 시그널**을 JSONL에 기록 (Orchestrator를 통해):

```json
{"type": "no_more_questions", "from_role": "PM", "phase": "DISCOVER", "round": 3, "ts": "..."}
```

- 단일-role phase (DISCOVER, SPEC_DRAFT, BUILD_PLAN): 해당 role이 한 번만 시그널 → phase 종료.
- 양쪽-role phase (SPEC_HARDEN: PM ↔ Architect): **양쪽 모두** 같은 round 번호로 시그널 발행해야 phase 종료.
- 모든 phase가 종료되면 최종 게이트로 진입.
- **BUILD_PLAN 종료 시 ready WI가 0개면** 최종 게이트가 `진행할까요? [y → DONE 단축]` 형식으로 분기 (IMPLEMENT 거치지 않고 바로 DONE).

### 실시간 예산 enforcement

질문 예산(30개)은 **Orchestrator가 라운드마다 실시간으로** 확인:

- 누적 25 초과 → 신규 질문은 강제 `blocking: false` 처리.
- 누적 30 초과 → 사용자에게 "스코프가 너무 큰 것 같습니다 — 분해하시겠어요?" 알림. plan 일시정지.

watchdog은 cross-session visibility용 알림만 발행. 임계 판단은 orchestrator에 있음 (15분 cycle 너무 늦음).

### 영속성 — Orchestrator가 단일 작성자

`.agent-atelier/plan-conversations/<plan-cycle-id>.jsonl` 에 모든 이벤트(질문 발행, 응답 수신, artifact 갱신, phase 전환, no_more_questions, 게이트 시작/종료)를 append.

**Orchestrator만 이 파일에 append한다.** PM/Architect는 ClarifyingQuestion을 SendMessage로 Orchestrator에 전달, Orchestrator가 jsonl 기록 + 사용자 표시 + 응답 라우팅. PM/Architect 직접 쓰기 금지 (race 방지). 이는 single-writer 모델의 plan 사이클 확장.

JSONL 한 라인 = 한 이벤트. 세션 재시작 시 `loop-state.active_plan_cycle_id`가 가리키는 jsonl의 마지막 이벤트부터 재개.

**Cross-cycle 참조:** PM의 `assumptions.md` / `decision-log.md` 등 외부 문서가 CQ를 인용할 때는 cycle-id prefix를 포함 (예: `cycle-20260508T103000Z/CQ-001`). cycle 내부에서는 `CQ-NNN`만 사용 (cycle 시작마다 `CQ-001`로 reset).

## 최종 승인 게이트

모든 phase가 "질문 없음" 상태로 안정화되면 BUILD_PLAN 종료 시 통합 리뷰 한 번:

```text
=== Plan Stable. Ready for Implementation? ===
Spec: 12 behaviors (3 added/changed during plan)
WIs:  5 ready (complexity S:2 / M:2 / L:1, 모두 verify ≥1)
사용자 결정사항: 8건 (CQ-001 ~ CQ-008, 로그 보기: ...)
가정으로 진행한 항목: 2건 (사용자가 "네가 결정"한 케이스)

진행할까요? [y / 더 검토 / 수정 <피드백>]
```

| 응답 | 처리 |
|------|------|
| `y` | `상태 모델 / Atomicity` 표대로 단일 state-commit transaction 실행. `/execute`면 IMPLEMENT 진입, `/plan`이면 BUILD_PLAN 유지. 0 WI면 IMPLEMENT 거치지 않고 DONE 분기. |
| `더 검토` | 빈 라운드 한 번 더 — 사용자가 추가 의문 던질 기회 |
| `수정 <피드백>` | 피드백을 적절한 phase로 라우팅, 핑퐁 재시작. 라우팅된 phase로 `loop-state.mode` 되돌림. |

## 안전장치

| 항목 | 동작 | 책임 주체 |
|------|------|---------|
| 질문 예산 (실시간) | 누적 25 초과 시 신규 질문 강제 `blocking: false`. 누적 30 초과 시 사용자 알림 + plan 일시정지 | Orchestrator (라운드 시작마다 카운트 확인) |
| Blocking vs non-blocking | blocking이면 답 받기 전 phase 진행 불가; non-blocking은 사용자가 건너뛰면 권장안 자동 채택 | Orchestrator |
| 사용자 부재 감지 | `loop-state.plan_gate.opened_at`이 24h 초과면 plan을 `paused`로 표시. 다음 `/plan`/`/execute` 호출 시 같은 자리서 재개 | watchdog (15분 tick) |
| Cold resume | `loop-state.active_plan_cycle_id`가 가리키는 jsonl 마지막 이벤트부터 재개 | plan/execute skill (호출 시 첫 단계) |
| Mechanical IMPLEMENT 게이트 | state-commit이 `mode: IMPLEMENT` 전환 시 동일 transaction의 `plan_approval` 유효성 검사. 우회 시 reject (exit 2) | state-commit |
| 무한 핑퐁 방지 | 단일 phase에서 같은 round 번호로 5회 이상 재진행되면 사용자에게 "이 phase 진행에 어려움이 있습니다 — spec 명확화 또는 진행 방향 결정 부탁드립니다" 알림 | Orchestrator |

## 사용자 진입점 vs 내부 메커니즘

운영 도구를 **3개의 사용자 진입점 + scripts/ 메커니즘 + monitors 얇은 shim** 구조로 정리. Claude Code의 skill 자동 발견을 사용자 표면으로 활용하되, monitors처럼 cron-callable + 자연어 trigger가 필요한 항목은 명시적으로 shim으로 남긴다.

### 사용자 진입점 (skills/)

| 명령 | 역할 |
|------|------|
| `/agent-atelier:plan` | 계획만. 핑퐁 루프 + 최종 게이트. 산출물: 승인된 spec + WI 백로그 |
| `/agent-atelier:execute` | 끝까지 실행. 승인된 plan 없으면 자동 plan 사이클 |
| `/agent-atelier:status` | 현재 오케스트레이션 대시보드 (read-only) |

### Internal-by-usage skill shim (skills/)

`monitors`는 LLM 전용 도구(`Bash run_in_background`, `TaskOutput`, `TaskStop`)에 의존하고, cron prompt가 절대경로 substitute 없이 안정적으로 호출하려면 슬래시 명령 형태가 필요하다. 따라서 `skills/monitors/`는 **frontmatter description만 유지하는 thin shim**으로 남기고, 본문은 `references/monitor-runtime.md`로 위임:

```markdown
---
name: monitors
description: "[INTERNAL — invoked by orchestrator/cron, not for direct user use] Background monitor lifecycle ..."
argument-hint: "spawn | check ... | stop ... | spawn-ci ..."
---

# Monitors — Internal Skill Shim

This skill is invoked **only** by the orchestrator or cron jobs. Users should not invoke it directly. Full procedure is documented in `<plugin-root>/references/monitor-runtime.md` — read that file before executing any subcommand.
```

이 패턴은 **slash 명령 안정성** + **자연어 자동 발견** + **단순화된 user mental model**을 모두 만족한다. AGENTS.md에 "skills/monitors는 internal-by-usage" 명시.

### 내부 메커니즘 (scripts/)

기존 슬래시 명령은 모두 bash/python 스크립트로 변환. 호출 방식은 `bash <plugin-root>/scripts/<name> <subcommand>` 형태. 출력은 JSON.

| 기존 skill | 신규 위치 | 비고 |
|-----------|----------|------|
| `skills/init/` | `scripts/init-helpers.sh` | plan/execute 두 skill이 호출. **기존 install 마이그레이션 포함**: 누락 top-level key를 defaults에서 머지 (nested 필드는 손대지 않음, 절대 overwrite 안 함) |
| `skills/wi/` | `scripts/wi` | list / show / upsert. natural-language input은 호출자가 JSON으로 변환. 출력에 `native_task_sync` hint 포함 (아래 참조) |
| `skills/execute/` (현 lifecycle) | `scripts/lifecycle` | claim / heartbeat / requeue / complete / attempt. native_task_sync hint 포함 |
| `skills/gate/` | `scripts/gate` | list / create / resolve |
| `skills/watchdog/` | `scripts/watchdog` | tick (mechanical recovery). 알림만 발행, 임계 enforcement는 orchestrator |
| `skills/candidate/` | `scripts/candidate` | enqueue / activate / clear. native_task_sync hint 포함 |
| `skills/validate/` | `scripts/validate` | record. native_task_sync hint 포함 |
| `skills/run/` | (제거) | 모든 logic이 새 `skills/execute/`로 이전 |

### 내부 메커니즘 (references/)

| 신규 파일 | 비고 |
|---------|------|
| `references/monitor-runtime.md` | monitors의 LLM-driven 절차서 (이전 `skills/monitors/SKILL.md` + `reference/event-classification.md` 통합). skills/monitors/ shim에서 위임받음 |

### Native Task Sync 패턴

`work-items.json` mutation을 일으키는 스크립트(`wi`, `lifecycle`, `candidate`, `validate`)는 **`TaskCreate`/`TaskUpdate`를 호출할 수 없다** (LLM 전용 도구). 대신 stdout JSON에 `native_task_sync` hint를 포함:

```json
{
  "accepted": true,
  "committed_revision": 42,
  "artifacts": [".agent-atelier/work-items.json"],
  "native_task_sync": {
    "action": "update",
    "subject_prefix": "WI-014:",
    "new_status": "in_progress",
    "metadata": {"complexity": "complex"}
  }
}
```

호출자(Orchestrator 또는 State Manager)는 스크립트 성공 후 hint를 읽고 LLM-side `TaskCreate` 또는 `TaskUpdate`를 실행. 이는 single-writer 모델 보존 (script ≠ task tool, 명시적 두 단계).

`orchestrator.md` 프롬프트에 "mutating script 호출 후 반드시 hint 처리" 규칙 명시.

### 내부 호출자 업데이트

기존 `/agent-atelier:foo bar` 호출을 새 위치로 일괄 변경 (전 repo 대상):

- `plugins/agent-atelier/references/prompts/orchestrator.md`
- `plugins/agent-atelier/references/prompts/output-discipline.md`
- `plugins/agent-atelier/references/recovery-protocol.md`
- `plugins/agent-atelier/agents/builder.md`, `architect.md`, `pm.md`
- `plugins/agent-atelier/hooks/on-stop.sh`
- `plugins/agent-atelier/hooks/on-task-completed.sh`
- `plugins/agent-atelier/skills/status/SKILL.md`
- 새 `plugins/agent-atelier/skills/plan/SKILL.md`, `skills/execute/SKILL.md` 내부
- cron prompt 텍스트 (execute skill이 CronCreate에 넣는 prompt — `<plugin-root>`를 절대경로로 substitute해서 저장)
- `tests/orchestration_contracts.sh`
- `tests/recovery_contracts.sh`
- `tests/all.sh`
- `docs/design/cli-surface.md`
- `docs/design/system-design.md`
- `docs/design/session-limit-retry.md`
- `docs/design/recovery-spec.md`
- `skills/wi/reference/native-task-sync.md` (해당 reference는 wi 삭제 시 함께 정리)
- `skills/monitors/reference/event-classification.md` (monitor-runtime.md로 통합)
- `skills/run/reference/state-machine.md`, `team-lifecycle.md` (execute로 이동)
- `AGENTS.md`

`monitors`는 `skills/monitors/SKILL.md` shim이 슬래시 호출을 그대로 받으므로, 슬래시 호출은 그대로 유지. shim 본문이 references/monitor-runtime.md를 읽도록만 변경.

**스크립트 호출 형태 (예시):**

| 이전 | 변경 후 |
|------|---------|
| `/agent-atelier:execute claim WI-014` | `bash <plugin-root>/scripts/lifecycle claim WI-014 --owner <session>` |
| `/agent-atelier:watchdog tick` | `bash <plugin-root>/scripts/watchdog tick` |
| `/agent-atelier:wi upsert <json>` | `bash <plugin-root>/scripts/wi upsert <json>` (호출 후 native_task_sync hint 처리) |
| `/agent-atelier:gate resolve HDR-001 --chosen 1` | `bash <plugin-root>/scripts/gate resolve HDR-001 --chosen 1` |
| `/agent-atelier:candidate enqueue WI-014,WI-015` | `bash <plugin-root>/scripts/candidate enqueue WI-014 WI-015` |
| `/agent-atelier:monitors check {...}` | **그대로 유지** (skills/monitors/ shim) |

`<plugin-root>` resolve 규칙:
- role 프롬프트 안: `${CLAUDE_PLUGIN_ROOT}` 환경변수 (Claude Code가 spawn 시 주입)
- hook 스크립트: `${CLAUDE_PLUGIN_ROOT}` 동일
- cron prompt: CronCreate 시점에 절대경로로 substitute해서 저장 (fire-time에는 substitution 안 일어남)

### PreToolUse Hook Audit

`hooks/on-pre-tool-use.sh`는 destructive bash 패턴을 차단한다. `bash <plugin-root>/scripts/*` 호출이 잘못 차단되지 않도록 audit 필요:

- `requeue`, `clear`, `delete`-flavored 동사 검사 패턴이 `scripts/lifecycle requeue`, `scripts/candidate clear` 등을 잡지 않는지 확인
- 필요 시 `<plugin-root>/scripts/` 경로를 allowlist에 추가

### tests/all.sh 갱신

현재 하드코딩된 expected list (10개 skill — 이전 사양은 9개로 잘못 적혀 있었음):
```bash
EXPECTED_SKILLS="init status wi execute gate watchdog candidate validate run monitors"
```

변경 후 (사용자 진입점 3 + monitors shim):
```bash
EXPECTED_SKILLS="plan execute status monitors"
EXPECTED_SCRIPTS="state-commit init-helpers.sh wi gate watchdog candidate validate lifecycle"
EXPECTED_REFERENCES="paths.md state-defaults.md wi-schema.md recovery-protocol.md success-metrics-routing.md monitor-runtime.md"
```

추가로 `EXPECTED_SCRIPTS` 각 항목이 chmod +x 처리됐는지(`-x` flag) 검증 추가.

## 변경 범위

### 신규 파일

- `plugins/agent-atelier/skills/plan/SKILL.md` — 부트스트랩 호출 + 핑퐁 루프 + 최종 게이트
- `plugins/agent-atelier/skills/execute/SKILL.md` — 게이트 검증 + plan 자동 실행 + IMPLEMENT → DONE (기존 `run` skill을 base로)
- `plugins/agent-atelier/scripts/init-helpers.sh` — 상태 파일 부트스트랩 + WAL 복구
- `plugins/agent-atelier/scripts/wi` — list / show / upsert (Python으로 작성, native task sync 포함)
- `plugins/agent-atelier/scripts/lifecycle` — claim / heartbeat / requeue / complete / attempt
- `plugins/agent-atelier/scripts/gate` — list / create / resolve
- `plugins/agent-atelier/scripts/watchdog` — tick
- `plugins/agent-atelier/scripts/candidate` — enqueue / activate / clear
- `plugins/agent-atelier/scripts/validate` — record
- `plugins/agent-atelier/references/monitor-runtime.md` — monitors의 LLM-driven 절차 (이전 `skills/monitors/SKILL.md` + `reference/event-classification.md` 통합)
- `plugins/agent-atelier/schema/clarifying-question.schema.json` — ClarifyingQuestion JSON 스키마
- `plugins/agent-atelier/schema/plan-conversation-entry.schema.json` — JSONL 한 라인 이벤트 스키마
- `.agent-atelier/plan-conversations/` 디렉터리 (init 시 생성)

### 제거

- `plugins/agent-atelier/skills/init/` (전체 디렉터리)
- `plugins/agent-atelier/skills/run/` (전체 디렉터리)
- `plugins/agent-atelier/skills/wi/` (scripts로 이전, reference/native-task-sync.md는 monitor-runtime 참고하여 통합 폐기)
- `plugins/agent-atelier/skills/execute/` (scripts/lifecycle로 이전)
- `plugins/agent-atelier/skills/gate/` (scripts로 이전)
- `plugins/agent-atelier/skills/watchdog/` (scripts로 이전)
- `plugins/agent-atelier/skills/candidate/` (scripts로 이전)
- `plugins/agent-atelier/skills/validate/` (scripts로 이전)

### 변환 (skill → shim)

- `plugins/agent-atelier/skills/monitors/` — frontmatter만 유지하는 thin shim으로 축소 (본문은 references/monitor-runtime.md로 위임). `reference/event-classification.md`도 monitor-runtime.md로 통합 후 디렉터리 정리.

### 수정

- `plugins/agent-atelier/skills/status/SKILL.md` — `/agent-atelier:init` 언급을 새 구조 기반으로 갱신
- `plugins/agent-atelier/skills/monitors/SKILL.md` — thin shim으로 축소 (frontmatter + 본문은 `references/monitor-runtime.md` 위임)
- `plugins/agent-atelier/scripts/state-commit` — `mode: BUILD_PLAN → IMPLEMENT` 전환 시 동일 transaction의 `plan_approval` 유효성 mechanical 검사 추가 (지금까지 opaque였던 부분에 한 가지 semantic rule 도입)
- `plugins/agent-atelier/references/state-defaults.md` — `loop-state.json`에 `plan_approval: null`, `active_plan_cycle_id: null`, `plan_gate: null` 추가. `watchdog-jobs.json`에 `plan_question_budget: 30`, `plan_user_response_timeout_hours: 24` 추가
- `plugins/agent-atelier/references/prompts/orchestrator.md` — 핑퐁 루프 호스팅 프로토콜, 질문 라우팅, 게이트 처리, 예산 모니터링 + 모든 슬래시 명령 호출을 스크립트 호출로 일괄 교체
- `plugins/agent-atelier/agents/pm.md` — "불확실하면 ClarifyingQuestion 발행, 가정 진행 금지" 규칙. blocking/non-blocking 사용 가이드
- `plugins/agent-atelier/agents/architect.md` — 같은 규칙. WI 분해/복잡도 결정 시 발행 시점 예시 + 슬래시 → 스크립트 호출 교체
- `plugins/agent-atelier/agents/builder.md` — `/agent-atelier:execute claim` 언급을 `scripts/lifecycle claim`으로 교체
- `plugins/agent-atelier/references/recovery-protocol.md` — 핑퐁 중 cold resume 처리, 슬래시 → 스크립트 호출 교체
- `plugins/agent-atelier/references/paths.md` — `plan-conversations/` 경로 추가, scripts/* 항목 정리
- `plugins/agent-atelier/references/prompts/output-discipline.md` — 슬래시 → 스크립트 호출 교체
- `plugins/agent-atelier/hooks/on-stop.sh` — `/agent-atelier:init`, `/agent-atelier:execute requeue`, `/agent-atelier:watchdog tick` 언급을 스크립트 경로로 교체
- `plugins/agent-atelier/hooks/on-task-completed.sh` — `/agent-atelier:execute complete` 언급을 스크립트 경로로 교체
- `tests/all.sh` — EXPECTED_SKILLS 축소(plan/execute/status/monitors), EXPECTED_SCRIPTS 추가 + `-x` flag 검증, EXPECTED_REFERENCES에 monitor-runtime.md 추가
- `tests/schema_validation.sh` — `loop-state.json`에 `plan_approval`/`active_plan_cycle_id`/`plan_gate` 필드, `watchdog-jobs.json` 새 필드 검증 추가
- `tests/orchestration_contracts.sh`, `tests/recovery_contracts.sh` — 슬래시 → 스크립트 호출 갱신
- `AGENTS.md` — Plugin Structure 섹션 (현 10 skill → 사용자 진입점 3 + monitors shim, scripts/* 추가), 워크플로우 설명, init/run 언급 갱신
- `docs/design/cli-surface.md`, `system-design.md`, `session-limit-retry.md`, `recovery-spec.md` — 슬래시 호출 / 명령 surface 언급 갱신

### 테스트

`tests/` 디렉터리에 시나리오 추가:

- `plan_only.sh` — `/plan` 단독 호출 → 게이트 → y → 승인 기록 → 종료
- `execute_no_plan.sh` — `/execute` 호출 → plan 자동 진행 → 게이트 통과 → IMPLEMENT 진입
- `execute_with_valid_plan.sh` — 사전 승인 상태에서 `/execute` 호출 → plan 스킵 → IMPLEMENT
- `plan_invalidated.sh` — 승인 후 spec 수정 → `/execute` 호출 → 무효화 감지 → plan 재진행
- `pingpong_basic.sh` — 단일 ClarifyingQuestion 발행 → 사용자 응답 → spec 갱신 → 다음 phase
- `pingpong_modify.sh` — 게이트에서 "수정 X" → 해당 phase 재진입 → 추가 핑퐁
- `pingpong_assume.sh` — "네가 결정" 응답 → 권장안이 가정으로 등록 → 진행
- `pingpong_budget.sh` — 30개 초과 → 사용자 알림 → blocking 강제 false 전환
- `cold_resume_pingpong.sh` — 핑퐁 중 세션 죽음 → 재개 → jsonl 마지막 이벤트부터
- `script_contracts.sh` — scripts/* 각 명령의 stdin/stdout 계약 (JSON in/out, exit code) 검증

## 스키마 정의

### `clarifying-question.schema.json`

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ClarifyingQuestion",
  "type": "object",
  "required": ["id", "from_role", "phase", "topic", "question", "options", "recommended", "blocking"],
  "properties": {
    "id": {"type": "string", "pattern": "^CQ-[0-9]{3,}$"},
    "from_role": {"enum": ["PM", "Architect"]},
    "phase": {"enum": ["DISCOVER", "SPEC_DRAFT", "SPEC_HARDEN", "BUILD_PLAN"]},
    "topic": {"type": "string", "maxLength": 60},
    "question": {"type": "string"},
    "options": {"type": "array", "items": {"type": "string"}, "maxItems": 5},
    "recommended": {"type": "string"},
    "reasoning": {"type": "string"},
    "blocking": {"type": "boolean"}
  }
}
```

### `plan-conversation-entry.schema.json`

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "PlanConversationEntry",
  "type": "object",
  "required": ["seq", "ts", "type"],
  "properties": {
    "seq": {"type": "integer", "minimum": 1},
    "ts": {"type": "string", "format": "date-time"},
    "type": {"enum": [
      "clarifying_question",
      "user_response",
      "artifact_update",
      "phase_transition",
      "no_more_questions",
      "gate_presented",
      "gate_resolved",
      "round_marker"
    ]},
    "round": {"type": "integer", "minimum": 1},
    "phase": {"enum": ["DISCOVER", "SPEC_DRAFT", "SPEC_HARDEN", "BUILD_PLAN", "FINAL_REVIEW"]},
    "from_role": {"enum": ["PM", "Architect", "Orchestrator"]},
    "payload": {"type": "object"}
  }
}
```

JSONL 한 줄 = 한 entry. `seq`는 cycle 내 monotonic. `payload`는 type별 prefix 필드 (`clarifying_question` → ClarifyingQuestion 객체, `user_response` → `{cq_id, choice, free_text?}`, `artifact_update` → `{artifact_path, before_revision, after_revision, diff_summary}`, 등).

## 스크립트 계약 (script_contracts)

각 스크립트의 invocation/입력/출력/exit code/idempotency. `tests/script_contracts.sh`가 이 표대로 검증.

| 스크립트 | invocation | stdin | stdout | exit | idempotency |
|---------|-----------|-------|--------|------|------------|
| `init-helpers.sh` | `init-helpers.sh [--root <path>] [--migrate]` | 없음 | `{"changed": bool, "created": [paths], "migrated_keys": [...]}` | 0 success / 3 no git root / 4 IO | re-run 시 누락 파일/key만 추가, 기존 값 보존 |
| `wi` | `wi list` \| `wi show <id>` \| `wi upsert <json>` | upsert 시 JSON 가능 | `{"accepted": bool, "committed_revision": N, "native_task_sync": {...}, "items": [...]}` | 0 success / 1 invalid / 2 stale / 4 IO | upsert는 expected_revision 기반 |
| `lifecycle` | `lifecycle <claim\|heartbeat\|requeue\|complete\|attempt> <id> [flags]` | attempt 시 JSON | `{"accepted": bool, "committed_revision": N, "native_task_sync": {...}}` | 0/1/2/4 | claim 중복은 stale로 reject |
| `gate` | `gate list` \| `gate create <json>` \| `gate resolve <id> --chosen <opt>` | create 시 JSON | `{"accepted": bool, "gate_id": "HDR-NNN", ...}` | 0/1/2/4 | resolve 중복은 idempotent (이미 resolved면 noop) |
| `watchdog` | `watchdog tick` | 없음 | `{"actions": [...], "alerts": [...], "auto_transitioned": [wi_ids]}` | 0/4 | tick은 부수효과 누적 (state mutation) |
| `candidate` | `candidate enqueue <wi_ids...>` \| `activate` \| `clear --reason <demoted\|completed>` | 없음 | `{"accepted": bool, "candidate_set_id": "CS-NNN", ...}` | 0/1/2/4 | enqueue 중복 reject |
| `validate` | `validate record` | manifest JSON via stdin | `{"accepted": bool, "run_id": "VR-NNN", ...}` | 0/1/4 | run_id 충돌 시 reject |

모든 스크립트는 mutation 시 내부적으로 `state-commit`을 호출해 single-writer 모델 보존.

## 비고: 의도적으로 다루지 않은 것

- **CI 전후 처리, hooks 동작**: 기존 hooks(PreToolUse, Stop 등)와 cron 스케줄링 그대로 유지. 호출 경로만 슬래시 → 스크립트로 변경.
- **`/execute --mode <phase>` escape hatch**: 명시적으로 제거. plan을 우회하고자 하는 power-user 경로는 제공하지 않음 — 사용자가 spec/WI를 직접 손대고 ping-pong을 자연스럽게 거치는 것이 의도된 흐름.
- **Builder의 `plan_approval_request` 메시지와 명명 충돌**: `loop-state.plan_approval`(글로벌, 워크플로우)과 Builder의 `plan_approval_request`(메시지 페이로드, 단일 WI plan-mode 검토)는 위치/스코프로 자연 구분됨. 리네임 안 함.
- **다중 사용자 / 권한 모델**: `approved_by`는 `"user"` 고정. 향후 협업 모드에서 확장 여지만 남김.
- **spec_hash 입력 범위 확장**: `behavior-spec.md` 단독 hash. assumptions/decisions/success-metrics는 plan 시점의 산출물이지 입력이 아니라고 간주.
- **PM의 자율 spec 갱신 권한**: 기존 PM 정의 그대로. 본 설계는 PM이 갱신 직전에 ClarifyingQuestion을 발행하게 하는 추가 제약.
- **Builder/VRM 등 IMPLEMENT 단계 역할 변경**: 본 설계 범위 밖.
