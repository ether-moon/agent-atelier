# Human Gate Tracking — Operational Specification

> 컨텍스트 윈도우가 압축/재구성되어도 human gate 상태가 유실되지 않도록,
> 모든 게이트 항목은 반드시 이 파일 시스템에 기록한다.

> `HUMAN_GATE`는 전역 phase가 아니라 특정 work item의 차단 상태다.
> gate 자체와 관련 WI 상태는 모두 State Manager가 직렬화해 기록한다.

---

## 1. 디렉토리 구조

```
.agent-atelier/
├── human-gates/
│   ├── _index.md              # 런타임 대시보드. 전체 게이트 현황 요약
│   ├── open/                  # 대기 중인 결정 요청
│   │   ├── HDR-001.json
│   │   └── HDR-002.json
│   ├── resolved/              # 사용자가 결정 완료한 항목
│   │   └── HDR-000.json
│   └── templates/
│       └── human-decision-request.json
├── attempts/                  # WI별 attempt journal
├── escalations/               # Level 1-3 에스컬레이션 (팀 내부 해결)
├── loop-state.json            # control plane 상태
├── watchdog-jobs.json         # watchdog check 상태와 임계치
└── work-items.json            # WI-level 상태와 blocked_by_gate 기록
```

---

## 2. Human Decision Request (HDR) 정본 스키마 참조

