# Human Gate Tracking — Operational Specification

> 컨텍스트 윈도우가 압축/재구성되어도 human gate 상태가 유실되지 않도록,
> 모든 게이트 항목은 반드시 이 파일 시스템에 기록한다.

---

## 1. 디렉토리 구조

```
docs/orchestration/
├── human-gates/
│   ├── _index.md              # ← 이 파일. 전체 게이트 현황 요약
│   ├── open/                  # 대기 중인 결정 요청
│   │   ├── HDR-001.json
│   │   └── HDR-002.json
│   ├── resolved/              # 사용자가 결정 완료한 항목
│   │   └── HDR-000.json
│   └── templates/
│       └── human-decision-request.json
├── escalations/               # Level 1-3 에스컬레이션 (팀 내부 해결)
└── loop-state.json            # 상태 머신 현재 위치
```

---

## 2. Human Decision Request (HDR) 스키마

```json
{
  "id": "HDR-NNN",
  "created_at": "2026-03-09T14:30:00Z",
  "triggered_by": "role-name",
  "state": "open | resolved | withdrawn",

  "question": "사용자에게 던지는 핵심 질문 (한 문장)",
  "why_now": "왜 지금 이 결정이 필요한지 배경",
  "context": "관련 스펙/코드 참조 링크",

  "gate_criteria": {
    "irreversibility": "high | medium | low",
    "blast_radius": "high | medium | low",
    "product_meaning_change": true
  },

  "options": [
    {
      "id": "A",
      "label": "옵션 설명",
      "tradeoffs": ["장점/단점 목록"],
      "estimated_effort": "small | medium | large"
    }
  ],
  "recommended_option": "A",

  "blocking": false,
  "blocked_work_items": ["FE-022"],
  "unblocked_work_items": ["BE-011", "FE-019"],
  "default_if_no_response": "continue_unblocked_work",

  "linked_escalations": ["ESC-009"],

  "resolution": {
    "resolved_at": null,
    "chosen_option": null,
    "user_notes": null,
    "follow_up_actions": []
  }
}
```

---

## 3. _index.md — 게이트 현황 대시보드

이 파일은 Team Lead가 게이트를 열거나 닫을 때마다 갱신한다.

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

Team Lead는 다음 상황에서 **즉시** HDR 파일을 생성한다:

1. Level 4 에스컬레이션이 확정될 때
2. REVIEW_SYNTHESIS에서 `product_level_change` 판정이 나올 때
3. 3-test gate (비가역성 + 폭발 반경 + 제품 의미 변경) 중 하나라도 HIGH일 때

### 4.2 비차단 원칙 (Non-blocking)

```
게이트 생성 → open/ 에 JSON 저장 → _index.md 갱신
         → blocked_work_items 은 PARKED 상태로 전환
         → unblocked_work_items 은 계속 진행
         → 사용자에게 알림 (Lead → User 단일 창구)
```

- 게이트가 **모든** 남은 작업을 차단할 때만 전체 정지
- 그 외에는 관련 없는 작업 계속 진행

### 4.3 해결 흐름

```
사용자 결정 도착
  → HDR JSON의 resolution 필드 채움
  → 파일을 open/ → resolved/ 로 이동
  → _index.md 갱신
  → blocked_work_items PARKED → PENDING 전환
  → follow_up_actions 에 따라 SPEC_HARDEN 또는 BUILD_PLAN 으로 복귀
```

### 4.4 컨텍스트 복원 프로토콜

**새 세션 시작 시 또는 컨텍스트 압축 후:**

1. `docs/orchestration/human-gates/open/` 디렉토리 확인
2. 열린 게이트가 있으면 _index.md 읽기
3. 각 open HDR JSON 파일 읽기
4. 차단된 작업 항목 상태를 work-items.json과 대조
5. 사용자에게 미결 게이트 현황 보고

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

### Step 1: Tech Lead가 이슈 발견
> "현재 PRD는 공개 API 응답 형태 변경을 암시하고 있음"

### Step 2: Lead가 HDR 생성

```bash
# open/ 에 JSON 파일 생성
cat > docs/orchestration/human-gates/open/HDR-007.json << 'EOF'
{
  "id": "HDR-007",
  "created_at": "2026-03-09T15:00:00Z",
  "triggered_by": "tech-lead",
  "state": "open",
  "question": "공개 API 응답 형태를 변경할까요, 프론트엔드에서 매핑할까요?",
  "why_now": "현재 PRD가 기존 API 클라이언트를 깨는 응답 구조를 암시",
  "context": "docs/product/prd.md#api-response, docs/design/api-spec.md",
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
  "blocked_work_items": ["FE-014", "API-003"],
  "unblocked_work_items": ["BE-011", "FE-019"],
  "default_if_no_response": "continue_unblocked_work",
  "linked_escalations": ["ESC-007"],
  "resolution": null
}
EOF
```

### Step 3: _index.md 갱신
Open Gates 테이블에 HDR-007 행 추가

### Step 4: 사용자 결정 도착 ("A로 가자")

### Step 5: 해결 처리
```bash
# resolution 채우고 resolved/ 로 이동
mv docs/orchestration/human-gates/open/HDR-007.json \
   docs/orchestration/human-gates/resolved/HDR-007.json
# _index.md 갱신: Open → Resolved 로 이동
```
