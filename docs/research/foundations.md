# Agent-Atelier — Research Foundations

**Date**: 2026-03-09
**Purpose**: Consolidated factual research reference for agent-atelier
**Status**: Background reference only. Project-specific rules are defined in `docs/design/*`, which take precedence over examples or source terminology in this document.

---

## Table of Contents

1. [Coding Agent Architecture](#1-coding-agent-architecture)
2. [Anthropic's Agentic Design Patterns](#2-anthropics-agentic-design-patterns)
3. [Claude Agent SDK](#3-claude-agent-sdk)
4. [Claude Code Subagents](#4-claude-code-subagents)
5. [Claude Code Agent Teams](#5-claude-code-agent-teams)
6. [Open-Source Multi-Agent Frameworks](#6-open-source-multi-agent-frameworks)
7. [Cross-Framework Patterns](#7-cross-framework-patterns)
8. [Existing skill-set Patterns](#8-existing-skill-set-patterns)
9. [Sources](#9-sources)

---

## 1. Coding Agent Architecture

코딩 에이전트는 **LLM + 제어 루프 + 소프트웨어 하니스(harness)** 로 구성된 시스템으로, 코드 작성·수정·실행·피드백을 반복 수행한다.

### 1.1 LLM, 추론 모델, 에이전트의 관계

| 개념 | 역할 |
|------|------|
| **LLM** | 다음 토큰 예측 엔진 — 단독으로도 코딩 가능하나 복합적 맥락 관리 불가 |
| **추론 모델(Reasoning Model)** | 중간 추론과 검증을 더 많이 수행하도록 훈련된 LLM |
| **에이전트** | 모델 호출, 도구 사용, 상태 갱신, 종료 판단을 반복하는 제어 루프 |
| **에이전트 하니스** | 제어 루프를 감싸는 소프트웨어 — 컨텍스트 관리, 도구 접근, 프롬프트 구성, 상태 제어 담당 |
| **코딩 하니스** | 에이전트 하니스의 코딩 특화 형태 — 리포지토리 컨텍스트, 코드 실행, 테스트, 에러 점검 관리 |

동일한 LLM이라도 하니스 설계에 따라 성능과 사용자 경험이 크게 달라진다. 오픈웨이트 모델도 잘 설계된 하니스에 통합되면 상용 수준의 성능을 낼 수 있다.

### 1.2 오케스트레이션 관점에서의 핵심 구성 요소

코딩 하니스의 6가지 구성 요소 중 오케스트레이션 설계에 직접 관련되는 것만 정리한다. 프롬프트 캐시, 컨텍스트 클리핑/요약, 세션 메모리 분리 등 하니스 내부 최적화는 제외.

**1. 실시간 리포지토리 컨텍스트 (Live Repo Context)**
- 각 에이전트가 현재 Git 리포 상태, 브랜치, 문서, 테스트 명령어 등을 인식해야 역할 수행 가능
- 작업 전 리포 요약 정보를 수집하여 안정된 작업 기반(stable facts) 확보

**2. 역할별 도구 접근 제한 (Tool Access Scoping)**
- 오케스트레이터가 각 역할에 필요한 도구만 노출하여 작업 범위와 권한 경계 설정
- 예: 리뷰어는 읽기 전용, 빌더는 쓰기 포함, 검증 역할은 실행 도구 접근

**3. 하위 에이전트 위임 (Delegation With Bounded Subagents)**
- 보조 작업을 병렬 처리하기 위해 하위 에이전트 생성 (심볼 정의 검색, 설정 파일 확인, 테스트 실패 분석 등)
- 필요한 컨텍스트만 상속, 읽기 전용·재귀 깊이 제한 등으로 경계 설정

### 1.3 실전 관찰

**Progressive Disclosure (3-tier 컨텍스트 로딩)**
- 다수의 스킬/에이전트를 운용할 때 컨텍스트 윈도우 예산 관리 전략
- Metadata tier (항상 로드) → Body tier (트리거 시 로드) → References tier (온디맨드 로드)
- 출처: [revfactory/harness](https://github.com/revfactory/harness)

**Phase 0 Audit (기존 상태 감지 후 선택적 실행)**
- 세션 재개 시 전체 워크플로를 처음부터 돌리지 않고, 기존 구성물(에이전트 정의, 스킬, 설정)을 먼저 스캔하여 필요한 단계만 선택 실행
- 출처: [revfactory/harness](https://github.com/revfactory/harness)

**Loop Guardrail + Reflection (반복 상한 + 반성 단계)**
- 모든 에이전트에 MAX_ITERATIONS 상한 설정, 각 재시도 전 반성 프롬프트 강제: "무엇이 실패했나? 같은 접근을 반복하고 있나?"
- 교착 에이전트 발생을 대폭 감소시키는 실전 패턴
- 출처: Addy Osmani — Claude Code Swarms

**Dedicated Reviewer Teammate (전담 리뷰어 패턴)**
- 읽기 전용 Opus, lint/test/security 도구만 사용, TaskCompleted 이벤트에 자동 트리거
- 빌더 3-4명당 리뷰어 1명 비율; 리드는 항상 검토 완료된 코드만 수신
- 출처: Addy Osmani — Claude Code Swarms

### 1.4 참고 구현

- [Mini Coding Agent](https://github.com/rasbt/mini-coding-agent) — 위 구조를 순수 Python으로 구현한 최소 예시

---

## 2. Anthropic's Agentic Design Patterns

From "Building Effective Agents" (Dec 2024). Anthropic distinguishes **Workflows** (predefined code paths) from **Agents** (LLMs dynamically directing their own processes) and recommends simple, composable patterns over complex frameworks.

**Five workflow patterns:**

| Pattern | Description | When to Use |
|---------|-------------|-------------|
| **Prompt Chaining** | Sequential LLM calls, each processing previous output | Decomposable tasks with clear steps |
| **Routing** | Initial LLM classifies input, dispatches to specialized handlers | Distinct input categories needing different treatment |
| **Parallelization** | LLMs work simultaneously ("sectioning" or "voting") | Independent subtasks or consensus-building |
| **Orchestrator-Workers** | Central LLM decomposes tasks at runtime, delegates to workers, synthesizes | Complex tasks where subtasks aren't known upfront |
| **Evaluator-Optimizer** | One LLM generates, another evaluates in a feedback loop | Iterative quality improvement |

> Anthropic advises starting with direct LLM API calls rather than complex frameworks.

**Source**: https://www.anthropic.com/research/building-effective-agents

---

## 3. Claude Agent SDK

Package: `@anthropic-ai/claude-agent-sdk` (TypeScript, v0.2.71) / `claude-agent-sdk` (Python, 3.10+). Wraps Claude Code CLI as a subprocess — the same runtime powering Claude Code.

### 3.1 Subagent API

Subagents are defined via `agents` parameter in `query()`. Parent must include `"Agent"` in `allowedTools`.

```python
from claude_agent_sdk import query, ClaudeAgentOptions, AgentDefinition

async for message in query(
    prompt="Review the auth module for security issues",
    options=ClaudeAgentOptions(
        allowed_tools=["Read", "Grep", "Glob", "Agent"],
        agents={
            "code-reviewer": AgentDefinition(
                description="Expert code reviewer for quality and security reviews.",
                prompt="You are a code review specialist...",
                tools=["Read", "Grep", "Glob"],
                model="sonnet",
            ),
            "test-runner": AgentDefinition(
                description="Runs and analyzes test suites.",
                prompt="You are a test execution specialist...",
                tools=["Bash", "Read", "Grep"],
            ),
        },
    ),
):
    ...
```

**AgentDefinition fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | `string` | Yes | When to use this agent |
| `prompt` | `string` | Yes | System prompt |
| `tools` | `string[]` | No | Allowed tools (omit = inherit all) |
| `model` | `sonnet/opus/haiku/inherit` | No | Model override |

**Key constraints:**
- Subagents cannot spawn other subagents — never include `"Agent"` in tools
- Context isolation: fresh conversation, no parent history inheritance
- Only receives: own prompt, Agent tool prompt string, project CLAUDE.md
- Multiple subagents can run concurrently
- Can be resumed via `agentId` from result message

**Dynamic factory pattern:**
```python
def create_role_agent(role: str, permissions: list[str]) -> AgentDefinition:
    return AgentDefinition(
        description=f"{role} agent for the development team",
        prompt=ROLE_PROMPTS[role],
        tools=permissions,
        model="opus" if role == "lead" else "sonnet",
    )
```

### 3.2 Session Management

| Operation | Python | TypeScript |
|-----------|--------|------------|
| Create | Default `query()` | Default `query()` |
| Continue | `continue_session=True` | `continue: true` |
| Resume by ID | `resume=session_id` | `resume: session_id` |
| Fork | `resume=id, fork_session=True` | `resume: id, forkSession: true` |
| No persist | — | `persistSession: false` |

Session storage: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`

**Python ClaudeSDKClient (auto session continuity):**
```python
async with ClaudeSDKClient(options=options) as client:
    await client.query("Analyze the auth module")
    async for message in client.receive_response():
        print_response(message)
    # Second query continues same session automatically
    await client.query("Now refactor it to use JWT")
```

**TypeScript V2 Preview (unstable):**
```typescript
await using session = unstable_v2_createSession({ model: "claude-opus-4-6" });
await session.send("Hello!");
for await (const msg of session.stream()) { ... }
```

### 3.3 Hook System

17 available hook events:

| Hook | Python | TypeScript | Trigger |
|------|--------|------------|---------|
| `PreToolUse` | Yes | Yes | Before tool execution (can block/modify) |
| `PostToolUse` | Yes | Yes | After tool result |
| `PostToolUseFailure` | Yes | Yes | Tool failure |
| `UserPromptSubmit` | Yes | Yes | User prompt |
| `Stop` | Yes | Yes | Agent stop |
| `SubagentStart` | Yes | Yes | Subagent init |
| `SubagentStop` | Yes | Yes | Subagent completion |
| `PreCompact` | Yes | Yes | Before compaction |
| `PermissionRequest` | Yes | Yes | Permission dialog |
| `Notification` | Yes | Yes | Status messages |
| `SessionStart` | — | Yes | Session init |
| `SessionEnd` | — | Yes | Session end |
| `TeammateIdle` | — | Yes | Teammate idle |
| `TaskCompleted` | — | Yes | Task done |
| `ConfigChange` | — | Yes | Config change |
| `Setup` | — | Yes | Session setup |
| `WorktreeCreate/Remove` | — | Yes | Worktree events |

**Configuration:**
```python
options = ClaudeAgentOptions(
    hooks={
        "PreToolUse": [
            HookMatcher(matcher="Write|Edit", hooks=[protect_critical_files]),
            HookMatcher(matcher="Bash", hooks=[check_destructive_commands]),
        ],
        "SubagentStop": [HookMatcher(hooks=[subagent_tracker])],
    }
)
```

**Callback return values (PreToolUse):**
- `permissionDecision`: `"allow"` / `"deny"` / `"ask"`
- `permissionDecisionReason`: explanation string
- `updatedInput`: modified tool input (requires `allow`)
- Priority: deny > ask > allow across multiple hooks

### 3.4 Permission Modes

| Mode | Description |
|------|-------------|
| `default` | No auto-approvals; unmatched tools trigger `canUseTool` callback |
| `dontAsk` | Deny instead of prompting (TS only) |
| `acceptEdits` | Auto-accept file ops (Edit, Write, mkdir, rm, mv, cp) |
| `bypassPermissions` | Skip all checks — **DANGER: inherited by subagents, cannot be overridden** |
| `plan` | No tool execution, planning only |

**Evaluation order:** Hooks → Deny rules → Permission mode → Allow rules → `canUseTool` callback

**Dynamic change mid-session:**
```python
q = query(prompt="...", options=ClaudeAgentOptions(permission_mode="default"))
await q.set_permission_mode("acceptEdits")
```

**Tool scoping:** `"Bash(npm:*)"` allows only npm commands in Bash.

### 3.5 Tool Restrictions & Custom Tools

**Built-in tools:** `Read`, `Edit`, `Write`, `Glob`, `Grep`, `Bash`, `WebSearch`, `WebFetch`, `Agent`, `Skill`, `AskUserQuestion`, `TodoWrite`, `ToolSearch`

**Custom tools via in-process MCP:**
```python
from claude_agent_sdk import tool, create_sdk_mcp_server

@tool("get_loop_state", "Read current development loop state", {"path": str})
async def get_loop_state(args):
    with open(args["path"]) as f:
        return {"content": [{"type": "text", "text": f.read()}]}

state_server = create_sdk_mcp_server(
    name="dev-loop", version="1.0.0", tools=[get_loop_state]
)
```

Tools exposed as `mcp__<server-name>__<tool-name>`, requiring explicit `allowedTools` inclusion.

### 3.6 MCP Integration

**Programmatic:**
```python
options = ClaudeAgentOptions(
    mcp_servers={
        "github": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-github"],
            "env": {"GITHUB_TOKEN": os.environ["GITHUB_TOKEN"]},
        }
    },
    allowed_tools=["mcp__github__list_issues"],
)
```

**From `.mcp.json`:** Auto-loaded, standard MCP config format.

**Transport types:** stdio (local), HTTP/SSE (remote), SDK MCP (in-process)

**Tool search for large tool sets:**
```python
options = ClaudeAgentOptions(
    env={"ENABLE_TOOL_SEARCH": "auto:5"}  # Activate at 5% context threshold
)
```

**MCP servers and subagents:** Parent's `mcpServers` config is shared with subagents that inherit those tools.

### 3.7 Cost & Token Limits

| Option | Python | TypeScript |
|--------|--------|------------|
| Max turns | `max_turns=30` | `maxTurns: 30` |
| Max budget | `max_budget_usd=5.0` | `maxBudgetUsd: 5.0` |
| Effort | `effort="high"` | `effort: "high"` |

Result subtypes on limits: `error_max_turns`, `error_max_budget_usd`

**Cost tracking:**
```python
if isinstance(message, ResultMessage):
    print(f"Cost: ${message.total_cost_usd}")
    print(f"Turns: {message.num_turns}")
```

**Session resume after budget limit:**
```python
if message.subtype == "error_max_budget_usd":
    async for msg in query(
        prompt="Continue",
        options=ClaudeAgentOptions(resume=message.session_id, max_budget_usd=5.0)
    ):
        ...
```

### 3.8 Practical Patterns

**Pattern 1: Parallel research subagents**
```
Main Orchestrator
  |-- Subagent 1: Topic A (WebSearch, Read)
  |-- Subagent 2: Topic B (WebSearch, Read)
  \-- Synthesis: Aggregate results
```

**Pattern 2: Cost-optimized model routing**
```python
agents={
    "scanner": AgentDefinition(prompt="...", tools=["Read", "Grep"], model="haiku"),
    "deep-reviewer": AgentDefinition(prompt="...", tools=["Read", "Grep", "Glob"], model="opus"),
}
```

**Pattern 3: Sandboxed file writes via hooks**
```python
async def redirect_to_sandbox(input_data, tool_use_id, context):
    if input_data["tool_name"] == "Write":
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": {
                    **input_data["tool_input"],
                    "file_path": f"/sandbox{input_data['tool_input']['file_path']}",
                },
            }
        }
    return {}
```

**Pattern 4: Session resume on budget exhaustion**
Capture `session_id` from `ResultMessage`, resume with higher `max_budget_usd`.

**Pattern 5: Interactive approval flow**
```typescript
canUseTool: async (toolName, input) => {
    if (toolName === "AskUserQuestion") return handleQuestion(input);
    const approved = await askUser(`Allow ${toolName}?`);
    return approved ? { behavior: "allow" } : { behavior: "deny", message: "Rejected" };
}
```

---

## 4. Claude Code Subagents

Three built-in subagent types:

| Subagent | Model | Tools | Purpose |
|----------|-------|-------|---------|
| **Explore** | Haiku | Read-only | File discovery, code search |
| **Plan** | Inherits | Read-only | Research for plan mode |
| **General-purpose** | Inherits | All tools | Complex multi-step tasks |

**Custom subagents**: Markdown files with YAML frontmatter in `.claude/agents/` (project) or `~/.claude/agents/` (user).

Key configuration fields:
- `name`, `description` (required)
- `tools` / `disallowedTools` — allowlist/denylist
- `model` — sonnet, opus, haiku, or inherit
- `permissionMode` — default, acceptEdits, dontAsk, bypassPermissions, plan
- `maxTurns`, `skills`, `memory`, `background`, `isolation` (git worktree), `hooks`, `mcpServers`

Agent tool spawns subagents. Can restrict spawnable types using `Agent(worker, researcher)` syntax. Supports foreground (blocking) and background (concurrent) execution.

**Source**: https://code.claude.com/docs/en/sub-agents

---

## 5. Claude Code Agent Teams

Experimental feature (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). Requires Opus 4.6+. Available since Claude Code v2.1.32.

### 5.1 Team Definition & Spawning

Teammates are spawned via natural language prompts, not pre-defined config files. The lead calls `spawnTeam` then spawns teammates via `Agent(team_name=...)`.

**Custom `.claude/agents/` files CAN be used as `subagent_type`**, but with significant limitations (GitHub Issue #30703):

| Field | Works for Team Agents | Works for Pure Subagents |
|-------|----------------------|-------------------------|
| `model` | Yes | Yes |
| `disallowedTools` | Yes | Yes |
| System prompt (body) | Yes (fixed in v2.1.69) | Yes |
| `skills` | **Silently ignored** | Yes |
| `hooks` | **Silently ignored** | Yes |
| Other frontmatter | **Silently ignored** | Yes |

### 5.2 Tool Operations

**TeammateTool (13 operations):**

| Operation | Purpose |
|-----------|---------|
| `spawnTeam` | Create team, write config to `~/.claude/teams/{name}/config.json` |
| `discoverTeams` | Find existing teams |
| `cleanup` | Remove team resources (fails if members still active) |
| `write` | Direct message to one teammate |
| `broadcast` | Message all teammates (cost scales with N) |
| `requestJoin` | Request to join team |
| `approveJoin` / `rejectJoin` | Handle join requests |
| `requestShutdown` | Graceful shutdown request |
| `approveShutdown` / `rejectShutdown` | Handle shutdown |
| `approvePlan` / `rejectPlan` | Plan approval workflow |

**Task operations:** `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet` — shared across all team members.

### 5.3 Communication Patterns

**Mailbox system:**
- Storage: `~/.claude/teams/{name}/inboxes/{agent-name}.json` (JSON arrays)
- O(N) per message (read-deserialize-push-serialize-write)
- Detection: polling-based
- **Critical:** Text output from an agent is NOT visible to the team. Must use `write` explicitly.

**Message types (JSON `text` field):**
- `message` — regular text
- `shutdown_request` / `shutdown_approved` / `shutdown_rejected`
- `idle_notification` — auto-sent when teammate stops
- `task_completed` — completion notification
- `plan_approval_request` — requires leader approval
- `join_request` / `permission_request`

**Communication patterns:**
- `write` — direct 1:1 (preferred)
- `broadcast` — all teammates (expensive)
- Idle notifications — automatic
- Shared task list — passive coordination

### 5.4 Task System

**States:** `pending` → `in_progress` (with owner) → `completed`

**Dependencies:** `addBlockedBy: [taskIds]` — blocked tasks cannot be claimed until dependencies complete.

**Storage:** `~/.claude/tasks/{team-name}/` — individual JSON files per task.

**Claiming:** File-locking prevents race conditions. Lead can assign explicitly, or teammates self-claim.

**Sizing:** 5-6 tasks per teammate. Too small = coordination overhead; too large = too long without check-ins.

### 5.5 Team Lifecycle

```
1. spawnTeam → creates config.json + task dirs + inbox dirs
2. TaskCreate → define work items with dependencies
3. Agent(team_name=..., run_in_background=true) → spawn teammates
4. Teammates poll TaskList → claim → execute → mark complete → message lead
5. requestShutdown → approve/reject
6. cleanup → remove team resources
```

**Team config:**
```json
{
  "name": "my-project",
  "leadAgentId": "team-lead@my-project",
  "members": [{
    "agentId": "worker-1@my-project",
    "name": "worker-1",
    "agentType": "general-purpose",
    "model": "haiku",
    "backendType": "in-process"
  }]
}
```

**Environment variables injected:**
- `CLAUDE_CODE_TEAM_NAME`, `CLAUDE_CODE_AGENT_ID`, `CLAUDE_CODE_AGENT_NAME`
- `CLAUDE_CODE_AGENT_COLOR`, `CLAUDE_CODE_PLAN_MODE_REQUIRED`

**Context loading:** Teammates receive project CLAUDE.md, MCP servers, skills (from project), spawn prompt. NOT lead's conversation history.

**Heartbeat:** 5-minute timeout. Crashed workers' tasks can be reclaimed.

### 5.6 Configuration

**Enable:**
```json
{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
```

**Display mode:**
- `auto` (default) — detects tmux/iTerm2/in-process
- `tmux` — visible panes
- `in-process` — same Node.js process, fastest, hidden

Force via: `export CLAUDE_CODE_SPAWN_BACKEND=tmux|in-process`

**Hooks for quality gates:**
```json
{
  "hooks": {
    "TeammateIdle": [{ "hooks": [{ "type": "command", "command": "./scripts/check-quality.sh" }] }],
    "TaskCompleted": [{ "hooks": [{ "type": "command", "command": "./scripts/verify-tests.sh" }] }]
  }
}
```

- `TeammateIdle` input: `session_id`, `teammate_name`, `team_name`
- `TaskCompleted` input: `session_id`, `task_id`, `task_subject`, `task_description`, `teammate_name`, `team_name`
- Exit code 2 = block action + feedback via stderr
- JSON `{"continue": false, "stopReason": "..."}` stops teammate entirely

**Delegate mode:** `Shift+Tab` restricts lead to coordination-only tools. Prevents lead from competing with workers.

### 5.7 Limitations

| Limitation | Detail |
|-----------|--------|
| No session resumption | `/resume` does not restore in-process teammates |
| One team per session | Must clean up before starting new team |
| No nested teams | Teammates cannot spawn teams |
| Fixed lead | Cannot transfer leadership |
| Task status can lag | Teammates sometimes fail to mark tasks completed |
| Slow shutdown | Finishes current request/tool call first |
| Permission inheritance | All teammates inherit lead's mode; cannot set per-teammate at spawn |
| Same-file conflicts | No merge resolution — overlapping edits overwrite |
| Partial custom agent support | `skills` and `hooks` frontmatter silently ignored (Issue #30703) |
| Split panes limited | Not supported in VS Code terminal, Windows Terminal, Ghostty |

### 5.8 Subagents vs. Agent Teams

| Aspect | Subagents | Agent Teams |
|--------|-----------|-------------|
| Invocation | `Agent(subagent_type=...)` | `spawnTeam` + `Agent(team_name=...)` |
| Context | Results return to caller | Fully independent |
| Communication | Report to parent only | Peer-to-peer mailbox |
| Coordination | Parent manages all | Shared task list, self-coordination |
| Lifecycle | Per-invocation (can resume) | Persistent until shutdown+cleanup |
| Nesting | Cannot spawn subagents | Cannot spawn teams |
| Task system | None (parent tracks) | Built-in TaskCreate/Update/List/Get |
| Messaging | None between subagents | write/broadcast/structured messages |
| Cost | Lower (summarized results) | Higher (each = separate instance) |
| Custom agents | Full frontmatter support | Partial (skills/hooks ignored) |
| Best for | Focused, result-only tasks | Complex work needing discussion |

---

## 6. Open-Source Multi-Agent Frameworks

### Framework Comparison

| Framework | Stars | Architecture | Claude Support | Config Format | Key Pattern |
|-----------|-------|-------------|---------------|--------------|-------------|
| **LangGraph** | 80K+ | Graph-based state machine | Yes | Code-first | Supervisor, Swarm, Pipeline, Scatter-gather |
| **CrewAI** | ~44,300 | Role-based teams | Yes (LiteLLM) | YAML | Sequential/hierarchical task execution |
| **AutoGen** | ~54,600 | Conversational patterns | Yes | Code-first | **Maintenance mode** — merging into MS Agent Framework |
| **OpenAI Agents SDK** | ~19,000 | Lightweight primitives | Yes | Code-first | Handoff-based delegation |
| **Google ADK** | ~17,800 | Event-driven, hierarchical agent tree | Yes (LiteLLM) | Code-first | SequentialAgent, CoordinatorAgent, LoopAgent, ParallelAgent |
| **Mastra** | fast-growing | TypeScript-native Agent Networks | Yes | Code-first | LLM-based routing |
| **Pydantic AI** | ~15,200 | Type-safe, model-agnostic | Yes (first-class) | Code-first | FastAPI-style agents, MCP + A2A |
| **Dify** | ~129K | Low-code/visual platform | — | Visual | Drag-and-drop |

---

## 7. Cross-Framework Patterns

### 8.1 Agent Coordination Models

| Model | Description | Frameworks |
|-------|-------------|------------|
| **Supervisor/Coordinator** | One agent dispatches tasks to specialists | LangGraph, ADK, CrewAI hierarchical |
| **Peer Handoff/Swarm** | Agents hand off directly without central control | OpenAI Agents SDK, LangGraph Swarm |
| **Sequential Pipeline** | Assembly-line through ordered agents | Universal |
| **Parallel Fan-out/Fan-in** | Simultaneous distribution, consolidated results | LangGraph scatter-gather, ADK ParallelAgent |
| **Conversational** | Multi-turn dialogue between agents | AutoGen's original pattern |

### 8.2 Agent Communication Mechanisms

- **Shared state**: Agents read/write to common state (LangGraph)
- **Message passing**: Structured messages (AutoGen, ADK events)
- **Direct delegation**: One agent explicitly calls another (CrewAI, OpenAI handoffs)
- **LLM-routed**: LLM decides which agent handles subtask (ADK AutoFlow, Mastra)

### 8.3 Agent Definition Commonalities

Every framework requires:
1. **Identity**: Role/name/description
2. **Goal/Objective**: What the agent should achieve
3. **Instructions**: System prompt or behavior specification
4. **Tools**: Available capabilities
5. **Model**: Which LLM to use

Optional additions:
- Backstory/personality (CrewAI)
- Guardrails (OpenAI Agents SDK)
- Type-safe outputs (Pydantic AI)
- Memory/persistence

### 8.4 Configuration Approaches

| Approach | Frameworks | Pros | Cons |
|----------|------------|------|------|
| **YAML** | CrewAI | Declarative, easy to read | Less flexible |
| **Code-first** | LangGraph, OpenAI SDK, ADK, Mastra, Pydantic AI | Maximum flexibility | More complex |
| **Visual/Low-code** | Dify | Accessible | Limited customization |
| **Markdown + Frontmatter** | Claude Code custom subagents | Natural for Claude skills | Claude-specific |

### 8.5 Emerging Interoperability Standards

- **Agent2Agent (A2A)**: Google-initiated, adopted by ADK, Pydantic AI, CrewAI
- **Model Context Protocol (MCP)**: Anthropic-initiated, widely adopted for tool integration
- **Agent Skills**: Anthropic-initiated open standard for capability packages

---

## 8. Existing skill-set Patterns

### 8.1 Ralph — Sequential Loop with Fresh Context

- Two modes (PLANNING/BUILDING)
- Spawns one Task subagent per iteration with fresh context
- **State**: Plan file on disk (`tmp/ralph/{session-id}/plan.md`)
- **Progress**: Git commits + plan file hash changes
- **Stuck detection**: 3 consecutive iterations with no progress

### 8.2 Consulting-Peer-LLMs — Parallel Multi-Tool Execution

- Detects installed CLI tools (gemini, codex, claude)
- Launches all simultaneously in background
- Waits for all, then synthesizes results
- Shows raw responses first, then consolidates

### 8.3 CodeRabbit-Feedback — Interactive Isolated Subagent

- Three phases: Collection → Discussion → Application
- Severity classification (CRITICAL/MAJOR/MINOR)
- Triple verification system for applied changes

### 8.4 State Management Comparison

| Skill | State Location | Update Frequency | Context Sharing |
|-------|---------------|-----------------|-----------------|
| ralph | Disk (plan.md) | Every iteration | Fresh context per subagent |
| consulting-peer-llms | Memory | Single pass | None (parallel) |
| coderabbit-feedback | GitHub API | Per phase | User approval between phases |

---

## 9. Sources

### Anthropic Official
- [Building Effective Agents](https://www.anthropic.com/research/building-effective-agents)
- [Agent SDK Overview](https://platform.claude.com/docs/en/agent-sdk/overview)
- [Agent SDK Subagents](https://platform.claude.com/docs/en/agent-sdk/subagents)
- [Agent SDK Hooks](https://platform.claude.com/docs/en/agent-sdk/hooks)
- [Agent SDK Permissions](https://platform.claude.com/docs/en/agent-sdk/permissions)
- [Agent SDK Sessions](https://platform.claude.com/docs/en/agent-sdk/sessions)
- [Agent SDK MCP Integration](https://platform.claude.com/docs/en/agent-sdk/mcp)
- [Agent SDK Custom Tools](https://platform.claude.com/docs/en/agent-sdk/custom-tools)
- [Agent SDK Cost Tracking](https://platform.claude.com/docs/en/agent-sdk/cost-tracking)
- [Agent SDK TypeScript V2 Preview](https://platform.claude.com/docs/en/agent-sdk/typescript-v2-preview)
- [Agent SDK Demos](https://github.com/anthropics/claude-agent-sdk-demos)
- [Building Agents Blog](https://claude.com/blog/building-agents-with-the-claude-agent-sdk)
- [Building Agents with Claude Agent SDK](https://www.anthropic.com/engineering/building-agents-with-the-claude-agent-sdk)
- [Multi-Agent Research System](https://www.anthropic.com/engineering/multi-agent-research-system)
- [Anthropic Cookbook - Agent Patterns](https://github.com/anthropics/anthropic-cookbook/tree/main/patterns/agents)

### Claude Code
- [Claude Code Custom Subagents](https://code.claude.com/docs/en/sub-agents)
- [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams)
- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [GitHub Issue #30703 — Custom agent definitions for teams](https://github.com/anthropics/claude-code/issues/30703)

### Agent Teams Community Resources
- [Addy Osmani — Claude Code Swarms](https://addyosmani.com/blog/claude-code-agent-teams/)
- [Swarm Orchestration Skill (Gist)](https://gist.github.com/kieranklaassen/4f2aba89594a4aea4ad64d753984b2ea)
- [Porting Agent Teams to OpenCode](https://dev.to/uenyioha/porting-claude-codes-agent-teams-to-opencode-4hol)
- [Claude Code's Hidden Multi-Agent System](https://paddo.dev/blog/claude-code-hidden-swarm/)
- [Agent Teams Controls Guide](https://claudefa.st/blog/guide/agents/agent-teams-controls)
- [From Tasks to Swarms](https://alexop.dev/posts/from-tasks-to-swarms-agent-teams-in-claude-code/)

### Open-Source Frameworks
- [LangGraph](https://github.com/langchain-ai/langgraph)
- [CrewAI](https://github.com/crewAIInc/crewAI)
- [Microsoft AutoGen](https://github.com/microsoft/autogen)
- [OpenAI Agents SDK](https://github.com/openai/openai-agents-python)
- [Google ADK](https://github.com/google/adk-python)
- [Mastra](https://github.com/mastra-ai/mastra)
- [Pydantic AI](https://github.com/pydantic/pydantic-ai)
- [Dify](https://github.com/langgenius/dify)
