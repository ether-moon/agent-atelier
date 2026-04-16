# Orchestration Model v0.2 — Two-Tier State + Batch Candidate + Auto-Dependency + Fast-Track Review

## Context

agent-atelier v0.1.3에 대한 실사용 피드백 17건을 분석한 결과, 15건이 미해결/부분해결 상태. 이 중 MAJOR 4건(#2, #3, #5, #6) + 관련 부분해결 2건(#4, #12)을 하나의 통합 오케스트레이션 모델 개선으로 설계.

### 해결하는 문제

| # | 문제 | 영향 |
|---|------|------|
| #6 | SM 직렬 병목 — 모든 상태 쓰기가 SM 2턴 왕복 필요 | 세션당 ~22턴 낭비 |
| #2 | 배치 후보 미지원 — active_candidate 단일 슬롯 | 병렬 WI의 CI 대기 4x |
| #3 | 의존성 자동 전환 미지원 — 선행 WI 완료 시 후행 WI pending 잔류 | 수동 상태 변경 필요 |
| #5 | REVIEW_SYNTHESIS 스킵 경로 부재 | 단순 1파일 수정도 풀 리뷰 사이클 |
| #4 | verify 필드 미강제 — 80% WI가 빈 배열 | VRM demotion 악순환 |
| #12 | Validate-Clear 원자성 부재 | 크래시 시 candidate 슬롯 정지 |

### 피어 리뷰 반영 (Codex + Claude)

- Revision 간섭 → **patch/verb 연산** (파일 분리 대신)
- `owner_session_id` → **control-plane 유지** (status 전이와 필연적 결합)
- `active_candidate` → **1급 candidate_set 객체** (ID + type 확장성)
- 의존성 전이 → **pre-WAL 계산** (replay 결정성)
- fast-track → **per-batch 보수적 기준**
- `complexity` 기본값 → **null** (Architect 명시 설정 필수)
- 배치 실패 → **fate-sharing** (all-or-nothing)
- 사이클 감지 → **wi upsert 시점 DFS**

---

## Design

### 1. Two-Tier State: Patch/Verb 모델 (#6 해결)

#### 핵심 개념

state-commit 스크립트에 **verb 모드**를 추가. Data-plane 변경은 SM을 거치지 않고 호출자가 state-commit을 직접 실행. 같은 원자적 커밋, revision 검증, WAL 복구 유지.

#### Verb 입력 형식

```json
{"verb": "heartbeat", "target": "WI-014", "fields": {"last_heartbeat_at": "...", "lease_expires_at": "..."}}
```

#### Verb 정의 (data-plane 화이트리스트)

| Verb | 대상 파일 | 수정 가능 필드 | 호출자 |
|------|----------|---------------|--------|
| `heartbeat` | work-items.json | `last_heartbeat_at`, `lease_expires_at` | Orchestrator |
| `record-attempt` | work-items.json | `attempt_count`, `last_attempt_ref`, `last_finding_fingerprint` | Orchestrator |
| `record-requeue-meta` | work-items.json | `stale_requeue_count`, `last_requeue_reason` | Watchdog |
| `watchdog-tick-meta` | watchdog-jobs.json | `open_alerts`, `last_tick_at` | Watchdog |

#### state-commit 처리 흐름 (verb 모드)

1. stdin JSON 파싱 — `verb` 키 존재 시 verb 모드
2. 파일 lock 획득 (기존과 동일)
3. 현재 상태 읽기 + revision 확인
4. `target` WI 탐색
5. **필드 화이트리스트 검증**: verb 정의에 없는 필드 → exit 1
6. patch 적용 → WI revision bump → store revision bump
7. WAL 기록 → 파일 쓰기 → WAL 삭제 (기존 흐름)
8. 이벤트 emit

#### Control-Plane vs Data-Plane 분류

**Control-Plane (SM 경유 필수):**
- `status`, `promotion.*`, `completion`, `owner_session_id`
- `mode`, `active_candidate_set`, `candidate_queue`, `open_gates`
- `depends_on`, `verify`, `owned_paths`, `behaviors`, 모든 spec 필드

**Data-Plane (Verb 직접 가능):**
- `last_heartbeat_at`, `lease_expires_at` (리스 관리)
- `first_claimed_at`, `handoff_count` (클레임 메타)
- `attempt_count`, `last_attempt_ref`, `last_finding_fingerprint` (시도 추적)
- `stale_requeue_count`, `last_requeue_reason` (requeue 메타)
- `open_alerts`, `last_tick_at` (watchdog 메타)

#### 스킬별 호출 경로

| 스킬/서브커맨드 | 경로 | 근거 |
|----------------|------|------|
| `execute heartbeat` | Verb (직접) | lease 갱신만 |
| `execute attempt` | Verb (직접) | 시도 메타만 |
| `watchdog tick` (카운터 부분) | Verb (직접) | 기계적 갱신 |
| `execute claim/complete/requeue` | Transaction (SM) | status 변경 |
| `candidate *` | Transaction (SM) | candidate lifecycle |
| `validate record` | Transaction (SM) | status + promotion |
| `wi upsert` | Transaction (SM) | WI 생성/수정 |

---

### 2. Batch Candidate Lifecycle (#2 + #12 해결)

#### candidate_set 스키마

`active_candidate`를 1급 `candidate_set` 객체로 대체:

```json
{
  "active_candidate_set": {
    "id": "CS-001",
    "work_item_ids": ["WI-018", "WI-019", "WI-020", "WI-021"],
    "branch": "feat/phase-2",
    "commit": "abc1234",
    "type": "batch",
    "activated_at": "2026-04-08T14:10:00Z"
  },
  "candidate_queue": [
    {
      "id": "CS-002",
      "work_item_ids": ["WI-022"],
      "branch": "candidate/WI-022",
      "commit": "def5678",
      "type": "single"
    }
  ]
}
```

- `id`: `CS-NNN` 형식, enqueue 시 자동 생성
- `work_item_ids`: 항상 배열 (단일도 `["WI-014"]`)
- `type`: `"single"` | `"batch"`
- `activated_at`: 기존 `candidate_activated_at` 통합
- 기존 `active_candidate`, `candidate_activated_at` 필드 제거

#### candidate 스킬 서브커맨드

**`enqueue`**:
```bash
# 단일
candidate enqueue WI-014 --branch candidate/WI-014 --commit abc1234
# 배치
candidate enqueue WI-018,WI-019,WI-020,WI-021 --branch feat/phase-2 --commit abc1234
```
전제조건: 모든 WI가 `implementing` 상태. 하나라도 아니면 전체 거부.

**`activate`**: 큐에서 FIFO pop → `active_candidate_set`. 모든 WI → `candidate_validating`.

**`clear`**:
- `--reason completed`: 모든 WI `done` 확인 → set null
- `--reason demoted`: 모든 WI → `ready`, promotion 클리어 (fate-sharing)

#### Validate-Clear 원자성

validate record의 트랜잭션에 candidate_set 정리 포함:

| validate 결과 | 같은 트랜잭션에 포함되는 추가 변이 |
|--------------|-------------------------------|
| `passed` | 없음 (set 유지 — 리뷰/완료 대기) |
| `failed` | 모든 WI → `ready` + promotion 클리어 + `active_candidate_set` → null |
| `environment_error` | 없음 |

execute complete에서: 마지막 WI 완료 시 같은 트랜잭션에 `active_candidate_set → null` 포함. 별도 `candidate clear` 불필요.

#### Validate 매니페스트 스키마

```json
{
  "id": "RUN-2026-04-08-01",
  "candidate_set_id": "CS-001",
  "work_item_ids": ["WI-018", "WI-019", "WI-020", "WI-021"],
  "candidate_branch": "feat/phase-2",
  "candidate_commit": "abc1234",
  "status": "passed|failed|environment_error",
  "checks": [...]
}
```

build-vrm-prompt: 배치 set의 모든 WI에서 verify 수집 → 단일 증거 번들.

---

### 3. Dependency Auto-Transition (#3 해결)

#### Pre-WAL Dependency Resolver

state-commit이 WAL 기록 직전, 트랜잭션 내 변이를 분석:

1. `done`으로 변경된 WI ID 수집
2. 전체 WI의 `depends_on` 스캔
3. `pending` 상태 WI 중 모든 deps가 `done` → `status: "ready"` 변이를 같은 트랜잭션에 추가
4. WAL에 원본 + 파생 변이 모두 기록

**제외 규칙:**
- `blocked_on_human_gate` → 전이 안 함 (게이트 우선)
- non-`pending` 상태 → 이미 진행 중이므로 건너뜀

**Replay 결정성**: WAL에 파생 전이 포함 → `--replay` 동일 결과.

#### 사이클 감지 (정규화 규칙 9)

`wi upsert` 시 `depends_on` 설정 시점에 DFS 사이클 탐지. 감지 시 exit 1 거부.

#### Native Task 동기화

auto-transition된 WI에 `TaskUpdate(status: "pending")` 호출 (best-effort).

---

### 4. Fast-Track Review + Verify 강화 (#5 + #4 해결)

#### Verify 하드 게이트 (#4, 선행)

BUILD_PLAN → IMPLEMENT 전이 전제조건:
```
∀ WI where status == "ready": verify.length ≥ 1
위반 → 전이 거부 + WI ID 목록
```

Verify 스코프 규칙 (정규화 규칙 10):
> verify 항목은 해당 WI의 `owned_paths` 범위 내에서 검증 가능해야 함.

Architect 프롬프트에 강제 지침. PM이 SPEC_HARDEN에서 교차 검증.

#### Complexity 기본값 변경

정규화 규칙 7 수정: `complexity: null | "simple" | "complex"`. 기본값 `null`.
`null`인 WI는 fast-track 불가 — Architect가 명시 설정 필수.

#### Fast-Track 경로 (#5, 후행)

모드 전이 테이블 추가:

| From | To | 조건 |
|------|----|------|
| VALIDATE | IMPLEMENT | VRM passed + fast-track 충족 → 리뷰 스킵 |
| VALIDATE | REVIEW_SYNTHESIS | VRM passed + fast-track 미충족 → 풀 리뷰 |

Fast-track 조건 (per-batch 보수적, ALL 충족):
1. candidate_set 내 모든 WI `complexity == "simple"`
2. VRM `status == "passed"`
3. 총 diff ≤ 30줄
4. owned_paths에 auth/payment/schema-migration/public-api 경로 미포함

---

## 영향 범위

| 파일 | 변경 유형 | 관련 항목 |
|------|----------|----------|
| `scripts/state-commit` | verb 모드, pre-WAL resolver, 사이클 감지 | #6, #3 |
| `skills/candidate/SKILL.md` | candidate_set 스키마, 배치 enqueue/activate/clear | #2 |
| `skills/validate/SKILL.md` | 매니페스트 배열화, failed 시 atomic clear | #12 |
| `skills/execute/SKILL.md` | complete 시 set 자동 정리, heartbeat verb | #12, #6 |
| `skills/run/SKILL.md` | 전이 테이블 fast-track, complexity null | #5 |
| `skills/wi/SKILL.md` | verify 하드 게이트, 사이클 감지, 스코프 규칙 | #4, #3 |
| `references/state-defaults.md` | active_candidate_set 스키마, complexity null | #2, #5 |
| `references/wi-schema.md` | 규칙 7 수정, 규칙 9/10 추가 | #3, #4, #5 |
| `references/prompts/orchestrator.md` | 전이 테이블, fast-track, verb 허용 | #5, #6 |
| `references/prompts/state-manager.md` | verb 비경유 명시, control-plane 범위 | #6 |
| `references/prompts/architect.md` | complexity 필수, verify 스코프, 배치 가이드 | #4, #5 |
| `scripts/build-vrm-prompt` | 배치 set 다중 WI verify 수집 | #2 |
| `hooks/on-task-completed.sh` | verify 경고→차단 | #4 |
| `references/recovery-protocol.md` | candidate_set 정합성 검사 | #2 |
| `tests/all.sh` | 신규 어설션 추가 | 전체 |
