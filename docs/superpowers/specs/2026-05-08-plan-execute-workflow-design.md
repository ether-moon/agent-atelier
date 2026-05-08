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

```
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

`loop-state.json`에 `plan_approval` 추가:

```json
{
  "plan_approval": {
    "approved_at": "2026-05-08T10:30:00Z",
    "approved_revision": 42,
    "spec_hash": "sha256:...",
    "approved_by": "user"
  }
}
```

| 필드 | 의미 |
|------|------|
| `approved_at` | UTC timestamp, ISO 8601 with `Z` |
| `approved_revision` | 승인 시점의 `work-items.json` revision |
| `spec_hash` | 승인 시점의 `docs/product/behavior-spec.md` SHA-256 (형식: `sha256:<64-hex>`) |
| `approved_by` | 식별자 (현 단계는 `"user"` 고정) |

**무효화 조건** — 다음 `execute` 호출 시 plan 재실행 트리거:

- `plan_approval`이 `null` 또는 부재
- `work-items.json` revision이 `approved_revision`보다 진행됨
- `behavior-spec.md`의 `sha256:<hex>` 가 `spec_hash`와 다름

사용자가 손으로 두 파일 중 하나를 수정해도 자동 감지된다. 게이트 통과 = State Manager가 `plan_approval` 객체 전체를 atomic하게 기록.

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
| `blocking` | true면 답 받기 전 phase 진행 불가; false면 같은 라운드의 다른 질문에 답하면서 이 질문을 건너뛴 경우 권장안을 가정으로 자동 채택 |

### 사용자 응답 처리

Orchestrator는 질문 묶음을 사용자에게 표시하고 응답을 라우팅:

| 응답 | 처리 |
|------|------|
| 선택지 번호 (예: `1`) | 해당 옵션 채택, 발행한 role에게 전달 |
| 자유 텍스트 | 새 답변으로 채택, role이 적절히 spec/WI 갱신 |
| `네가 결정` 또는 `너 알아서` | role이 `recommended`를 가정으로 채택, PM의 assumptions log에 기록 |
| `잠깐, 내가 X에 대해 묻고 싶어` | 사용자 역질문을 PM/Architect에게 forward — 진짜 핑퐁 |

질문 답변 후 spec/WI 변경분 diff 요약을 Orchestrator가 사용자에게 보여준다(짧게).

### 질문 출제 단위

한 라운드에서 한 role이 **최대 5개**까지 묶어서 출제 가능. 효율 우선. 5개 초과 시 라운드를 나눔.

### 루프 종료 조건

활성 role이 "더 이상 질문 없음" 신호를 보낼 때까지 phase 내에서 N라운드 반복. 한 phase가 끝나면 다음 phase로. BUILD_PLAN까지 모두 "질문 없음"이면 최종 게이트로 진입.

### 영속성

`.agent-atelier/plan-conversations/<plan-cycle-id>.jsonl` 에 모든 ClarifyingQuestion + 응답 + 갱신 artifact 참조를 append.

`<plan-cycle-id>` 형식: `cycle-<UTC-timestamp>` (예: `cycle-20260508T103000Z`). plan 사이클이 시작될 때 결정.

JSONL 한 라인 = 한 이벤트 (질문 발행, 응답 수신, artifact 갱신, phase 전환). 세션 재시작이나 다음 cycle에서도 결정 이력 추적 가능. PM 기존 assumptions log는 이 파일의 view로 통합.

## 최종 승인 게이트

모든 phase가 "질문 없음" 상태로 안정화되면 BUILD_PLAN 종료 시 통합 리뷰 한 번:

```
=== Plan Stable. Ready for Implementation? ===
Spec: 12 behaviors (3 added/changed during plan)
WIs:  5 ready (complexity S:2 / M:2 / L:1, 모두 verify ≥1)
사용자 결정사항: 8건 (CQ-001 ~ CQ-008, 로그 보기: ...)
가정으로 진행한 항목: 2건 (사용자가 "네가 결정"한 케이스)

