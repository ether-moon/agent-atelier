# Agent Teams API 실증 검증 프롬프트

## 사용법

새 Claude Code 세션에서 아래 프롬프트를 실행한다.
작업 디렉토리: `/Users/ether/conductor/workspaces/agent-atelier/auckland`

---

## 프롬프트

```text
이 세션은 agent-atelier 플러그인의 Agent Teams API 가정을 실증 검증하기 위한 테스트 세션이다.
3가지 미검증 항목을 순서대로 테스트하고, 각 결과를 tests/manual/verification-results.json에 기록한다.
모든 테스트 완료 후 반드시 팀을 정리(TeamDelete)한다.

## 배경

이전 세션에서 다음을 확인했다:
- TaskList/TaskGet은 metadata를 반환하지 않는다 (subject prefix 매칭으로 전환 완료)
- TaskCreated hook stdin에 metadata가 포함되지 않는다 (task_subject 파싱으로 전환 완료)
- on-teammate-idle.sh, on-task-created.sh에 bash heredoc 구문 오류가 있었다 (수정 완료)

아래 3가지는 실제 Agent Teams 환경에서만 검증 가능하다.

## 테스트 1: spawn-time mode 파라미터

**가설:** Agent tool의 mode 파라미터가 spawn 시점에 적용되는지 확인한다.

단계:
1. TeamCreate(team_name="api-test", description="Agent Teams API verification")
2. Agent tool로 teammate 생성: name="test-acceptEdits", subagent_type="state-manager", team_name="api-test", mode="acceptEdits"
3. test-acceptEdits에게 SendMessage: "현재 너의 permission mode가 뭔지 확인해. 도구 사용 시 승인이 필요한지 Write tool로 /tmp/mode-test.txt에 'hello'를 써 봐. 결과를 나에게 보고해."
4. 응답을 기록:
   - Write가 승인 없이 실행됐는가? → mode=acceptEdits 적용됨
   - 승인 프롬프트가 떴는가? → mode 무시됨 (lead 설정 상속)
5. test-acceptEdits에게 shutdown 요청: SendMessage({type: "shutdown_request"})

**기록 형식:**
{
  "test": "spawn_time_mode",
  "mode_requested": "acceptEdits",
  "write_succeeded_without_approval": true/false,
  "conclusion": "mode parameter honored at spawn time" 또는 "mode parameter ignored, inherits from lead"
}

## 테스트 2: plan_approval_request 프로토콜

**가설:** spawn prompt에 plan approval 요구 시, teammate가 plan_approval_request 구조화 메시지를 보내는지 확인한다.

단계:
1. (팀이 이미 존재하므로 TeamCreate 생략)
2. Agent tool로 teammate 생성: name="test-planner", subagent_type="builder", team_name="api-test", prompt="This is a complex work item. You must propose a plan and get approval before making any changes. Do not write or edit files until the Orchestrator approves your plan. Your task: create a file /tmp/plan-test.txt with the text 'test'. First, send your plan to the lead for approval."
3. test-planner의 응답을 관찰:
   a. 구조화된 JSON plan_approval_request를 보내는가?
   b. 아니면 plain text로 계획을 설명하는가?
   c. 승인 없이 바로 파일을 생성하는가?
4. 만약 plan_approval_request를 받으면:
   - approve: true로 응답
   - 파일 생성이 진행되는지 확인
5. 만약 plain text로 오면:
   - "Approved. Proceed."로 응답
   - 파일 생성이 진행되는지 확인
6. test-planner에게 shutdown 요청

**기록 형식:**
{
  "test": "plan_approval_protocol",
  "message_type_received": "plan_approval_request" | "plain_text" | "no_plan_sent",
  "respected_approval_gate": true/false,
  "created_file_before_approval": true/false,
  "conclusion": "..."
}

## 테스트 3: mode=plan 동작 확인

**가설:** mode="plan"으로 spawn하면 teammate가 read-only plan mode에서 시작하여 ExitPlanMode → plan_approval_request 흐름을 따르는지 확인한다.

단계:
1. Agent tool로 teammate 생성: name="test-plan-mode", subagent_type="builder", team_name="api-test", mode="plan", prompt="Your task: create a file /tmp/plan-mode-test.txt with the text 'test'. Propose your plan first."
2. test-plan-mode의 응답을 관찰:
   a. plan mode에서 시작하여 Write/Edit가 차단되는가?
   b. ExitPlanMode를 호출하는가?
   c. plan_approval_request가 lead에게 전달되는가?
3. plan_approval_request를 받으면 approve
4. 승인 후 파일 생성이 진행되는지 확인
5. test-plan-mode에게 shutdown 요청

**기록 형식:**
{
  "test": "plan_mode_spawn",
  "started_in_plan_mode": true/false,
  "write_blocked_before_approval": true/false,
  "used_exit_plan_mode": true/false,
  "sent_plan_approval_request": true/false,
  "conclusion": "..."
}

## 정리

모든 테스트 완료 후:
1. 모든 활성 teammate에게 SendMessage({type: "shutdown_request"})
2. 모든 teammate이 종료되면 TeamDelete
3. /tmp/mode-test.txt, /tmp/plan-test.txt, /tmp/plan-mode-test.txt 삭제
4. 결과를 tests/manual/verification-results.json에 저장

결과 파일 형식:
{
  "verified_at": "2026-04-14T...",
  "claude_code_version": "<확인한 버전>",
  "results": [테스트1, 테스트2, 테스트3]
}
```