HDR의 정본 스키마는 [system-design.md](/Users/ether/conductor/workspaces/agent-atelier/colombo-v1/docs/design/system-design.md#L722)의 Section 8.4에 둔다. 이 문서는 스키마를 중복 정의하지 않고, 해당 정본을 전제로 gate 운영 규칙만 정의한다.

운영상 필수 필드는 다음이다.

- `id`, `created_at`, `state_revision`, `triggered_by`, `state`
- `question`, `why_now`, `context`
- `gate_criteria`, `options`, `recommended_option`
- `blocking`, `blocked_work_items`, `unblocked_work_items`
- `resume_target`, `default_if_no_response`, `linked_escalations`
- `resolution`

---

## 3. _index.md — 게이트 현황 대시보드

이 파일은 State Manager가 게이트를 열거나 닫을 때마다 갱신한다.

### Open Gates

| ID | Question | Triggered By | Blocking? | Blocked Items | Created |
|----|----------|-------------|-----------|---------------|---------|
| — | (없음) | — | — | — | — |

### Resolved Gates

| ID | Question | Chosen Option | Resolved At |
|----|----------|--------------|-------------|
| — | (없음) | — | — |

---

## 4. 운영 규칙

### 4.1 기록 시점

Orchestrator는 다음 상황에서 **즉시** gate 요청을 올리고, State Manager는 HDR 파일을 생성한다:

1. Level 4 에스컬레이션이 확정될 때
2. REVIEW_SYNTHESIS에서 `product_level_change` 판정이 나올 때
3. 3-test gate (비가역성 + 폭발 반경 + 제품 의미 변경) 중 하나라도 HIGH일 때

### 4.2 비차단 원칙 (Non-blocking)

```
게이트 요청 → State Manager가 open/ 에 JSON 저장 → _index.md 갱신
         → blocked_work_items 은 blocked_on_human_gate 로 전환
         → blocked_by_gate = HDR-NNN 기록
         → unblocked_work_items 은 계속 진행
         → loop-state.json 은 현재 control-plane mode 와 candidate queue 를 유지
         → 사용자에게 알림 (Orchestrator → User 단일 창구)
```

- 게이트가 **모든** 남은 작업을 차단할 때만 전체 정지
- 그 외에는 관련 없는 작업 계속 진행
- watchdog는 장기 방치된 open gate를 감지해 Orchestrator에 알린다

### 4.3 해결 흐름

```
사용자 결정 도착
  → State Manager가 HDR JSON의 resolution 필드 채움
  → 파일을 open/ → resolved/ 로 이동
  → _index.md 갱신
  → blocked_work_items 의 blocked_by_gate 제거
  → blocked_work_items blocked_on_human_gate → ready 로 전환
  → Orchestrator가 resume_target 에 따라 SPEC_HARDEN 또는 BUILD_PLAN 으로 라우팅
```

### 4.4 컨텍스트 복원 프로토콜

**새 세션 시작 시 또는 컨텍스트 압축 후:**

1. `.agent-atelier/loop-state.json` 확인
2. `.agent-atelier/work-items.json`에서 `blocked_by_gate` 필드 확인
3. `.agent-atelier/human-gates/open/` 디렉토리 확인
4. 열린 게이트가 있으면 _index.md 및 각 open HDR JSON 파일 읽기
5. 차단된 작업 항목 상태와 `resume_target`을 대조
6. [system-design.md](/Users/ether/conductor/workspaces/agent-atelier/colombo-v1/docs/design/system-design.md#L598)의 loop-state 스키마를 기준으로 `active_candidate` 와 `candidate_queue` 에 gate 때문에 막힌 WI가 섞여 있는지 확인
7. 사용자에게 미결 게이트 현황 보고

> 이 프로토콜이 있으므로 대화 기록이 전부 사라져도 게이트 상태는 복원된다.

### 4.5 Gate를 열어야 하는 항목 (체크리스트)

- [ ] 핵심 사용자 흐름/네비게이션 구조 변경
- [ ] 인증/개인정보/결제/법적 영향
- [ ] DB 스키마 또는 공개 API 호환성 깨는 변경
- [ ] 주요 의존성 추가/교체
- [ ] "현재 방향이 틀렸다" 수준의 피벗 발견
- [ ] KPI 또는 타겟 사용자 가정 변경

### 4.6 Gate를 열지 않아야 하는 항목 (자율 판단)

- 로딩/에러/빈 상태 UI
- 디자인 시스템 범위 내 간격/타이포그래피
- 폼 유효성 검증 규칙
- API 타임아웃/재시도 기본값
- 테스트 데이터, 마이너 리팩토링
- 수용 기준 범위 내 카피/레이아웃 조정

---

## 5. 예시: 게이트 생성부터 해결까지

### Step 1: Architect가 이슈 발견
> "현재 Behavior Spec이 공개 API 응답 형태 변경을 암시하고 있음"

### Step 2: Orchestrator가 gate 요청, State Manager가 HDR 기록

```bash
# open/ 에 JSON 파일 생성
cat > .agent-atelier/human-gates/open/HDR-007.json << 'EOF'
{
  "id": "HDR-007",
  "created_at": "2026-03-09T15:00:00Z",
  "state_revision": 41,
  "triggered_by": "architect",
  "state": "open",
  "question": "공개 API 응답 형태를 변경할까요, 프론트엔드에서 매핑할까요?",
  "why_now": "현재 Behavior Spec이 기존 API 클라이언트를 깨는 응답 구조를 암시",
  "context": "docs/product/behavior-spec.md#B7, docs/engineering/api-contracts.md#checkout-response",
  "gate_criteria": {
    "irreversibility": "high",
    "blast_radius": "high",
    "product_meaning_change": false
  },
  "options": [
    {
      "id": "A",
      "label": "현재 API 유지, 프론트엔드 매핑 추가",
      "tradeoffs": ["매핑 코드 추가", "하위 호환 유지"],
      "estimated_effort": "medium"
    },
    {
      "id": "B",
      "label": "API 응답 형태 변경",
      "tradeoffs": ["깔끔한 계약", "기존 클라이언트 깨짐"],
      "estimated_effort": "small"
    }
  ],
  "recommended_option": "A",
  "blocking": false,
  "blocked_work_items": ["WI-014", "WI-021"],
  "unblocked_work_items": ["WI-011", "WI-019"],
  "resume_target": "BUILD_PLAN",
  "default_if_no_response": "continue_unblocked_work",
  "linked_escalations": ["ESC-007"],
  "resolution": {
    "resolved_at": null,
    "chosen_option": null,
    "user_notes": null,
    "follow_up_actions": []
  }
}
EOF
```

### Step 3: _index.md 갱신
Open Gates 테이블에 HDR-007 행 추가

### Step 4: 사용자 결정 도착 ("A로 가자")

### Step 5: 해결 처리
```bash
# resolution 채우고 resolved/ 로 이동
mv .agent-atelier/human-gates/open/HDR-007.json \
   .agent-atelier/human-gates/resolved/HDR-007.json
# _index.md 갱신: Open → Resolved 로 이동
# work-items.json 갱신:
#   WI-014, WI-021 의 blocked_by_gate 제거
#   status: blocked_on_human_gate -> ready
#   resume_target: BUILD_PLAN 유지, Orchestrator가 다음 단계로 라우팅
```
