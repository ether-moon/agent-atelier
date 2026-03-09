# Agent-Atelier — System Design

**Date**: 2026-03-09
**Status**: Draft v2
**Research Foundations**: [Research Foundations](../research/foundations.md)

---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [Organization Chart](#2-organization-chart)
3. [Role Definitions](#3-role-definitions)
4. [State Machine — Development Loop](#4-state-machine--development-loop)
5. [Escalation Protocol](#5-escalation-protocol)
6. [Autonomy Boundaries](#6-autonomy-boundaries)
7. [Document Architecture](#7-document-architecture)
8. [Communication Schema (JSON)](#8-communication-schema-json)
9. [Role Prompt Skeletons](#9-role-prompt-skeletons)
10. [Claude Implementation Mapping](#10-claude-implementation-mapping)
11. [Phase-Based Activation Patterns](#11-phase-based-activation-patterns)
12. [Core Operating Rules](#12-core-operating-rules)
13. [Constraints & Limitations](#13-constraints--limitations)
14. [TODO](#14-todo)

---

## 1. Design Philosophy

### What This System Is

An **autonomous product development loop** — not just "an implementation agent team," but a system that cycles through the entire product lifecycle: spec refinement → implementation → testing → QA/research → spec revision → re-implementation, with the team self-correcting on reversible/local decisions while escalating only irreversible/product-altering decisions to the human.

### Core Principles

1. **Documents are truth, conversations are ephemeral.** Teammates and subagents read project context (CLAUDE.md, files on disk) but do NOT inherit the lead's conversation history. Long-running loops drift without file-based state.
2. **Core roles stay active; specialist roles activate on demand.** Always-on large teams slow convergence and inflate token cost. Official guidance recommends 3–5 teammates.
3. **Separate validation execution from validation interpretation.** One agent runs tests/browsers/screenshots; reviewers consume the same evidence. This prevents browser session collisions and duplicate test processes.
4. **Artifacts over opinions.** Every decision must land in a log file. Every validation must produce an evidence bundle. Every spec change must update the Behavior Spec.
5. **Narrow human gates, wide auto-proceed.** The team autonomously handles reversible/local choices; only irreversible or product-meaning changes reach the human.
6. **Human gates are non-blocking by default.** When a decision requires human approval, the team does NOT stop all work. It continues progressing on unrelated tasks while the gated item waits. Only truly blocking dependencies (where no other work can proceed without the answer) cause a full halt. See [Human Gate Operations](./human-gate-ops.md) for tracking details.
7. **All agents are generalists.** Roles exist to prevent attention scatter and maintain focus, not to match specialization. Every agent is the same LLM — roles constrain attention, assign accountability, and prevent scope creep.
8. **Quality over token efficiency.** When a design choice trades quality for efficiency, choose quality. Token efficiency is a welcome side effect, never a design driver.
9. **Full implementation from the start.** No MVP/prototype compromises — partial approaches create more rework than building the full model correctly once. Every design decision targets the complete architecture.

### Design Tradeoff Rationale

| Concern | Decision | Rationale |
|---------|----------|-----------|
| All roles always active | Core 4 + conditional specialists | Official docs: 3–5 teammates; more = more coordination cost |
| Aesthetic UX every loop | Milestone-only activation | Prevents endless polish loops |
| Each reviewer runs own browser | Single Validation Runtime Manager | Avoids deadlocks, state corruption, duplicate processes |
| Conversation-based state | File-based state | Teammates don't inherit lead's conversation history |
| "20% change" threshold | Irreversibility + blast radius criteria | Mechanical, unambiguous gate criteria |
| Specialization-framed roles | Focus-framed roles | All agents are generalists; roles constrain attention, not capability |
| Token efficiency as driver | Quality as driver | Quality output is the goal; efficiency is a welcome side effect |
| FE/BE builder split | Full-stack Builder | Vertical-slice scenarios reduce coordination overhead and file conflicts |

---

## 2. Organization Chart

```
                        ┌─────────────────────┐
                        │    Human (User)      │
                        └──────────┬───────────┘
                                   │ Level 4 only
                        ┌──────────▼───────────┐
                        │  Team Lead /          │
                        │  Orchestrator         │
                        └──┬───────────────┬────┘
                           │               │
              ┌────────────▼──┐    ┌───────▼────────────┐
              │  PM /          │    │  Tech Lead /        │
              │  Spec Owner    │    │  Architect          │
              └────────┬───────┘    └───┬──────────┬─────┘
                       │                │          │
            ┌──────────▼──────────┐     │    ┌─────▼──────────────┐
            │  Verification       │     │    │  Execution          │
            │  Part               │     │    │  Part               │
            │  (trigger: PM)      │     │    │  (managed: TL)      │
            ├─────────────────────┤     │    ├─────────────────────┤
            │ • QA Reviewer       │     │    │ • UI Designer [C]   │
            │ • Pragmatic UX [C]  │     │    │ • Builder       [C] │
            │ • Aesthetic UX [C*] │     │    │   (full-stack)      │
            └─────────────────────┘     │    └─────────────────────┘
                                        │
                              ┌─────────▼─────────┐
                              │  Validation        │
                              │  Runtime Manager   │
                              └───────────────────┘

[C]  = Conditional — activated on demand
[C*] = Conditional, milestone-only
```

### Role Classification

| Category | Roles | Activation |
|----------|-------|------------|
| **Always-on Core** | Team Lead, PM, Tech Lead, Validation Runtime Manager | Every loop iteration |
| **Conditional Executors** | Builder (full-stack), UI Designer | When implementation is needed |
| **Conditional Reviewers** | QA Reviewer, Pragmatic UX Reviewer | Most validation loops |
| **Milestone-only** | Aesthetic UX Reviewer | Release candidates, major milestones |

---

## 3. Role Definitions

### 3.1 Team Lead / Orchestrator

| Aspect | Detail |
|--------|--------|
| **Focus** | Loop state transitions, role invocation decisions, final merge, human gate judgment, sole user-facing communication |
| **Stay focused on** | Orchestration and decision routing. Don't get pulled into writing specs or implementing code — that's not your focus right now. |
| **Operating rule** | Delegate over direct implementation. Direct fix only when all executors are idle AND a single trivial fix remains |
| **Outputs** | `loop-state.json`, active work-items summary, risk register, next action decision |

> **Why the "no direct implementation" rule**: Official docs note that leads often skip waiting for teammates and implement directly. Anthropic explicitly recommends instructing the lead to wait.

### 3.2 PM / Spec Owner

| Aspect | Detail |
|--------|--------|
| **Focus** | Defining behaviors and acceptance states. Your job is specifying what the system should do — stay focused on that. |
| **Stay focused on** | Behavior Spec authoring/revision, acceptance criteria maintenance, assumption log, decision log, feedback classification. Don't get pulled into implementation details — that's not your focus right now. |
| **Codebase exploration** | Explore existing code via Explore subagents to understand current policies and behaviors. Keep your own context focused on spec authoring — delegate specific questions to subagents and receive summarized answers. |
| **Feedback classification** | Every piece of implementation feedback → one of: `bug`, `spec_gap`, `ux_polish`, `product_level_change` |
| **Open Questions** | Apply 3-test gate criteria (irreversibility, blast radius, product meaning) to decide: human gate → HDR file, or team-resolvable → log in `assumptions.md` |
| **Outputs** | Behavior Spec deltas, acceptance criteria deltas, open questions, decision proposals |

### 3.3 Tech Lead / Architect

| Aspect | Detail |
|--------|--------|
| **Focus** | Translating specs into implementable work items and coordinating builders. Your job is decomposition and technical coordination — stay focused on that. |
| **Stay focused on** | Decompose specs into vertical-slice work items, assign file ownership, invoke builders, technical risk assessment. Don't get pulled into filling spec gaps with product decisions — that's the PM's focus. |
| **Autonomy scope** | Local, reversible technical choices (see [Section 6](#6-autonomy-boundaries)) |
| **Work item pattern** | Vertical slices per scenario, not horizontal layers. Each work item = everything needed to make one Behavior pass. |
| **Outputs** | `work-items.json`, dependency graph, `file-ownership.md`, technical risk notes |

### 3.4 Validation Runtime Manager

| Aspect | Detail |
|--------|--------|
| **Focus** | Executing all validation tooling and producing reusable evidence bundles. Your job is running tests and collecting evidence — stay focused on that. |
| **Stay focused on** | Execute test suites, run Playwright scenarios, accessibility checks (axe), screenshot collection, evidence bundle assembly. Don't make product judgments or attempt code fixes — that's not your focus right now. |
| **Key principle** | Single point of test execution — prevents multiple test processes, deadlocks, and environment contamination |
| **Outputs** | Validation report, evidence bundle (screenshots, logs, traces), pass/fail summary |

### 3.5 Conditional Executors

#### UI Designer
- Design system management and direction
- Acts as UI architect BEFORE frontend implementation begins
- Activated when: new screens, information architecture changes, design system impact

#### Builder (Full-Stack)
- Implements vertical-slice scenarios per Tech Lead's work items
- Handles frontend, backend, API, DB — whatever the assigned scenario requires
- Owns all file paths needed for their scenario during implementation
- Must receive UI Designer guidance before starting (when applicable)
- **Stay focused on** implementing the assigned scenario. Don't revise the spec mid-implementation — that's the PM's job.

### 3.6 Conditional Reviewers

#### QA Reviewer
- Validates implementation correctness against specs and requirements
- Detects functional defects
- Consumes evidence from Validation Runtime Manager (does NOT run own tests)

#### Pragmatic UX Reviewer
- Evaluates usability, accessibility, intuitiveness from a practical standpoint
- Uses Playwright/browser tools via evidence from Validation Runtime Manager
- Participates in most validation loops

#### Aesthetic UX Reviewer
- Evaluates visual trends, aesthetic refinement, interface sophistication
- Milestone/release candidate reviews only
- **Why milestone-only**: Always-on aesthetic review creates endless polish loops

---

## 4. State Machine — Development Loop

```
DISCOVER ──► SPEC_DRAFT ──► SPEC_HARDEN ──► BUILD_PLAN ──► IMPLEMENT
                                 ▲                              │
                                 │                              ▼
                            AUTOFIX ◄──── REVIEW_SYNTHESIS ◄── VALIDATE
                                 │               │
                                 │               ▼
                                 │         HUMAN_GATE
                                 │               │
                                 └───────────────┘
                                                  └──► DONE
```

### State Definitions

#### DISCOVER
- **Input**: User's service concept / requirements
- **Actors**: Lead + PM + Tech Lead (separate agents, each explores from own perspective)
- **Activity**: Gap analysis, initial requirement decomposition. PM explores user needs and behavior gaps; Tech Lead assesses feasibility and architecture constraints; Lead judges scope, priority, and human gate candidates.
- **Output**: `open-questions.md`, `assumptions.md`

#### SPEC_DRAFT
- **Actors**: PM (with Explore subagents for codebase investigation)
- **Activity**: Write Behavior Spec first draft including Goal, Current State (via subagent exploration), Behaviors with UI States tables and Verify sections, Constraints, Out of Scope
- **Output**: `behavior-spec.md` (draft)

#### SPEC_HARDEN
- **Actors**: PM + Tech Lead + (optional) UI Designer
- **Activity**: Tech Lead challenges PM's spec ("this Behavior is unimplementable because..."), PM revises, Tech Lead re-confirms. Reviews implementability, requests missing UI state / API contract / error handling specs.
- **Rules**:
  - Reversible, local gaps → auto-fill (log in `assumptions.md`)
  - Irreversible, product-meaning gaps → human gate candidate (PM applies 3-test criteria)
- **Output**: `behavior-spec.md` (hardened), `assumptions.md` (updated)

#### BUILD_PLAN
- **Actors**: Tech Lead
- **Activity**: Create vertical-slice work items with file ownership, dependencies, definition of done. Each work item maps to one or more Behaviors.
- **Rules**: Never assign overlapping file sets to multiple builders
- **Output**: `work-items.json`, `file-ownership.md`

#### IMPLEMENT
- **Actors**: Tech Lead + Builder(s) + (optional) UI Designer
- **Activity**: Code production. Each Builder implements everything needed (frontend, backend, API, DB) to make their assigned scenario pass.
- **Rules**:
  - One builder per file set at any time
  - Frontend work: UI Designer review first → Builder
  - Risky operations: read-only plan mode review first
- **Output**: Code changes, git commits

#### VALIDATE
- **Actors**: Validation Runtime Manager
- **Activity**: Single execution pass — tests, Playwright, accessibility, screenshots
- **Output**: Evidence bundle at `docs/qa/validation/{date}-run-{n}/`

#### REVIEW_SYNTHESIS
- **Actors**: PM + QA Reviewer + Pragmatic UX Reviewer + (optional) Aesthetic UX Reviewer
- **Activity**:
  - Reviewers independently interpret the SAME evidence bundle
  - QA and UX Reviewers debate findings from same evidence → PM arbitrates
  - PM classifies all feedback into 4 categories:
    - `bug` → AUTOFIX
    - `spec_gap` → AUTOFIX (via SPEC_HARDEN)
    - `ux_polish` → AUTOFIX
    - `product_level_change` → HUMAN_GATE
- **Output**: Classified feedback report

#### AUTOFIX
- **Trigger**: `bug`, `spec_gap`, or `ux_polish` feedback
- **Activity**: Automatic regression to SPEC_HARDEN or IMPLEMENT
- **Key**: No human approval needed

#### HUMAN_GATE
- **Trigger**: `product_level_change` or irreversible/high-blast-radius decisions
- **Activity**: Lead compiles impact report → asks user → enters non-blocking wait
- **Non-blocking principle**: The gated item is parked, but the team continues working on all unrelated tasks. Only when the gated decision is a true upstream dependency for ALL remaining work does the loop fully halt. See [Human Gate Operations](./human-gate-ops.md).
- **Resume**: User approval → SPEC_HARDEN or BUILD_PLAN

#### DONE
- **Conditions**:
  - All acceptance criteria met
  - No blocking issues
  - Validation evidence exists
  - PM + Lead confirm release candidate

---

## 5. Escalation Protocol

### 4-Level Communication Hierarchy

#### Level 1 — Bug Fast Track
```
PM/QA ──► Tech Lead (Direct)
```
- Obvious bugs requiring code-level fix only (button not clickable, API 500)
- No Behavior Spec modification needed
- Tech Lead dispatches to appropriate builder

#### Level 2 — Spec Clarification
```
Tech Lead ──► PM
```
- Missing edge case handling, undefined UI states (e.g., loading state design)
- Tech Lead does NOT guess — requests spec supplement from PM

#### Level 3 — Trade-off Escalation
```
Tech Lead / PM ──► Team Lead
```
- "Implementing this spec will degrade performance by 50%"
- "This design requires a complete library replacement"
- Team Lead decides considering project timeline and goals

#### Level 4 — Human-in-the-Loop
```
Team Lead ──► User (Human)
```
- Major Behavior Spec revision proposals
- "Redesign the entire UI concept" recommendations
- Lead compiles impact analysis report → submits to user → enters **non-blocking wait**
- **Non-blocking**: The gated item is parked, but the team continues all unrelated work. Full halt only when the gated decision blocks ALL remaining tasks.
- **Critical**: Subagents cannot ask the user directly (SDK limitation: `AskUserQuestion` unavailable in Task-spawned subagents). All human-facing queries MUST route through Lead.

---

## 6. Autonomy Boundaries

### Auto-Proceed (Team Decides Autonomously)

These decisions are made by the team, logged in `assumptions.md`, and never escalated:

- Loading / error / empty state UI
- Button disable/enable rules
- Default sort order, page size
- Standard form validation rules
- Spacing/typography choices within the design system
- API retry/timeout conservative defaults
- Test data composition
- Minor refactoring necessary for implementation
- Copy/layout polish that doesn't break acceptance criteria
- Exception handling within existing flows

### Human Gate (Must Escalate)

These decisions ALWAYS go to the user:

- Core user flow changes
- Information architecture / navigation structure changes
- Authentication / authorization / privacy / payment / legal implications
- Database schema breaking changes
- Public API breaking changes
- Major external dependency additions or replacements
- QA/UX findings indicating "the current direction itself is wrong" (pivot-level)
- KPI interpretation or target user assumption changes

### Decision Criteria

The gate criterion is NOT a vague threshold like "20% or more modification." Instead, apply these three tests:

| Test | Question |
|------|----------|
| **Irreversibility** | Can this be undone without significant cost? |
| **Blast Radius** | How many components/users/systems does this affect? |
| **Product Meaning** | Does this change what the product IS or WHO it's for? |

If any test scores HIGH → HUMAN_GATE.

---

## 7. Document Architecture

### Product Documents (Source of Truth)

```
docs/product/
├── behavior-spec.md             # Behavior Spec (replaces traditional PRD)
├── success-metrics.md           # Business metrics (NOT referenced in agent workflow)
├── assumptions.md               # Auto-filled assumptions with Impact × Uncertainty matrix
├── open-questions.md            # Unresolved questions for human
└── decision-log.md              # All decisions with rationale
```

### Behavior Spec Format

The Behavior Spec replaces the traditional PRD. Every statement must be verifiable by agent tools.

```markdown
# [Feature Name]

## Goal
[1-2 sentences. What and why. No narrative.]

## Current State
[File paths and existing components relevant to this feature.
 Written by PM via Explore subagent investigation.
 Reduces agent exploration cost.]

## Behaviors
[Primary content. Organized by user-observable behavior.
 Each Behavior block = one end-to-end testable scenario.
 Builders implement everything needed (frontend, backend, API, DB)
 to make that scenario pass.]

### B1: [Behavior title]
- [Testable behavior statements]
- [Given/When/Then without BDD ceremony]

**UI States:**
| State | Condition | Display |
|-------|-----------|---------|
| Default | ... | ... |
| Loading | ... | ... |
| Error | ... | ... |
| Success | ... | ... |

**Verify:**
- test: [unit/integration assertion]
- e2e: [Playwright scenario]
- axe: [accessibility check]
- lint: [static analysis check]

## Constraints
[Hard limits that restrict implementation choices.
 Only code-verifiable constraints — no runtime measurements.]

## Out of Scope
[Explicit exclusions to prevent agent scope creep.]

## Open Questions
[Unresolved items linked to specific Behaviors they block.
 PM applies 3-test criteria to decide: human gate vs team-resolvable.]
```

**Key principles:**
- Each Behavior block IS the acceptance criteria — no separate AC section
- UI States table is mandatory for every interaction, not optional
- Current State section = exploration map for the agent, written by PM via subagent exploration
- Open Questions link to specific Behaviors → direct human gate mapping
- The Verify section is literally the test suite the Builder must satisfy

### Verification Taxonomy

All verification criteria must be binary (pass/fail) and executable by agent tools. No percentages, no subjective judgment, no environment-dependent metrics.

| Prefix | Tool | Judgment |
|--------|------|----------|
| `test:` | Unit/integration test runner | Assertion pass/fail |
| `e2e:` | Playwright scenario | Scenario complete/fail |
| `axe:` | Accessibility checker | 0 violations / N violations |
| `lint:` | TypeScript + linter | 0 errors / N errors |

**Excluded from spec:** Runtime performance metrics (load time, response time), business metrics (conversion rate, engagement), subjective quality (intuitive, fast, clean).

When performance matters, express as implementation constraints (causes) rather than runtime measurements (effects):

| Don't (unmeasurable at build time) | Do (code-verifiable) |
|---|---|
| "Page loads in under 2s" | "No blocking JS in critical path; images use lazy loading" |
| "API responds in 200ms" | "Query uses index on email column; no N+1 queries" |
| "Handles high traffic" | "Stateless API; no server-side session storage" |
| "Fast checkout" | "Bundle size < 150KB gzipped" |

### Business Metrics

Business metrics (conversion rate, engagement, revenue impact) go in `docs/product/success-metrics.md` — a separate document NOT referenced in the agent workflow. If an agent reads "improve conversion by 20%," it will attempt to reflect this with no way to verify or achieve it, wasting cycles.

### Assumption Categorization

`assumptions.md` uses an Impact x Uncertainty matrix:

| | High Uncertainty | Low Uncertainty |
|---|---|---|
| **High Impact** | Human gate candidate | Monitor |
| **Low Impact** | Defer validation | Ignore |

High Impact + High Uncertainty assumptions naturally map to human gate triggers via the 3-test criteria (irreversibility, blast radius, product meaning change).

### Design Documents

```
docs/design/
├── system-design.md             # This document
├── human-gate-ops.md            # Human gate tracking operations
├── ui-spec.md                   # UI states, layouts, interactions
└── design-principles.md         # Design system rules and constraints
```

### Engineering Documents

```
docs/engineering/
├── tech-spec.md                 # Technical architecture decisions
├── api-contracts.md             # API interface definitions
└── file-ownership.md            # Current file → owner mapping
```

### QA & Validation

```
docs/qa/
├── test-plan.md                 # Test strategy and coverage
└── validation/
    ├── {date}-run-{n}.md              # Validation report
    └── {date}-run-{n}-evidence/       # Screenshots, logs, traces
```

### Orchestration (Machine-Readable)

```
docs/orchestration/
├── loop-state.json              # Current state machine position
├── work-items.json              # Task graph with ownership
├── escalations/                 # Active escalation records
└── human-gates/                 # Pending human decisions
```

---

## 8. Communication Schema (JSON)

### 8.1 Work Item

Work items are vertical slices — each maps to one or more Behaviors and includes all layers (frontend, backend, API, DB) needed to make the scenario pass.

```json
{
  "id": "WI-014",
  "title": "Checkout page empty/loading/error states",
  "owner_role": "builder",
  "depends_on": ["WI-003"],
  "behaviors": ["B3", "B4"],
  "input_artifacts": [
    "docs/product/behavior-spec.md#B3",
    "docs/product/behavior-spec.md#B4",
    "docs/design/ui-spec.md#checkout-states"
  ],
  "owned_paths": [
    "apps/web/src/pages/checkout/",
    "apps/web/src/components/checkout/",
    "apps/api/src/routes/checkout/",
    "apps/api/src/services/checkout/"
  ],
  "verify": [
    "test: checkout empty state renders placeholder",
    "test: checkout loading state shows spinner",
    "test: checkout error state enables retry",
    "e2e: checkout page loads and transitions through states",
    "axe: checkout page has no accessibility violations"
  ],
  "status": "pending"
}
```

### 8.2 Escalation

```json
{
  "id": "ESC-007",
  "raised_by": "tech-lead",
  "level": "human_gate",
  "reason_type": "breaking_api_change",
  "summary": "Current Behavior Spec implies a public API response shape change.",
  "impact": {
    "product": "low",
    "engineering": "medium",
    "ux": "low",
    "risk": "high"
  },
  "options": [
    {
      "id": "A",
      "label": "Preserve current API and adapt frontend",
      "tradeoffs": ["More frontend mapping code", "No breaking change"]
    },
    {
      "id": "B",
      "label": "Change API response shape",
      "tradeoffs": ["Cleaner contract", "Breaking change for existing clients"]
    }
  ],
  "recommended_option": "A",
  "status": "open"
}
```

### 8.3 Validation Finding

```json
{
  "id": "VAL-031",
  "reviewer_role": "pragmatic-ux-reviewer",
  "severity": "medium",
  "category": "usability",
  "evidence": [
    "docs/qa/validation/2026-03-08-run-01.md#finding-4",
    "docs/qa/validation/2026-03-08-run-01-evidence/checkout-error.png"
  ],
  "summary": "Retry button is below the fold on smaller screens.",
  "recommendation": "Move retry action above supporting copy.",
  "requires_human": false
}
```

### 8.4 Human Decision Request

```json
{
  "id": "HDR-002",
  "triggered_by": "pm",
  "question": "Should checkout allow guest purchases?",
  "why_now": "Current flow blocks completion for non-signed-in users.",
  "options": [
    "Require sign-in before checkout",
    "Allow guest checkout",
    "Defer checkout and collect email only"
  ],
  "blocking": false,
  "blocked_work_items": ["WI-022"],
  "unblocked_work_items": ["WI-011", "WI-019", "WI-005"],
  "default_if_no_response": "continue_unblocked_work",
  "linked_escalations": ["ESC-009"]
}
```

---

## 9. Role Prompt Skeletons

### Design Principle

Prompts use **focus framing**, not specialization framing. Every agent is a generalist LLM — roles constrain attention and prevent scope creep. Prompts define: **focus / guardrails / inputs / outputs**. All role-specific domain knowledge is embedded directly in prompts (Agent Teams silently ignores `skills` and `hooks` frontmatter).

### Team Lead / Orchestrator

```
Your job is driving the product development loop to satisfy all acceptance
criteria autonomously. Stay focused on orchestration and decision routing.

FOCUS:
- Decide current loop state and transitions
- Choose which roles to invoke and when
- Open human gates when criteria are met
- Perform final merge and release candidate judgment
- You are the sole channel to the human

GUARDRAILS:
- Don't get pulled into writing specs — that's the PM's focus right now
- Don't get pulled into implementing code — that's the Builder's focus
- Don't push human-approval decisions down to other roles

ESCALATION RULE:
If a teammate needs user input, they MUST escalate to you. You are the
sole channel to the human. Use AskUserQuestion only through your own context.

HUMAN GATE RULE:
When you open a human gate, do NOT halt all work. Park the gated item and
continue driving all tasks that are not blocked by the pending decision.
Only enter full halt when the gated decision is an upstream dependency for
ALL remaining work items.

DIRECT IMPLEMENTATION EXCEPTION:
Only fix code yourself when ALL executors are idle AND only a single trivial
fix remains. In all other cases, delegate.

OUTPUTS: loop-state.json, work-items summary, risk register, next action.
```

### PM / Spec Owner

```
Your job is defining behaviors — what the system should do, in every state,
for every user. Stay focused on spec authoring.

FOCUS:
- Write and revise the Behavior Spec as the single source of product truth
- Classify implementation feedback into: bug | spec_gap | ux_polish | product_level_change
- Auto-fill reversible/local spec gaps (log in assumptions.md)
- Apply 3-test gate criteria to Open Questions: human gate or team-resolvable

YOUR DOCUMENTS: behavior-spec.md, assumptions.md, decision-log.md

CODEBASE EXPLORATION:
Explore existing code via Explore subagents to understand current policies
and behaviors. Keep your own context focused on spec authoring — delegate
specific questions ("What validation rules does the current form apply?")
to subagents and receive summarized answers. The raw code doesn't need to
live in your context window.

GUARDRAILS:
- Don't get pulled into implementation details — that's not your focus
  right now
- You can explore code to inform spec decisions, but your output is the
  Behavior Spec
- Don't run tests — that's the VRM's focus

ESCALATION: If a spec gap changes product meaning, propose a human gate to Lead.

OUTPUTS: Behavior Spec deltas, acceptance criteria deltas, open questions,
decision proposals.
```

### Tech Lead / Architect

```
Your job is translating specs into implementable work items and coordinating
builders. Stay focused on decomposition and technical coordination.

FOCUS:
- Decompose Behavior Spec into vertical-slice work items with file ownership
- Invoke builders and assign scenarios
- Make local, reversible technical decisions autonomously
- Request UI Designer guidance before frontend-heavy scenarios

WORK ITEM PATTERN:
Each work item = everything needed to make one Behavior pass. Vertical slices,
not horizontal layers. One builder owns all files for their scenario.

GUARDRAILS:
- Don't get pulled into filling spec gaps with product decisions — if the
  spec is silent, ask PM for clarification
- Don't assign overlapping file sets to multiple builders simultaneously
- Don't proceed with breaking changes without escalation

OUTPUTS: work-items.json, dependency graph, file-ownership.md, technical risks.
```

### Validation Runtime Manager

```
Your job is executing all validation tooling and producing reusable evidence
bundles. Stay focused on test execution and evidence collection.

FOCUS:
- Run test suites, Playwright scenarios, accessibility checks, screenshot capture
- Produce evidence bundles at standard paths

GUARDRAILS:
- Don't make product judgments — that's the PM's and reviewers' focus
- Don't modify specs or fix code — report what you find, others will act on it

OUTPUTS: Validation report, evidence bundle, pass/fail summary at
docs/qa/validation/{date}-run-{n}/
```

### Builder (Full-Stack)

```
Your job is implementing the assigned scenario end-to-end. Stay focused on
making the Verify checks pass.

FOCUS:
- Implement everything needed (frontend, backend, API, DB) for your
  assigned Behavior(s)
- Own all file paths in your work item
- The Verify section in the Behavior Spec IS your test suite — make it pass

GUARDRAILS:
- Don't revise the spec mid-implementation — that's the PM's job. If the
  spec is unclear, ask Tech Lead for clarification
- Don't modify files outside your assigned ownership
- Don't start frontend work without UI Designer guidance (when applicable)

OUTPUTS: Code changes, git commits, passing verification checks.
```

### QA / UX Reviewers (Common Pattern)

```
Your job is interpreting validation evidence and producing actionable feedback.
Stay focused on your review perspective.

INPUT: Evidence bundle from Validation Runtime Manager (same evidence for all
reviewers).

FOCUS:
- Read and interpret evidence from your perspective:
  - QA: spec compliance, functional defects
  - Pragmatic UX: usability, accessibility, intuitiveness
  - Aesthetic UX: visual trends, refinement, interface sophistication

GUARDRAILS:
- Don't launch your own browser sessions or test processes — the VRM
  provides the evidence
- Don't duplicate findings already reported by other reviewers
- Don't modify code or specs — report findings, others will act on them

OUTPUTS: Feedback report with severity, evidence references, recommendations.
```

---

## 10. Claude Implementation Mapping

### Architecture: Agent Teams as Primary

Agent Teams is the primary architecture for the entire development loop. The core purpose of this system is **mutual auditing and complementing** between roles — subagents (result-only, no peer communication) cannot achieve this. Agent Teams enable teammates to message each other, debate, challenge, and build on each other's work.

```
┌─────────────────────────────────────────────────────┐
│  Claude Agent SDK (Outer Loop)                      │
│  - Session management (resume/fork)                 │
│  - Permission control                               │
│  - Cost limits                                      │
│  - Monitoring                                       │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  One Flat Team — Entire Development Loop      │  │
│  │                                               │  │
│  │  Lead (team lead — orchestrator)              │  │
│  │    ├── PM (teammate — always-on)              │  │
│  │    │     └── Explore subagents (codebase      │  │
│  │    │         investigation, not team members)  │  │
│  │    ├── Tech Lead (teammate — always-on)       │  │
│  │    ├── VRM (teammate — always-on)             │  │
│  │    ├── Builder 1..N (spawned per scenario)    │  │
│  │    ├── QA Reviewer (spawned for validation)   │  │
│  │    └── UX Reviewer (spawned for validation)   │  │
│  │                                               │  │
│  │  Conditional roles spawned/shutdown on demand  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Why This Architecture

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| **Outer loop** | Claude Agent SDK | Production-ready: headless mode, permissions, monitoring, session management. Used internally at Anthropic. |
| **Primary execution** | Agent Teams (one flat team) | Mutual auditing is the core purpose. Teammates can message, debate, challenge each other. |
| **Codebase exploration** | Subagents (PM's Explore agents only) | PM delegates specific questions to keep own context focused on spec authoring. Not team members. |
| **Role knowledge** | Embedded in prompts | Agent Teams silently ignores `skills` and `hooks` frontmatter (Issue #30703). All role-specific knowledge must go in prompts. |

### Mutual Auditing in Practice

- **SPEC_HARDEN**: Tech Lead challenges PM's spec ("this Behavior is unimplementable because...") → PM revises → Tech Lead re-confirms
- **IMPLEMENT**: Builder asks Tech Lead for clarification → Tech Lead consults PM → answer flows back
- **REVIEW_SYNTHESIS**: QA and UX Reviewers debate findings from same evidence → PM arbitrates

### Session Crash Recovery

Agent Teams cannot restore teammates on session resume. Mitigation: file-based state (`loop-state.json`, `work-items.json`, Behavior Spec, git commits) is the source of truth (Core Rule #1). A new session spawns a fresh team, reads file state, and continues from last committed checkpoint.

### Hooks (Project-Level)

All hooks must be defined at the project level since Agent Teams ignores per-agent hook configuration.

| Hook | Purpose | Mechanism |
|------|---------|-----------|
| `PreToolUse` | Block destructive commands, enforce file ownership, schema migrations, external deployments | Exit code 2 = block + feedback |
| `TaskCompleted` | Reject task completion without tests/lint/evidence | Exit code 2 = reject completion |
| `TeammateIdle` | Prevent idle if acceptance criteria unmet | Exit code 2 = push feedback |
| `Stop` / `SubagentStop` | Prevent termination with critical tasks remaining | Exit code 2 = block exit |

### Permission Modes by Role

| Role | Permission Mode | Rationale |
|------|----------------|-----------|
| Team Lead | `default` | Needs user confirmation for risky operations |
| PM / QA / UX | Read-only tools + `plan` | No code modification authority |
| Builders | `acceptEdits` in isolated worktree | Auto-approve file edits within owned paths |
| All roles | Never `bypassPermissions` | Subagents inherit this mode — extremely dangerous |

Note: All teammates inherit the lead's permission mode at spawn. Per-teammate permission differentiation must be enforced via `PreToolUse` hooks (file ownership enforcement).

### SDK Configuration Note

> **Pitfall**: `.claude/settings.json` rules are NOT auto-loaded by the SDK. You must explicitly set `settingSources: ["project"]` to apply project-level permission rules and hook settings.

---

## 11. Phase-Based Activation Patterns

### Spec Phase (DISCOVER → SPEC_HARDEN)

| Status | Role | Mode |
|--------|------|------|
| Active | Lead, PM, Tech Lead | Read-only / plan |
| Optional | Pragmatic UX Reviewer, UI Designer | Consultation |
| Inactive | All builders, QA, Aesthetic UX | — |

### Build Phase (BUILD_PLAN → IMPLEMENT)

| Status | Role | Mode |
|--------|------|------|
| Active | Lead, Tech Lead, Builder(s), Validation Runtime Manager | acceptEdits (builders) |
| Optional | UI Designer | Pre-implementation guidance |
| Inactive | PM (standby), QA, UX reviewers | — |

### Validation Phase (VALIDATE → REVIEW_SYNTHESIS)

| Status | Role | Mode |
|--------|------|------|
| Active | Lead, PM, Validation Runtime Manager, QA Reviewer, Pragmatic UX Reviewer | Read-only (reviewers) |
| Optional | Aesthetic UX Reviewer | Milestone only |
| Inactive | All builders | — |

This keeps **3–5 active roles** at any given moment, aligned with official recommendations. Conditional roles (Builders, Reviewers) are spawned when entering their phase and shut down via `requestShutdown` when the phase ends.

---

## 12. Core Operating Rules

1. **Documents are truth, conversations are ephemeral.** All decisions, assumptions, and state changes must be persisted to files.
2. **One work item, one owner role.** No shared ownership.
3. **One file set, one executor at a time.** Agent teams warn: same-file edits cause overwrites.
4. **Validation execution is centralized.** Only Validation Runtime Manager runs tests/browsers.
5. **Reviewers interpret evidence; they don't create new evidence.** Prevents session proliferation.
6. **Subordinates never ask the human directly.** All user-facing queries route through Lead. (SDK constraint: `AskUserQuestion` unavailable in Task-spawned subagents.)
7. **Lead delegates before implementing.** Direct implementation is the exception, not the rule.
8. **Human gates are narrow; auto-proceed is wide.** Use the three-test criteria (irreversibility, blast radius, product meaning), not vague percentage thresholds.
9. **Human gates are non-blocking.** Park the gated item, continue all unrelated work. Full halt only when the pending decision blocks every remaining task.
10. **All agents are generalists; roles constrain focus, not capability.** Roles exist to prevent attention scatter, not to match specialization.
11. **Quality over token efficiency.** When a design choice trades quality for efficiency, choose quality.
12. **Behavior Spec is the product truth, not a traditional PRD.** Every statement must be verifiable by agent tools.

---

## 13. Constraints & Limitations

- **UX Reviewers**: Only capable of validating web-based services (via Playwright, Chrome-connected tools). Android/iOS or other platform-specific runtimes are not supported.
- **Agent Teams**: Currently experimental (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). Requires Opus 4.6+. No session resumption with in-process teammates, no nested teams.
- **Subagent nesting**: Subagents cannot spawn other subagents. Never include `Task`/`Agent` in a subagent's tools array.
- **Session limits**: One team per session, lead is fixed and cannot be changed.
- **File conflicts**: Agent teams provide no merge resolution — overlapping file edits cause overwrites. Work item decomposition MUST be file-boundary-aware.
- **Skills/hooks in teams**: Agent Teams silently ignores `skills` and `hooks` frontmatter in custom `.claude/agents/` files (Issue #30703). All role knowledge must go in prompts; all hooks must be project-level.
- **Permission inheritance**: All teammates inherit the lead's permission mode at spawn. Per-teammate differentiation requires `PreToolUse` hook enforcement.

---

## 14. TODO

- [ ] Write full role prompts for each agent (expand skeletons in Section 9 with embedded domain knowledge)
- [ ] Create Behavior Spec template file (`docs/product/behavior-spec.md`)
- [ ] Create `assumptions.md` template with Impact x Uncertainty matrix
- [ ] Create `success-metrics.md` template (separated from agent workflow)
- [ ] Implement flat Agent Teams configuration (team spawn logic, conditional role lifecycle)
- [ ] Build session crash recovery logic (read file state → spawn fresh team → resume from checkpoint)
- [ ] Implement `PreToolUse` hooks for file ownership enforcement
- [ ] Implement `TaskCompleted` and `TeammateIdle` quality gate hooks
- [ ] Design inter-agent communication format (JSON / YAML / Markdown — decide optimal format)
- [ ] Create `.claude/settings.json` with project-level permission rules and hooks
- [ ] Build loop-state management tooling (custom MCP tools for state sharing)
- [ ] Implement PM's Explore subagent pattern for codebase investigation
- [ ] Define work-items.json schema for vertical-slice scenarios
- [ ] Test with a pilot project (flat team, full architecture)