진행할까요? [y / 더 검토 / 수정 <피드백>]
```

| 응답 | 처리 |
|------|------|
| `y` | `plan_approval` atomic 기록. 호출 컨텍스트가 `/execute`였으면 IMPLEMENT 진입; `/plan` 단독이었으면 종료. |
| `더 검토` | 빈 라운드 한 번 더 — 사용자가 추가 의문 던질 기회 |
| `수정 <피드백>` | 피드백을 적절한 phase로 라우팅, 핑퐁 재시작 |

## 안전장치

| 항목 | 동작 |
|------|------|
| 질문 예산 | 한 plan cycle 누적 질문 수 30 초과 시 watchdog이 "스코프가 너무 큰 것 같습니다 — 분해하시겠어요?" 알림 |
| Blocking vs non-blocking | role이 발행 시 `blocking` 플래그로 표시. blocking이면 답 받기 전 진행 불가; non-blocking은 미답 시 권장안 자동 채택 |
| 예산 임박 시 | 누적 질문이 25 초과한 시점부터 모든 신규 질문은 강제 `blocking: false` 처리 (무한 핑퐁 방지) |
| 사용자 부재 감지 | 게이트에서 24h 이상 응답 없으면 watchdog이 plan을 `paused`로 표시. 다음 `/plan` 또는 `/execute` 호출 시 그 자리서 재개 |
| Cold resume | 핑퐁 중 세션이 죽으면, 다음 `/plan`/`/execute` 호출이 `plan-conversations/<cycle-id>.jsonl` 마지막 이벤트부터 재개 |

## 기존 `init` / `run` 처리

플러그인이 0.1.x이므로 deprecation alias 없이 깔끔하게 교체:

- `plugins/agent-atelier/skills/init/` — 삭제. 부트스트랩 로직은 `references/init-helpers.md` 같은 internal helper로 흡수, plan/execute 두 skill이 호출.
- `plugins/agent-atelier/skills/run/` — 삭제. `execute/`로 이름 변경 + 게이트 검증 + plan 자동 실행 분기.
- README, AGENTS.md, plugin description, role prompts의 init/run 언급 모두 plan/execute로 갱신.

## 변경 범위

### 신규 파일

- `plugins/agent-atelier/skills/plan/SKILL.md` — init 부트스트랩 + 핑퐁 루프 + 최종 게이트
- `plugins/agent-atelier/skills/execute/SKILL.md` — 게이트 검증 + plan 자동 실행 + IMPLEMENT → DONE (기존 `run/SKILL.md` 이름 변경 후 수정)
- `plugins/agent-atelier/references/init-helpers.md` — 부트스트랩 로직(상태 파일 생성, WAL 복구) 정의. plan/execute 두 skill이 호출
- `plugins/agent-atelier/schema/clarifying-question.schema.json` — ClarifyingQuestion JSON 스키마
- `plugins/agent-atelier/schema/plan-conversation-entry.schema.json` — JSONL 한 라인 이벤트 스키마
- `.agent-atelier/plan-conversations/` 디렉터리 (init 시 생성)

### 제거

- `plugins/agent-atelier/skills/init/SKILL.md`
- `plugins/agent-atelier/skills/run/SKILL.md`

### 수정

- `plugins/agent-atelier/scripts/state-commit` — `plan_approval` 필드 검증 스키마 추가
- `plugins/agent-atelier/references/state-defaults.md` — `loop-state.json` 기본 shape에 `plan_approval: null`
- `plugins/agent-atelier/references/prompts/orchestrator.md` — 핑퐁 루프 호스팅 프로토콜, 질문 라우팅, 응답 분류, 게이트 처리, 예산 모니터링
- `plugins/agent-atelier/references/prompts/pm.md` — "불확실하면 ClarifyingQuestion 발행, 가정 진행 금지" 규칙. blocking/non-blocking 사용 가이드
- `plugins/agent-atelier/references/prompts/architect.md` — 같은 규칙. WI 분해/복잡도 결정 시 발행 시점 예시
- `plugins/agent-atelier/references/recovery-protocol.md` — 핑퐁 중 cold resume 처리 (jsonl 마지막 이벤트 기준 재개)
- `plugins/agent-atelier/references/paths.md` — `plan-conversations/` 경로 추가
- `plugins/agent-atelier/references/state-defaults.md` — `watchdog-jobs.json` 기본 shape에 `plan_question_budget: 30`, `plan_user_response_timeout_hours: 24` 추가 (runtime 위치는 `.agent-atelier/watchdog-jobs.json`)
- `AGENTS.md` — 워크플로우 다이어그램과 init/run 언급 갱신 (Versioning 섹션은 그대로)

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

## 비고: 의도적으로 다루지 않은 것

- **CI 전후 처리, hooks 변경**: 기존 hooks(PreToolUse, Stop 등)와 cron 스케줄링 그대로 유지. 게이트 통과 이후 IMPLEMENT 단계의 동작은 현 `run`과 동일.
- **다중 사용자 / 권한 모델**: `approved_by`는 `"user"` 고정. 향후 협업 모드에서 확장 여지만 남김.
- **PM의 자율 spec 갱신 권한**: 기존 PM 정의 그대로. 본 설계는 PM이 갱신 직전에 사용자 확인을 받게 하는 추가 제약.
- **Builder/VRM 등 IMPLEMENT 단계 역할 변경**: 본 설계 범위 밖.
