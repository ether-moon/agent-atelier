# Agent-Atelier — System Design

**Date**: 2026-04-08
**Status**: Draft v3
**Research Foundations**: [Research Foundations](../research/foundations.md) (background reference only; `docs/design/*` is normative)

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
2. **Core roles stay active; specialist roles activate on demand.** In the full architecture, the always-on core is Orchestrator + State Manager + PM + Architect (4). All others (Builder, VRM, Reviewers, UI Designer) are conditional. Pilot implementations may temporarily collapse these responsibilities into a smaller loop until the core invariants are proven. Official guidance recommends 3–5 teammates; the extra control-plane role earns its cost by serializing shared state.
3. **Separate validation execution from validation interpretation.** One agent runs tests/browsers/screenshots; reviewers consume the same evidence. This prevents browser session collisions and duplicate test processes.
4. **Artifacts over opinions.** Every decision must land in a log file. Every validation must produce an evidence bundle. Every spec change must update the Behavior Spec.
5. **Narrow human gates, wide auto-proceed.** The team autonomously handles reversible/local choices; only irreversible or product-meaning changes reach the human.
6. **Human gates are non-blocking by default.** When a decision requires human approval, the team does NOT stop all work. It continues progressing on unrelated tasks while the gated item waits. Only truly blocking dependencies (where no other work can proceed without the answer) cause a full halt. See [Human Gate Operations](./human-gate-ops.md) for tracking details.
7. **All agents are generalists.** Roles exist to prevent attention scatter and maintain focus, not to match specialization. Every agent is the same LLM — roles constrain attention, assign accountability, and prevent scope creep.
8. **Validation uses an information barrier.** VRM and reviewers must not consume Builder summaries, diffs, or "what changed" explanations. VRM inputs are assembled from work items, specs, and verification commands only.
9. **Reviewer independence comes before debate.** Reviewers first evaluate the same evidence bundle independently; PM-led synthesis and debate happen only after the first-pass findings are recorded.
10. **Long-running loops need watchdog monitoring.** Open gates, stalled implementations, missing validation, and missing synthesis must be detected from persisted state rather than memory.
11. **Quality over blind complexity.** Choose the simplest structure that preserves quality. Token, latency, and coordination overhead must stay within explicit operating budgets.
12. **Stage the implementation.** Build the smallest loop that preserves the architecture's invariants first: executor, independent validator, persisted work-item state, and recovery. Expand role count only after this loop is stable.

### Design Tradeoff Rationale

| Concern | Decision | Rationale |
|---------|----------|-----------|
| All roles always active | Core 4 + conditional specialists | Official docs: 3–5 teammates; the extra State Manager role prevents control-plane races |
| Aesthetic UX every loop | Milestone-only activation | Prevents endless polish loops |
| Each reviewer runs own browser | Single Validation Runtime Manager | Avoids deadlocks, state corruption, duplicate processes |
| Conversation-based state | File-based state | Teammates don't inherit lead's conversation history |
| Single global phase state | Two-tier state (control plane + WI state) | Non-blocking human gates and parallel WIs need separate state representations |
| Multi-writer shared state | State Manager single writer for `.agent-atelier/**` | Deterministic recovery and race-free state commits |
| Validation informed by builder narrative | WI/spec-derived VRM prompt builder | Prevents confirmation bias in validation |
| Ad hoc reviewer discussion | Independent first pass + PM-led synthesis | Preserves reviewer independence before debate |
| No long-loop monitor | Two-lane observation + recovery (`*/2` monitor poll + `*/15` watchdog pulse) | Fast event handling plus durable mechanical recovery without relying on chat memory |
| "20% change" threshold | Irreversibility + blast radius criteria | Mechanical, unambiguous gate criteria |
| Specialization-framed roles | Focus-framed roles | All agents are generalists; roles constrain attention, not capability |
| Token efficiency as driver | Quality as driver | Quality output is the goal; efficiency is a welcome side effect |
| No explicit operating budget | Quality within cost/latency budgets | High-quality output does not justify unbounded coordination overhead |
| Long-lived Builder sessions | Ephemeral Builder sessions | Fresh context per WI over accumulated context; clean > cheap |
| Hook-based file ownership | Worktree isolation | Physical separation via git worktrees; prompt guidance sufficient |
| VRM as sole test runner | Two-tier validation | Builder self-tests for fast feedback; VRM for authoritative cross-validation |
| Merge then validate | Validate candidate, then promote to `main` | Keeps trunk green and recovery points trustworthy |
| VRM always-on | VRM conditional (on merge / VALIDATE) | Idle most of the loop; spawn on demand saves tokens |
| Orchestrator resolves merge conflicts | Architect resolves | Architect understands decomposition; Orchestrator stays focused on orchestration |
| Custom messaging layer | Agent Teams native write() | Built-in is sufficient; structured payloads via JSON in text field |
| FE/BE builder split | Full-stack Builder | Vertical-slice scenarios reduce coordination overhead and file conflicts |
| Full role graph from day one | Minimal pilot loop first | Prove state, validation, and recovery on the smallest viable topology before adding specialists |
| Implicit WI rationale | Explicit `why_now` / `non_goals` / `decision_rationale` / `relevant_constraints` | Preserve intent across session resets and handoffs |
| Alert-only watchdog | Recovery-capable watchdog | Detect stale work and perform limited safe recovery before escalating |
| Business metrics isolated from workflow | Metrics inform prioritization, synthesis, and human gates | Product direction should influence routing decisions without polluting executable acceptance checks |

---

### Pilot Implementation Direction (v0)

The **target architecture** remains the full development loop described in this document. However, implementation order matters:

1. **Start with a minimal loop**: one executor + one independent validator + persisted WI state + minimal recovery watchdog.
2. **Add orchestration structure only after evidence**: promote to PM / Architect / State Manager / specialist roles when the minimal loop proves stable on real work.
3. **Gate role expansion by operational evidence**:
   - crash recovery works without human reconstruction
   - completion requires evidence, not narrative
   - token and latency budgets remain within configured thresholds
   - added roles improve quality or throughput enough to justify coordination cost

This sequencing prevents the system from locking in a high-overhead multi-agent topology before basic execution, validation, and recovery are proven.

---

## 2. Organization Chart

```
                        ┌─────────────────────┐
                        │    Human (User)     │
                        └──────────┬──────────┘
                                   │ Level 4 only
                        ┌──────────▼──────────┐
                        │    Orchestrator     │
                        └──────┬──────┬───────┘
                               │      │
                  ┌────────────▼──┐   │   ┌──────────────▼─────────────┐
                  │ State Manager │   │   │ Architect                  │
                  │ Control Plane │   │   │ Execution Coordination      │
                  └──────────┬────┘   │   └──────────┬──────────┬──────┘
                             │        │              │          │
                     ┌───────▼─────┐  │     ┌────────▼──────┐   │
                     │ PM / Spec   │  │     │ Execution      │   │
                     │ Owner       │  │     │ Part           │   │
                     └──────┬──────┘  │     ├───────────────┤   │
                            │         │     │ • UI Designer │   │
               ┌────────────▼───────┐ │     │ • Builder [C] │   │
               │ Verification Part  │ │     │   (full-stack)│   │
               ├────────────────────┤ │     └────────────────┘   │
               │ • QA Reviewer      │ │                           │
               │ • Pragmatic UX [C] │ │                 ┌────────▼─────────┐
               │ • Aesthetic UX[C*] │ │                 │ Validation       │
               └────────────────────┘ │                 │ Runtime Mgr [C]  │
                                       │                 └──────────────────┘

[C]  = Conditional — activated on demand
[C*] = Conditional, milestone-only
```

### Role Classification

| Category | Roles | Activation |
|----------|-------|------------|
| **Always-on Core** | Orchestrator, State Manager, PM, Architect | Every loop iteration |
| **Conditional Executors** | Builder (full-stack), UI Designer, Validation Runtime Manager | When implementation/validation is needed |
| **Conditional Reviewers** | QA Reviewer, Pragmatic UX Reviewer | Most validation loops |
| **Milestone-only** | Aesthetic UX Reviewer | Release candidates, major milestones |

---

## 3. Role Definitions

### 3.1 Orchestrator

| Aspect | Detail |
|--------|--------|
| **Focus** | Control-plane decisions, role invocation, candidate promotion judgment, human gate judgment, sole user-facing communication |
| **Stay focused on** | Orchestration and decision routing. Don't get pulled into writing specs or implementing code — that's not your focus right now. |
| **Operating rule** | Delegate over direct implementation. Direct fix only when all executors are idle AND a single trivial fix remains |
| **Outputs** | State update requests, active work-items summary, risk register, next action decision |

> **Why the "no direct implementation" rule**: Official docs note that leads often skip waiting for teammates and implement directly. Anthropic explicitly recommends instructing the lead to wait.

### 3.2 State Manager / Control Plane Writer

| Aspect | Detail |
|--------|--------|
| **Focus** | Serializing all machine-readable workflow state. Your job is deterministic state commits and acknowledgements — stay focused on that. |
| **Stay focused on** | Sole writer for `.agent-atelier/**`, validation of state transition requests against current revision, monotonic revision assignment, human gate ledger maintenance, attempt journal indexing. Don't author product specs or technical design docs — that's not your focus right now. |
| **Operating rule** | Every control-plane write follows `intent → validate → commit → ack`. If a request is stale or conflicts with current state, reject it with a reason instead of guessing how to merge it. |
| **Outputs** | `loop-state.json`, `work-items.json`, `.agent-atelier/human-gates/**`, attempt journal index, state commit acknowledgements |

### 3.3 PM / Spec Owner

| Aspect | Detail |
|--------|--------|
| **Focus** | Defining behaviors and acceptance states. Your job is specifying what the system should do — stay focused on that. |
| **Stay focused on** | Behavior Spec authoring/revision, acceptance criteria maintenance, assumption log, decision log, feedback classification. Don't get pulled into implementation details — that's not your focus right now. |
| **Codebase exploration** | Explore existing code via Explore subagents to understand current policies and behaviors. Keep your own context focused on spec authoring — delegate specific questions to subagents and receive summarized answers. |
| **Feedback classification** | Every piece of implementation feedback → one of: `bug`, `spec_gap`, `ux_polish`, `product_level_change` |
| **Open Questions** | Apply 3-test gate criteria (irreversibility, blast radius, product meaning) to decide: human gate → HDR file, or team-resolvable → log in `assumptions.md` |
| **Outputs** | Behavior Spec deltas, acceptance criteria deltas, open questions, decision proposals |

### 3.4 Architect

| Aspect | Detail |
|--------|--------|
| **Focus** | Translating specs into implementable work items and coordinating builders. Your job is decomposition and technical coordination — stay focused on that. |
| **Stay focused on** | Decompose specs into vertical-slice work items, assign file ownership, invoke builders, technical risk assessment. Don't get pulled into filling spec gaps with product decisions — that's the PM's focus. |
| **Autonomy scope** | Local, reversible technical choices (see [Section 6](#6-autonomy-boundaries)) |
| **Work item pattern** | Vertical slices per scenario, not horizontal layers. Each work item = everything needed to make one Behavior pass. |
| **Outputs** | Work-item proposals for State Manager commit, dependency graph, `file-ownership.md`, technical risk notes |

### 3.5 Validation Runtime Manager (Conditional)

| Aspect | Detail |
|--------|--------|
| **Focus** | Producing authoritative evidence bundles for cross-validation. Your job is running the full validation suite and collecting evidence — stay focused on that. |
| **Stay focused on** | Execute full test suites, run Playwright scenarios, accessibility checks (axe), screenshot collection, evidence bundle assembly. Don't make product judgments or attempt code fixes — that's not your focus right now. |
| **Key principle** | Authoritative evidence production — the single point for integration tests, E2E, and accessibility checks that require environment coordination. Builders run their own unit/integration tests during IMPLEMENT; VRM produces the official cross-validation evidence during VALIDATE. |
| **Information barrier** | VRM input is generated from the work item, Behavior Spec, and verification commands only. Builder summaries, diffs, and post-hoc explanations are excluded. |
| **Activation** | Spawned by Orchestrator when a candidate integration branch is ready. Runs authoritative validation before promotion to `main`. Can run incremental candidate validation per merge or a full suite at VALIDATE. Shut down after evidence bundle is produced. |
| **Outputs** | Validation report, evidence bundle (screenshots, logs, traces), pass/fail summary |

### 3.6 Conditional Executors

#### UI Designer
- Design system management and direction
- Acts as UI architect BEFORE frontend implementation begins
- Activated when: new screens, information architecture changes, design system impact

#### Builder (Full-Stack)
- Implements vertical-slice scenarios per Architect's work items
- Handles frontend, backend, API, DB — whatever the assigned scenario requires
- Runs own unit/integration tests during implementation for fast feedback (self-test)
- Works in an isolated git worktree — no file conflict with other Builders
- Ephemeral sessions: spawn per work item → implement → atomic commit → shutdown. Fresh context per WI over accumulated context.
- Must receive UI Designer guidance before starting (when applicable)
- **Stay focused on** implementing the assigned scenario. Don't revise the spec mid-implementation — that's the PM's job.

### 3.7 Conditional Reviewers

#### QA Reviewer
- Validates implementation correctness against specs and requirements
- Detects functional defects
- Consumes evidence from Validation Runtime Manager (does NOT run own tests)
- Performs an independent first-pass review before reading any other reviewer output

#### Pragmatic UX Reviewer
- Evaluates usability, accessibility, intuitiveness from a practical standpoint
- Uses Playwright/browser tools via evidence from Validation Runtime Manager
- Participates in most validation loops
- Performs an independent first-pass review before debate or synthesis

#### Aesthetic UX Reviewer
- Evaluates visual trends, aesthetic refinement, interface sophistication
- Milestone/release candidate reviews only
- **Why milestone-only**: Always-on aesthetic review creates endless polish loops
- Performs an independent first-pass review before debate or synthesis

---

## 4. State Machine — Development Loop

```
DISCOVER ──► SPEC_DRAFT ──► SPEC_HARDEN ──► BUILD_PLAN ──► IMPLEMENT
                                 ▲                              │
                                 │                              ▼
                            AUTOFIX ◄──── REVIEW_SYNTHESIS ◄── VALIDATE
                                 │
                                 └──────────────────────────────► DONE
```

This diagram shows the **dominant control flow for an unblocked work item**, not an exclusive global phase machine. The formal **Mode Transition Protocol** (valid transition table, overlap rules, invalid transition rejection) is defined in `skills/run/SKILL.md § Mode Transition Protocol`.

### State Representation

The workflow uses a **two-tier state model**:

- `loop-state.json` stores the control plane: current operating mode, active roles, open gates, the single active candidate, the FIFO candidate queue, and the current revision.
- `work-items.json` stores WI-level lifecycle state: `pending`, `ready`, `implementing`, `candidate_queued`, `candidate_validating`, `reviewing`, `blocked_on_human_gate`, `done`.
- `HUMAN_GATE` is **not** a global phase. It is a WI-level blocked condition recorded as `blocked_by_gate` on the affected WI(s).
- `State Manager` is the sole writer for `.agent-atelier/**`. All state changes are requested asynchronously and committed synchronously via `intent → validate → commit → ack`.
- `main` promotion is serialized: exactly one candidate may be under authoritative validation at a time. Additional candidate-ready WIs wait in a FIFO queue.

### State Definitions

#### DISCOVER
- **Input**: User's service concept / requirements
- **Actors**: Orchestrator + PM + Architect (separate agents, each explores from own perspective)
- **Activity**: Gap analysis, initial requirement decomposition. PM explores user needs and behavior gaps; Architect assesses feasibility and architecture constraints; Orchestrator judges scope, priority, and human gate candidates.
- **Output**: `open-questions.md`, `assumptions.md`

#### SPEC_DRAFT
- **Actors**: PM (with Explore subagents for codebase investigation)
- **Activity**: Write Behavior Spec first draft including Goal, Current State (via subagent exploration), Behaviors with UI States tables and Verify sections, Constraints, Out of Scope
- **Output**: `behavior-spec.md` (draft)

#### SPEC_HARDEN
- **Actors**: PM + Architect + (optional) UI Designer
- **Activity**: Architect challenges PM's spec ("this Behavior is unimplementable because..."), PM revises, Architect re-confirms. Reviews implementability, requests missing UI state / API contract / error handling specs.
- **Orchestrator coordination protocol**: Orchestrator initiates PM↔Architect dialogue turn. Architect writes challenges to PM, PM revises and writes confirmation request to Architect, Architect writes completion to Orchestrator. Orchestrator manages start/end, middle turns are peer-to-peer.
- **Rules**:
  - Reversible, local gaps → auto-fill (log in `assumptions.md`)
  - Irreversible, product-meaning gaps → human gate candidate (PM applies 3-test criteria)
- **Output**: `behavior-spec.md` (hardened), `assumptions.md` (updated)

#### BUILD_PLAN
- **Actors**: Architect
- **Activity**: Create vertical-slice work items with file ownership, dependencies, definition of done. Each work item maps to one or more Behaviors.
- **Rules**:
  - Never assign overlapping file sets to multiple builders
  - Every work-item proposal must bind to the current `behavior_spec_revision` (or content hash) so State Manager can reject stale decompositions after spec changes
- **Output**: Work-item proposals for State Manager commit, `file-ownership.md`

#### IMPLEMENT
- **Actors**: Architect + Builder(s) + (optional) UI Designer
- **Activity**: Code production. Each Builder works in an isolated git worktree, implements everything needed (frontend, backend, API, DB) to make their assigned scenario pass, runs self-tests, and produces atomic commits.
- **Builder lifecycle**: Ephemeral — spawn per WI → implement → self-test → atomic commit (~100 lines) → shutdown. Fresh context per work item.
- **Rules**:
  - Each Builder works in an isolated git worktree (no file conflict by design)
  - Frontend work: UI Designer review first → Builder
  - Atomic commits as savepoints — every meaningful work unit is committed
  - Risky operations: read-only plan mode review first
  - Builder does NOT write attempt journals directly; it sends attempt journal payloads to State Manager for commit
- **Output**: Atomic git commits in worktree branches, self-test results, attempt journal payloads

#### VALIDATE
- **Actors**: Validation Runtime Manager
- **Activity**: Single authoritative execution pass on the current candidate integration branch — tests, Playwright, accessibility, screenshots
- **Rules**:
  - VRM input is assembled by a prompt builder from the work item, Behavior Spec, and verification commands only
  - Builder summaries, diffs, and "what changed" explanations are excluded from VRM input
  - Validation runs only for the `active_candidate` selected by Orchestrator and committed by State Manager
  - If other WIs become candidate-ready while validation is running, they enter `candidate_queued` and are appended to the FIFO `candidate_queue`
- **Output**: Evidence bundle at `.agent-atelier/validation/{date}-run-{n}/`, candidate validation status

#### REVIEW_SYNTHESIS
- **Actors**: PM + QA Reviewer + Pragmatic UX Reviewer + (optional) Aesthetic UX Reviewer + Orchestrator (cross-verification)
- **Activity**:
  - **Stage 1: Independent first pass**
    - Orchestrator delivers the SAME evidence bundle path to every reviewer
    - Reviewers independently interpret the evidence without reading other reviewers' output
  - **Stage 2: PM-led synthesis**
    - PM collects all first-pass findings
    - If findings conflict or need refinement, PM initiates reviewer debate on the same evidence bundle
  - PM classifies all feedback into 4 categories:
    - `bug` → AUTOFIX
    - `spec_gap` → AUTOFIX (via SPEC_HARDEN)
    - `ux_polish` → AUTOFIX
    - `product_level_change` → HUMAN_GATE
  - **Orchestrator cross-verifies PM's classification** before routing — prevents `product_level_change` being misclassified as `ux_polish` (mutual auditing principle applied to feedback classification)
  - If validation passes with no blocking findings, Orchestrator approves promotion of the candidate to `main`
- **Output**: Orchestrator-verified classified feedback report, promotion decision

#### AUTOFIX
- **Trigger**: `bug`, `spec_gap`, or `ux_polish` feedback
- **Activity**: Automatic regression to SPEC_HARDEN or IMPLEMENT
- **Failure context handoff**: Architect updates the relevant WI with failure reason and validation report path (e.g., `"previous_failure": "VAL-031: retry button not clickable"`, `"evidence": ".agent-atelier/validation/2026-03-08-run-01.md"`). New ephemeral Builder receives this context as part of the WI, preserving failure knowledge without carrying stale context.
- **Loop budget rule**: Each WI stores `attempt_count` and `last_finding_fingerprint`. If the same fingerprint repeats 3 times, the loop MUST escalate to Orchestrator for root-cause review instead of retrying blindly.
- **Key**: No human approval needed

#### HUMAN_GATE (WI Overlay, Not Global Phase)
- **Trigger**: `product_level_change` or irreversible/high-blast-radius decisions
- **Activity**: Orchestrator compiles impact report → asks user → affected WI(s) enter `blocked_on_human_gate`
- **Max deferral strategy**: Before opening a gate, execute everything possible that is not blocked by the pending decision. Gate-independent Behaviors proceed through BUILD_PLAN → IMPLEMENT → VALIDATE. The goal is to have all unblocked work completed by the time the user responds.
- **Non-blocking principle**: The gated item is parked, but the team continues working on all unrelated tasks. Only when the gated decision is a true upstream dependency for ALL remaining work does the loop fully halt. See [Human Gate Operations](./human-gate-ops.md).
- **Resume**: User approval clears `blocked_by_gate` on the affected WI(s), returns them to `ready`, and lets Orchestrator route them using the recorded `resume_target` (`SPEC_HARDEN` or `BUILD_PLAN`)

#### DONE
- **Conditions**:
  - All acceptance criteria met
  - No blocking issues
  - Validation evidence exists for the promoted candidate
  - `main` only contains candidate commits that have passed VRM validation and review synthesis
  - PM + Orchestrator confirm release candidate

---

## 5. Escalation Protocol

### 4-Level Communication Hierarchy

#### Level 1 — Bug Fast Track
```
PM/QA ──► Architect (Direct)
```
- Obvious bugs requiring code-level fix only (button not clickable, API 500)
- No Behavior Spec modification needed
- Architect dispatches to appropriate builder

#### Level 2 — Spec Clarification
```
Architect ──► PM
```
- Missing edge case handling, undefined UI states (e.g., loading state design)
- Architect does NOT guess — requests spec supplement from PM

#### Level 3 — Trade-off Escalation
```
Architect / PM ──► Orchestrator
```
- "Both implementation paths satisfy the spec, but one is cheaper and one is more maintainable"
- "This internal refactor reduces complexity but increases implementation effort"
- Orchestrator decides considering project timeline and goals
- Only allowed for reversible, internal trade-offs that preserve external contracts
- Must NOT involve public API changes, DB compatibility breaks, auth/privacy/payment/legal implications, or major dependency replacement

#### Level 4 — Human-in-the-Loop
```
Orchestrator ──► User (Human)
```
- Major Behavior Spec revision proposals
- "Redesign the entire UI concept" recommendations
- Orchestrator compiles impact analysis report → submits to user → enters **non-blocking wait**
- **Non-blocking**: The gated item is parked, but the team continues all unrelated work. Full halt only when the gated decision blocks ALL remaining tasks.
- **Critical**: Subagents cannot ask the user directly (SDK limitation: `AskUserQuestion` unavailable in Task-spawned subagents). All human-facing queries MUST route through Orchestrator.
- **Precedence rule**: If an issue matches any Human Gate predicate or any 3-test criterion scores HIGH, Level 4 overrides Level 3.

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

Human Gate predicates override lower escalation levels. There is no "Orchestrator can decide anyway" escape hatch for public contracts, major dependency replacement, or other Level 4 items.

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

`docs/product/**` is PM-owned. Other roles may propose edits, but PM is the single writer of product meaning.

Starter templates in `docs/product/*.md` are intentionally lightweight. They define the minimum required structure for v1, not a rigid form that must never grow.

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

Business metrics (conversion rate, engagement, revenue impact) go in `docs/product/success-metrics.md`. They are **not** executable Builder / VRM acceptance criteria, but they **are** valid inputs for:

- Orchestrator prioritization
- PM review synthesis
- Human-gate judgment
- deciding whether a validated implementation still points in the wrong product direction

This keeps implementation checks binary while still letting product signals influence workflow decisions.

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
├── runtime-contracts.md         # Cross-role runtime ownership and invariants
├── state-schemas.md             # Canonical machine-readable object shapes
├── agent-lifecycle.md           # Spawn / claim / heartbeat / timeout / resume
├── cli-surface.md               # `agent-atelier` command contract
├── recovery-spec.md             # Crash recovery and watchdog recovery rules
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

`docs/engineering/file-ownership.md` is Architect-owned. It is not part of the machine control plane.

### QA & Validation

```
.agent-atelier/validation/
├── {run-id}/
│   ├── manifest.json                  # Machine-readable validation manifest
│   ├── report.md                      # Human-readable validation report
│   └── evidence/                      # Screenshots, logs, traces
```

### Orchestration (Machine-Readable)

```
.agent-atelier/
├── loop-state.json              # Current control-plane state
├── work-items.json              # Task graph with ownership
├── attempts/                    # Attempt journals per WI for crash recovery
├── escalations/                 # Active escalation records
├── watchdog-jobs.json           # Watchdog checks and thresholds
└── human-gates/                 # Pending human decisions
```

`.agent-atelier/**` is State Manager-owned. No other role writes these files directly.

### Runtime Support Components

```text
plugins/agent-atelier/
├── skills/
│   ├── init/SKILL.md              # Bootstrap orchestration workspace
│   ├── status/SKILL.md            # Orchestration dashboard
│   ├── wi/SKILL.md                # Work item planning (list/show/upsert)
│   ├── execute/SKILL.md           # Execution lifecycle (claim/heartbeat/complete/requeue/attempt)
│   ├── candidate/SKILL.md         # Candidate pipeline (enqueue/activate/clear)
│   ├── validate/SKILL.md          # Validation evidence recording
│   ├── gate/SKILL.md              # Human decision gates (list/open/resolve)
│   ├── watchdog/SKILL.md          # Health check & mechanical recovery
│   └── run/SKILL.md               # Orchestration loop entry point (team spawn & lifecycle)
├── hooks/
│   ├── hooks.json                 # Hook registrations (UserPromptSubmit, PreToolUse, Stop, SubagentStop)
│   ├── on-prompt.sh               # UserPromptSubmit hook (signal collector: open gates, active_candidate, pending WAL)
│   ├── on-pre-tool-use.sh         # Destructive command blocking
│   ├── on-task-completed.sh       # Minimum evidence validation
│   └── on-stop.sh                 # Dangling obligation check
├── scripts/
│   ├── state-commit               # Atomic multi-file writer with WAL and revision checking
│   └── build-vrm-prompt           # Builds VRM evidence input from WI/spec only (information barrier)
├── schema/
│   └── vrm-evidence-input.schema.json
└── references/
    ├── paths.md                   # Canonical path reference
    ├── state-defaults.md          # Default JSON structures + operating budgets
    ├── wi-schema.md               # Work item schema & normalization rules
    ├── recovery-protocol.md       # Cold resume algorithm & test scenarios
    ├── success-metrics-routing.md # Metrics → prioritization/synthesis/gate routing
    └── prompts/                   # Production role prompts (10 roles)
        ├── orchestrator.md
        ├── state-manager.md
        ├── pm.md
        ├── architect.md
        ├── builder.md
        ├── vrm.md
        ├── qa-reviewer.md
        ├── ux-reviewer.md
        ├── ui-designer.md
        └── aesthetic-ux-reviewer.md
```

`state-commit` is the sole writer for `.agent-atelier/**`, enforcing single-writer guarantees and crash recovery. `build-vrm-prompt` enforces the validation information barrier. The `watchdog` skill performs mechanical recovery directly (not a separate script). All hooks are project-level (Agent Teams ignores per-agent hook configuration).

---

## 8. Communication Schema (JSON)

The control plane uses two persistent layers:

- `loop-state.json` = team-wide operating mode and revision
- `work-items.json` = WI-level lifecycle and blocking state

All writes to `.agent-atelier/**` are serialized through the State Manager.
Promotion policy is `single active candidate + FIFO queue`.

Section 8 is the architectural overview. Exact runtime contracts for implementation live in:

- [state-schemas.md](./state-schemas.md) for canonical object shapes
- [agent-lifecycle.md](./agent-lifecycle.md) for claim / heartbeat / timeout behavior
- [cli-surface.md](./cli-surface.md) for the command interface
- [recovery-spec.md](./recovery-spec.md) for auto-recovery and crash-resume policy

### 8.0 Loop State

```json
{
  "revision": 41,
  "mode": "VALIDATE",
  "active_spec": "docs/product/behavior-spec.md",
  "active_spec_revision": 7,
  "open_gates": ["HDR-002"],
  "active_candidate": {
    "work_item_id": "WI-014",
    "branch": "candidate/WI-014",
    "commit": "abc1234"
  },
  "candidate_queue": [
    {
      "work_item_id": "WI-021",
      "branch": "candidate/WI-021",
      "commit": "def5678"
    }
  ],
  "next_action": {
    "owner": "orchestrator",
    "type": "dispatch_vrm_evidence_run",
    "target": "WI-014"
  }
}
```

### 8.1 Work Item

Work items are vertical slices — each maps to one or more Behaviors and includes all layers (frontend, backend, API, DB) needed to make the scenario pass.

Work items must carry both **execution instructions** and **intent-preservation context**. The assignee should know not only what to build, but why this slice matters now, which constraints must remain intact, and which adjacent changes are explicitly out of scope.

```json
{
  "id": "WI-014",
  "revision": 12,
  "behavior_spec_revision": 7,
  "title": "Checkout page empty/loading/error states",
  "why_now": "Checkout validation is blocked by missing empty/loading/error states in the current candidate.",
  "non_goals": [
    "Guest checkout policy changes",
    "Checkout information architecture redesign"
  ],
  "decision_rationale": [
    "Preserve the current public checkout API contract.",
    "Fix reversible state-handling gaps before broader checkout redesign work."
  ],
  "relevant_constraints": [
    "Must not change auth requirements.",
    "Must keep the existing checkout response shape."
  ],
  "success_metric_refs": [
    "docs/product/success-metrics.md#guardrail-metrics"
  ],
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
  "status": "candidate_validating",
  "blocked_by_gate": null,
  "resume_target": null,
  "attempt_count": 2,
  "last_heartbeat_at": "2026-03-08T13:55:00Z",
  "lease_expires_at": "2026-03-08T15:25:00Z",
  "stale_requeue_count": 1,
  "last_attempt_ref": ".agent-atelier/attempts/WI-014/attempt-02.json",
  "last_finding_fingerprint": "VAL-031/retry-button-not-clickable",
  "promotion": {
    "candidate_branch": "candidate/WI-014",
    "candidate_commit": "abc1234",
    "status": "validating"
  }
}
```

`success_metric_refs` are **not** executable acceptance checks. They exist so Orchestrator and PM can use product signals during prioritization, review synthesis, and human-gate decisions.

### 8.1.1 Work Item Transition Policy (Loose v1)

The control plane should prefer rejecting only obviously invalid jumps. V1 is intentionally permissive about corrective loops as long as the request carries a reason and a valid `causation_id`.

| Current Base Status | Default Next | Allowed Corrective / Alternate Moves | Notes |
|---|---|---|---|
| `pending` | `ready` | — | Newly created or reset after crash recovery |
| `ready` | `implementing` | `pending` | `pending` allowed when dependencies or inputs are withdrawn |
| `implementing` | `candidate_queued` | `ready`, `pending` | Builder may yield back to `ready` after partial discovery or re-planning |
| `candidate_queued` | `candidate_validating` | `implementing`, `ready` | Queue exit can return to build if merge or smoke issues appear |
| `candidate_validating` | `reviewing` | `implementing`, `candidate_queued`, `ready` | On failure: `validate record` demotes WI to `ready` (work-items.json only); Orchestrator then calls `candidate clear --reason demoted` to release the loop-state slot (idempotent — skips WI write if already demoted) |
| `reviewing` | `done` | `implementing`, `ready` | Review findings may reopen implementation via `execute requeue` (supports `reviewing` status, clears promotion metadata). Findings are persisted to `.agent-atelier/reviews/<WI-ID>/findings.json` for cold resume. |
| `done` | — | — | V1 treats `done` as terminal; reopen as a new WI unless there is a strong reason to reuse the id |

`blocked_on_human_gate` is an overlay, not a separate base lane. It may be applied to any non-`done` WI and cleared back to the recorded `resume_target`.

### 8.2 Escalation

```json
{
  "id": "ESC-007",
  "raised_by": "architect",
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
    ".agent-atelier/validation/2026-03-08-run-01.md#finding-4",
    ".agent-atelier/validation/2026-03-08-run-01-evidence/checkout-error.png"
  ],
  "summary": "Retry button is below the fold on smaller screens.",
  "recommendation": "Move retry action above supporting copy.",
  "requires_human": false
}
```

### 8.4 Human Decision Request

This is the canonical HDR schema. Operational docs reference this section instead of redefining it.

```json
{
  "id": "HDR-002",
  "created_at": "2026-03-08T14:30:00Z",
  "state_revision": 41,
  "triggered_by": "pm",
  "state": "open",
  "question": "Should checkout allow guest purchases?",
  "why_now": "Current flow blocks completion for non-signed-in users.",
  "context": "docs/product/behavior-spec.md#B9",
  "gate_criteria": {
    "irreversibility": "medium",
    "blast_radius": "high",
    "product_meaning_change": true
  },
  "options": [
    {
      "id": "A",
      "label": "Require sign-in before checkout",
      "tradeoffs": ["Simple policy", "Higher completion friction"],
      "estimated_effort": "small"
    },
    {
      "id": "B",
      "label": "Allow guest checkout",
      "tradeoffs": ["Lower friction", "Requires guest identity handling"],
      "estimated_effort": "medium"
    },
    {
      "id": "C",
      "label": "Defer checkout and collect email only",
      "tradeoffs": ["Keeps funnel moving", "Adds later conversion step"],
      "estimated_effort": "medium"
    }
  ],
  "recommended_option": "B",
  "blocking": false,
  "blocked_work_items": ["WI-022"],
  "unblocked_work_items": ["WI-011", "WI-019", "WI-005"],
  "resume_target": "BUILD_PLAN",
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

### 8.5 State Update Request

```json
{
  "id": "SUR-104",
  "requested_by": "architect",
  "based_on_revision": 41,
  "target": "work-items.json",
  "operation": "transition_work_item",
  "payload": {
    "work_item_id": "WI-014",
    "behavior_spec_revision": 7,
    "from_status": "implementing",
    "to_status": "candidate_validating",
    "candidate_branch": "candidate/WI-014"
  },
  "causation_id": "MSG-883"
}
```

### 8.5.1 Agent Teams Message Envelope (Loose v1)

All `write()` traffic SHOULD use one lightweight envelope. V1 favors a small stable contract over a fully normalized bus.

- Required: `type`, `message_id`, `sent_by`, `sent_to`, `body`
- Recommended: `schema_version`, `sent_at`, `causation_id`, `based_on_revision`
- Optional fields may be added freely; unknown fields are ignored
- If the real payload already exists on disk, the message may carry references instead of duplicating the whole object

```json
{
  "type": "state_update_request",
  "schema_version": 1,
  "message_id": "MSG-883",
  "sent_at": "2026-04-08T14:12:00Z",
  "sent_by": "architect",
  "sent_to": "state_manager",
  "causation_id": "WI-014",
  "based_on_revision": 41,
  "body": {
    "ref": "SUR-104"
  }
}
```

Preferred v1 message types:

- `state_update_request`
- `state_update_ack`
- `state_update_reject`
- `review_submission`
- `watchdog_alert`
- `human_gate_notification`

### 8.5.2 State Manager Interface (Loose v1)

V1 uses the built-in `write()` channel plus persisted files. A custom MCP layer is optional hardening and is NOT required to start implementation.

- Caller sends `state_update_request`
- State Manager validates against current revision and current spec binding
- State Manager commits file changes in `.agent-atelier/**`
- State Manager replies with either `state_update_ack` or `state_update_reject`
- Other roles treat the acked revision as the only committed truth

State Manager should reject only:

- stale `based_on_revision`
- stale `behavior_spec_revision`
- impossible status jumps
- missing required references for destructive or high-impact transitions

Everything else should default to accept-and-ack rather than over-policing the loop.

### 8.6 Attempt Journal

```json
{
  "id": "ATT-WI-014-02",
  "work_item_id": "WI-014",
  "attempt": 2,
  "hypothesis": "Retry button is disabled by stale error-boundary state.",
  "repro_steps": [
    "Open checkout page with forced API failure",
    "Click retry after error banner appears"
  ],
  "commands_run": [
    "pnpm test checkout-error-state",
    "pnpm test:e2e checkout-retry"
  ],
  "failing_checks": [
    "e2e: checkout page loads and transitions through states"
  ],
  "touched_paths": [
    "apps/web/src/pages/checkout/",
    "apps/web/src/components/checkout/ErrorState.tsx"
  ],
  "result": "failed",
  "finding_fingerprint": "VAL-031/retry-button-not-clickable"
}
```

### 8.7 VRM Evidence Input

```json
{
  "work_item_id": "WI-014",
  "behavior_spec_revision": 7,
  "target_branch": "candidate/WI-014",
  "acceptance_criteria_refs": [
    "docs/product/behavior-spec.md#B3",
    "docs/product/behavior-spec.md#B4"
  ],
  "files_expected": [
    "apps/web/src/pages/checkout/",
    "apps/api/src/routes/checkout/"
  ],
  "verification_commands": [
    "pnpm test checkout",
    "pnpm test:e2e checkout",
    "pnpm lint"
  ],
  "forbidden_context": [
    "builder_summary",
    "builder_diff",
    "builder_log",
    "architect_interpretation"
  ]
}
```

### 8.8 Watchdog Alert

```json
{
  "id": "WDA-004",
  "detected_at": "2026-04-08T14:10:00Z",
  "type": "validation_missing_after_candidate_merge",
  "severity": "medium",
  "target": "WI-021",
  "summary": "Candidate branch exists but no VRM evidence run has started within threshold.",
  "evidence_refs": [
    ".agent-atelier/loop-state.json",
    ".agent-atelier/work-items.json#WI-021"
  ],
  "recovery_action": {
    "type": "demote_candidate_to_queue",
    "performed": true,
    "details": "Removed WI-021 from active_candidate and re-queued it for the next validation slot."
  },
  "notify_role": "orchestrator"
}
```

---

## 9. Role Prompt Skeletons

### Design Principle

Prompts use **focus framing**, not specialization framing. Every agent is a generalist LLM — roles constrain attention and prevent scope creep. Prompts define: **focus / guardrails / inputs / outputs**. All role-specific domain knowledge is embedded directly in prompts (Agent Teams silently ignores `skills` and `hooks` frontmatter).

**Loop Guardrail (all roles):** Every role prompt includes a retry safety mechanism. Before each retry attempt, the agent must answer: "What specifically failed? What concrete change will fix it? Am I repeating the same approach?" If the same approach has been tried twice, escalate to the next level instead of retrying.

### Prompt Source Policy (Loose v1)

For the pilot implementation, Section 9 is the canonical prompt source. Dedicated prompt files are optional hardening, not a prerequisite.

- Keep one stable base prompt per role in-repo
- Inject task-specific context at runtime rather than rebuilding the whole prompt
- Prefer additive prompt revisions over clever dynamic composition
- Split prompts into standalone files only after the pilot proves the role set is stable

### Orchestrator

```
Your job is driving the product development loop to satisfy all acceptance
criteria autonomously. Stay focused on orchestration and decision routing.

FOCUS:
- Decide current control-plane mode and role activation
- Choose which roles to invoke and when
- Open human gates when criteria are met
- Judge when a validated candidate is ready for promotion to main
- React to watchdog alerts about stalled or missing orchestration handoffs
- You are the sole channel to the human

GUARDRAILS:
- Don't get pulled into writing specs — that's the PM's focus right now
- Don't get pulled into implementing code — that's the Builder's focus
- Don't directly edit `.agent-atelier/**` — send state update requests to the State Manager
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

OUTPUTS: state update requests, work-items summary, risk register, next action.
```

### State Manager / Control Plane Writer

```
Your job is serializing machine-readable workflow state. Stay focused on
deterministic state commits and acknowledgements.

FOCUS:
- Be the sole writer for `.agent-atelier/**`
- Validate state update requests against the latest committed revision
- Validate that incoming work-item proposals still match the latest `behavior_spec_revision`
- Enforce `intent -> validate -> commit -> ack`
- Keep `HUMAN_GATE` as a WI-level blocked condition, not a global phase
- Maintain exactly one `active_candidate` plus a FIFO `candidate_queue`
- Maintain attempt journals and finding fingerprints for crash recovery
- Commit watchdog alerts and watchdog job state

INPUT:
- State update requests from Orchestrator, PM, Architect, VRM

GUARDRAILS:
- Don't author product specs or technical design docs
- Don't interpret product meaning or UX quality
- Reject stale or conflicting writes instead of guessing how to merge them
- Reject stale work-item proposals when the referenced Behavior Spec revision is outdated

OUTPUTS: loop-state.json, work-items.json, human-gate ledgers, attempt
journal index, commit acknowledgements or rejections.
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
- Don't edit `.agent-atelier/**` directly — request machine-state changes
  through the State Manager
- Don't run tests — that's the VRM's focus

ESCALATION: If a spec gap changes product meaning, propose a human gate to Orchestrator.

OUTPUTS: Behavior Spec deltas, acceptance criteria deltas, open questions,
decision proposals.
```

### Architect

```
Your job is translating specs into implementable work items and coordinating
builders. Stay focused on decomposition and technical coordination.

FOCUS:
- Decompose Behavior Spec into vertical-slice work items with file ownership
- Invoke builders and assign scenarios
- Make local, reversible technical decisions autonomously
- Request UI Designer guidance before frontend-heavy scenarios
- Re-issue work-item proposals whenever the bound Behavior Spec revision changes

WORK ITEM PATTERN:
Each work item = everything needed to make one Behavior pass. Vertical slices,
not horizontal layers. One builder owns all files for their scenario.

GUARDRAILS:
- Don't get pulled into filling spec gaps with product decisions — if the
  spec is silent, ask PM for clarification
- Don't assign overlapping file sets to multiple builders simultaneously
- Don't edit `work-items.json` directly — send accepted WI transitions to
  the State Manager
- Don't proceed with breaking changes without escalation

OUTPUTS: work-item proposals for State Manager commit, dependency graph,
file-ownership.md, technical risks.
```

### Validation Runtime Manager

```
Your job is executing all validation tooling and producing reusable evidence
bundles. Stay focused on test execution and evidence collection.

FOCUS:
- Run test suites, Playwright scenarios, accessibility checks, screenshot capture
- Produce evidence bundles at standard paths
- Validate candidate branches before promotion to `main`
- Consume candidates strictly from the active candidate slot selected by State Manager
- Accept input only from the VRM Evidence Prompt Builder generated from WI/spec context

GUARDRAILS:
- Don't make product judgments — that's the PM's and reviewers' focus
- Don't modify specs or fix code — report what you find, others will act on it
- Don't read Builder summaries, diffs, logs, or "what changed" explanations

LOOP GUARDRAIL:
If a test/tool fails repeatedly: "Is this an environment issue or a code
issue?" Environment issues → report to Orchestrator and stop. Code issues → produce
evidence and let reviewers handle it. Don't retry the same failing test
more than twice.

OUTPUTS: Validation report, evidence bundle, pass/fail summary at
.agent-atelier/validation/{date}-run-{n}/, candidate validation status.
```

### Builder (Full-Stack)

```
Your job is implementing the assigned scenario end-to-end. Stay focused on
making the Verify checks pass.

FOCUS:
- Implement everything needed (frontend, backend, API, DB) for your
  assigned Behavior(s)
- Run your own unit/integration tests as you go (self-test for fast feedback)
- The Verify section in the Behavior Spec IS your test suite — make it pass
- Produce atomic commits (~100 lines) as savepoints
- Emit failed-attempt payloads with hypotheses, repro steps, and commands for State Manager commit

ENVIRONMENT:
- You work in an isolated git worktree — no file conflicts with others
- Your session is ephemeral: implement this WI → self-test → commit → done

GUARDRAILS:
- Don't revise the spec mid-implementation — that's the PM's job. If the
  spec is unclear, ask Architect for clarification
- Stay within your assigned scope — worktree isolation keeps you safe,
  but your changes should only address your assigned Behaviors
- Don't start frontend work without UI Designer guidance (when applicable)
- Don't run Playwright/E2E/accessibility checks — that's VRM's cross-validation

LOOP GUARDRAIL:
Before each retry: "What failed? What specific change will fix it? Am I
repeating the same approach?" If same approach tried twice → escalate to
Architect instead of retrying. Max 8 implementation iterations per WI.

OUTPUTS: Atomic git commits in worktree branch, self-test results, attempt
journal payloads.
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
- Don't read Builder summaries, diffs, or implementation explanations
- Submit your independent first-pass findings before reading other reviewers'
  output
- Only participate in debate after PM explicitly initiates synthesis
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
│  │  Orchestrator                                 │  │
│  │    ├── State Manager (always-on)             │  │
│  │    ├── PM (teammate — always-on)             │  │
│  │    │     └── Explore subagents (codebase      │  │
│  │    │         investigation, not team members)  │  │
│  │    ├── Architect (teammate — always-on)       │  │
│  │    ├── Builder 1..N (spawned per WI)          │  │
│  │    ├── VRM (spawned on candidate / VALIDATE)  │  │
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
| **Control-plane consistency** | Dedicated State Manager | Serializes orchestration writes and removes multi-writer races from file-based state |
| **Codebase exploration** | Subagents (PM's Explore agents only) | PM delegates specific questions to keep own context focused on spec authoring. Not team members. |
| **Role knowledge** | Embedded in prompts | Agent Teams silently ignores `skills` and `hooks` frontmatter (Issue #30703). All role-specific knowledge must go in prompts. |

### Mutual Auditing in Practice

- **SPEC_HARDEN**: Architect challenges PM's spec ("this Behavior is unimplementable because...") → PM revises → Architect re-confirms
- **IMPLEMENT**: Builder asks Architect for clarification → Architect consults PM → answer flows back
- **REVIEW_SYNTHESIS**: QA and UX Reviewers debate findings from same evidence → PM arbitrates → **Orchestrator cross-verifies PM's classification before routing**

### Communication via Agent Teams write()

All inter-agent communication uses Agent Teams' native `write()` API. Messages carry structured JSON payloads matching the Communication Schema (§8) as the `text` field. No custom messaging layer — the built-in mailbox is sufficient.

Orchestrator coordinates dialogue turns where synchronization matters (e.g., SPEC_HARDEN PM↔Architect exchanges) by initiating and concluding the conversation via `write()`. Middle turns are peer-to-peer.

All changes to `.agent-atelier/**` go through a request/ack pattern with the State Manager. Other roles never assume a state transition succeeded until the State Manager replies with the committed revision.

Candidate promotion is also serialized through this channel. When multiple WIs reach `candidate_validating`, State Manager maintains one `active_candidate` and a FIFO `candidate_queue`; VRM validates only the active candidate.

V1 transport decision: use `write()` plus persisted JSON artifacts first. Do not block initial implementation on custom MCP tooling unless the pilot shows the message volume is unmanageable.

### Validation Information Barrier

- VRM input is generated by `build-vrm-prompt` from the work item, Behavior Spec, and verification commands only
- Builder summaries, diffs, logs, and post-hoc explanations are excluded from VRM and reviewer input
- VRM produces raw evidence only; reviewers interpret evidence; PM classifies findings; Orchestrator cross-verifies routing

### Reviewer Independence

- Stage 1: Orchestrator sends the same evidence bundle path to each reviewer and reviewers submit independent first-pass findings
- Stage 2: PM synthesizes findings and may initiate reviewer debate only after the first-pass submissions exist
- Reviewer disagreement is resolved on shared evidence, not on implementation narrative

### Watchdog

- The `watchdog` skill reads persisted orchestration state, performs limited safe recovery, and emits alerts for anything requiring judgment; it never edits product code or product specs
- In the running system, `watchdog tick` is only the mechanical half of recovery. The Orchestrator follows it with teammate respawn, reachability checks, and work re-dispatch.
- Minimum checks:
  - open human gate exceeds threshold
  - `implementing` WI shows no artifact updates within threshold
  - candidate merge exists but VRM evidence run has not started
  - evidence exists but REVIEW_SYNTHESIS has not run
- Recovery scope:
  - expire stale WI leases and return the WI to `ready`
  - auto-requeue stalled implementation work
  - demote stale `active_candidate` entries back to `candidate_queue`
  - reject completion records that lack required evidence references
  - escalate repeated fingerprints or repeated watchdog interventions to Orchestrator
- Reachability of a still-valid `implementing` owner is not decided by the watchdog. The Orchestrator may still reclaim that WI immediately during a recovery sweep if the recorded owner session no longer exists.
- Watchdog alerts and recovery records route to Orchestrator through State Manager commits

### Watchdog Default Thresholds (Loose v1)

These defaults are intentionally forgiving. They should restore obviously stale flow without acting like a strict scheduler.

| Condition | Default Threshold | Default Action |
|---|---|---|
| Open human gate with no update | 24 hours | Warn Orchestrator |
| `implementing` WI with no new attempt journal, commit, or state ack | 90 minutes | Expire lease, move WI to `ready`, increment `stale_requeue_count`, warn Orchestrator |
| `active_candidate` with no VRM run started | 30 minutes | Demote candidate to `candidate_queue`, clear `active_candidate`, warn Orchestrator |
| Evidence bundle exists with no first-pass review or synthesis activity | 30 minutes | Re-dispatch synthesis request, warn Orchestrator |
| Same watchdog alert repeats twice | Next check cycle | Raise severity and require Orchestrator root-cause review |

Watchdog recovery is intentionally narrow: it may auto-transition orchestration state when the recovery is mechanical and reversible, but it must not rewrite specs, code, or human decisions. The broader recovery contract is two-step: mechanical watchdog tick first, then an Orchestrator resume sweep.

### Builder Isolation via Git Worktrees

Each Builder works in an independent git worktree rather than sharing the main working directory:

- **Spawn**: `git worktree add` creates an isolated copy for each Builder
- **Implement**: Builder works freely — no file conflict by design
- **Commit**: Atomic commits (~100 lines) in the worktree branch
- **Candidate merge**: Orchestrator dynamically decides candidate merge timing based on WI completion and dependency order. Orchestrator triggers merge, delegates conflict resolution to Architect, and State Manager records the result as either `active_candidate` or an entry in the FIFO `candidate_queue`.
- **Conflict resolution**: Architect handles merge conflicts in a dedicated integration worktree (not directly on `main`). Architect merges Builder branch into a candidate branch → resolves conflicts → runs smoke test. For trivial conflicts, Architect resolves directly. For complex conflicts, Architect consults relevant Builder(s).
- **Authoritative validation before promotion**: Orchestrator spawns VRM on the candidate branch. Only after VRM evidence passes REVIEW_SYNTHESIS does Orchestrator promote the candidate to `main`.
- **Failure containment**: If candidate validation fails, AUTOFIX resumes from the candidate branch and `main` remains unchanged.
- **Cleanup**: Worktree removed after successful merge

File ownership enforcement via `PreToolUse` hooks is unnecessary — worktree isolation provides physical separation. Prompt-level guidance ("implement only within your assigned scope") is sufficient.

### Session Crash Recovery

Agent Teams cannot restore teammates on session resume. Recovery relies on **commit-as-savepoint + attempt journal**:

1. All state is file-based (`loop-state.json`, `work-items.json`, Behavior Spec, attempt journals)
2. Builders produce atomic commits — every meaningful work unit is committed
3. Each failed or interrupted WI attempt records hypothesis, repro steps, commands run, touched paths, and failing checks in an attempt journal committed by State Manager
4. Uncommitted code in worktrees is discardable because operational knowledge survives in the attempt journal
5. New session: read `loop-state.json`, `work-items.json`, open HDRs, attempt journals, and `git log` → identify last committed checkpoint → start `/agent-atelier:run` → recreate fresh monitors and both orchestration cron jobs → run one startup resume sweep that immediately requeues stranded `implementing` WIs from the crashed runtime and resumes validation/review from disk → resume

Git workflow principles: trunk-based development, atomic commits (~100 lines), commit-as-savepoint pattern.

### Hooks (Project-Level)

All hooks must be defined at the project level since Agent Teams ignores per-agent hook configuration.

| Hook | Purpose | Mechanism | Platform |
|------|---------|-----------|----------|
| `UserPromptSubmit` | Inject orchestration context before each prompt | Stdout = prepended context | Claude Code CLI |
| `PreToolUse` | Block destructive commands, schema migrations, external deployments | Exit code 2 = block + feedback | Claude Code CLI |
| `Stop` / `SubagentStop` | Prevent termination with critical tasks remaining | Exit code 2 = block exit | Claude Code CLI |
| `TaskCompleted` | Reject task completion without tests/lint/evidence | Exit code 2 = reject completion | Agent SDK only — not available in Claude Code CLI |
| `TeammateIdle` | Prevent idle if acceptance criteria unmet | Exit code 2 = push feedback | Agent SDK only — not available in Claude Code CLI |

> **Platform note**: Claude Code CLI supports `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SubagentStop`. `TaskCompleted` and `TeammateIdle` are Agent SDK (Teams API) events. The implementation file `on-task-completed.sh` exists for forward-compatibility but cannot be registered in the current plugin `hooks.json`. When the runtime migrates to Agent SDK, these hooks can be activated.

Note: File ownership enforcement is NOT done via hooks — git worktree isolation provides physical separation. Prompt-level guidance is sufficient.

### Hook Defaults (Loose v1)

- `PreToolUse` blocks only clearly destructive or irreversible operations
- `TaskCompleted` (Agent SDK) checks for minimum role artifacts, not perfection
- `TeammateIdle` (Agent SDK) should warn first and block only on repeated idle-with-work conditions
- `Stop` / `SubagentStop` should block only when the role would leave an owned obligation dangling

### Permission Modes by Role

| Role | Permission Mode | Rationale |
|------|----------------|-----------|
| Orchestrator | `default` | Needs user confirmation for risky operations |
| State Manager | `acceptEdits` | Sole writer for `.agent-atelier/**` |
| Architect | `acceptEdits` | Writes `file-ownership.md`, resolves merge conflicts in integration worktree |
| Validation Runtime Manager | `acceptEdits` | Writes evidence bundles and candidate validation status |
| PM / QA / UX | Read-only tools + `plan` | No code modification authority |
| Builders | `acceptEdits` in isolated worktree | Auto-approve file edits within owned paths |
| All roles | Never `bypassPermissions` | Subagents inherit this mode — extremely dangerous |

Note: All teammates inherit the lead's permission mode at spawn. Per-teammate permission differentiation is enforced via `PreToolUse` hooks for destructive operations. File ownership is handled by git worktree isolation, not hooks.

### SDK Configuration Note

> **Claude Code CLI**: `.claude/settings.json` is automatically loaded as project settings — no additional configuration needed. Plugin hooks are registered via the plugin's `hooks.json`.
>
> **Agent SDK (future)**: When migrating to the programmatic Agent SDK, you must explicitly set `settingSources: ["project"]` in the `Session` constructor to load project-level permission rules and hook settings. This does not apply to the current Claude Code CLI deployment.

### Operating Budgets (Pilot Requirement)

The pilot must define explicit operating budgets before role expansion:

- max token spend per completed WI
- max wall-clock time per completed WI
- max number of cross-role handoffs per WI
- max watchdog interventions per WI before forced review

If a proposed role or communication pattern violates these budgets without clear quality gain, it should not be added yet.

---

## 11. Phase-Based Activation Patterns

### Spec Phase (DISCOVER → SPEC_HARDEN)

| Status | Role | Mode |
|--------|------|------|
| Active | Orchestrator (`default`), State Manager (`acceptEdits`), PM (`plan`), Architect (`plan`) | Mixed by role |
| Optional | Pragmatic UX Reviewer, UI Designer | Consultation |
| Inactive | All builders, QA, Aesthetic UX | — |

### Build Phase (BUILD_PLAN → IMPLEMENT)

| Status | Role | Mode |
|--------|------|------|
| Active | Orchestrator (`default`), State Manager (`acceptEdits`), Architect (`acceptEdits`), Builder(s) (`acceptEdits` in worktrees) | Mixed by role |
| Optional | UI Designer | Pre-implementation guidance |
| On candidate | VRM | Incremental validation per candidate merge |
| Inactive | PM (standby), QA, UX reviewers | — |

### Validation Phase (VALIDATE → REVIEW_SYNTHESIS)

| Status | Role | Mode |
|--------|------|------|
| Active | Orchestrator (`default`), State Manager (`acceptEdits`), PM (`plan`), VRM (`acceptEdits` for evidence output), QA Reviewer (`plan`), Pragmatic UX Reviewer (`plan`) | Mixed by role |
| Optional | Aesthetic UX Reviewer | Milestone only |
| Inactive | All builders | — |

In the full architecture, this keeps the always-on core at **4 roles** and adds specialists only when the current control-plane mode requires them. Conditional roles (Builders, Reviewers) are spawned when entering their phase and shut down via `requestShutdown` when the phase ends. Pilot implementations may collapse these roles into the minimal executor + validator loop described earlier.

---

## 12. Core Operating Rules

1. **Documents are truth, conversations are ephemeral.** All decisions, assumptions, and state changes must be persisted to files.
2. **Machine-readable orchestration state has a single writer.** State Manager is the only role allowed to write `.agent-atelier/**`.
3. **Meaning documents keep domain ownership.** PM owns `docs/product/**`; Architect owns `docs/engineering/file-ownership.md`.
4. **One work item, one owner role.** No shared ownership.
5. **Builders work in isolated git worktrees.** No shared working directory — physical separation eliminates file conflicts. Prompt-level guidance, not hook enforcement.
6. **Authoritative validation happens before `main` promotion.** Candidate branches are validated and reviewed before trunk advancement.
7. **Two-tier validation: self-test + cross-validation.** Builders run own unit/integration tests during IMPLEMENT (fast feedback). VRM produces authoritative evidence bundles during VALIDATE (cross-validation).
8. **Validation honors an information barrier.** VRM and reviewers never receive Builder summaries, diffs, or implementation explanations.
9. **Reviewers interpret evidence; they don't create new evidence.** Prevents session proliferation.
10. **Reviewer synthesis is two-stage.** Independent first-pass findings precede PM-led debate and classification.
11. **Subordinates never ask the human directly.** All user-facing queries route through Orchestrator. (SDK constraint: `AskUserQuestion` unavailable in Task-spawned subagents.)
12. **Orchestrator delegates before implementing.** Direct implementation is the exception, not the rule.
13. **Orchestrator cross-verifies PM's feedback classification.** Mutual auditing applies to REVIEW_SYNTHESIS — prevents misclassification of `product_level_change` as `ux_polish`.
14. **Human gates are narrow; auto-proceed is wide.** Use the three-test criteria (irreversibility, blast radius, product meaning), not vague percentage thresholds.
15. **Human gates are WI-level blocks, not a global halt by default.** Park the gated WI, continue all unblocked work through full cycles. Full halt only when the pending decision blocks every remaining task.
16. **Watchdogs recover only mechanically reversible orchestration failures.** They may expire leases, requeue stale work, and demote stale candidates, but they must not modify product code, specs, or human decisions.
17. **All agents are generalists; roles constrain focus, not capability.** Roles exist to prevent attention scatter, not to match specialization.
18. **Fresh context over accumulated context.** Ephemeral Builder sessions (spawn → implement → commit → shutdown) per work item. Clean context is more valuable than token savings.
19. **Atomic commits plus attempt journals are savepoints.** Crash recovery uses both committed code and persisted failure context.
20. **Behavior Spec is the product truth, not a traditional PRD.** Every statement must be verifiable by agent tools.
21. **Role expansion is evidence-gated.** The system starts from the minimal stable loop and adds roles only when measured quality or throughput gains justify the coordination cost.
22. **Product signals steer workflow, not Builder Verify checks.** Success metrics may influence prioritization and synthesis, but executable acceptance remains binary and tool-verifiable.

---

## 13. Constraints & Limitations

- **UX Reviewers**: Only capable of validating web-based services (via Playwright, Chrome-connected tools). Android/iOS or other platform-specific runtimes are not supported.
- **Agent Teams**: Currently experimental (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). Requires Opus 4.6+. No session resumption with in-process teammates, no nested teams.
- **Subagent nesting**: Subagents cannot spawn other subagents. Never include `Task`/`Agent` in a subagent's tools array.
- **Session limits**: One team per session, lead is fixed and cannot be changed.
- **Worktree merge conflicts**: Git worktrees eliminate concurrent edit conflicts, but sequential merge can still produce conflicts if two Builders touch shared interfaces. Architect resolves in integration worktree; work item decomposition should minimize overlap.
- **Skills/hooks in teams**: Agent Teams silently ignores `skills` and `hooks` frontmatter in custom `.claude/agents/` files (Issue #30703). All role knowledge must go in prompts; all hooks must be project-level.
- **Permission inheritance**: All teammates inherit the lead's permission mode at spawn. Per-teammate differentiation requires `PreToolUse` hooks for destructive operations (not file ownership — handled by worktrees).
- **Serialized state writes**: The State Manager reduces races, but it also introduces a control-plane bottleneck; all orchestration writes must queue through one role.
- **Coordination cost**: Multi-role `write()` traffic and serialized state commits can consume substantial tokens and latency. The architecture must prove that each added role earns its coordination cost under the pilot operating budgets.

---

## 14. TODO

### Priority 0 — Minimal Loop First ✓

- [x] Implement the v0 loop: single executor + independent validator + persisted work-item state → `execute`, `validate`, `candidate`, `wi` skills + `state-commit`
- [x] Implement minimal State Manager flow for WI persistence and evidence-required completion → `execute complete` with evidence verification
- [x] Add WI intent-preservation fields: `why_now`, `non_goals`, `decision_rationale`, `relevant_constraints`, `success_metric_refs` → `wi-schema.md`
- [x] Implement narrow watchdog recovery: lease expiry, auto-requeue, stale candidate demotion, repeated-failure escalation → `watchdog` skill steps 2-5
- [x] Define pilot operating budgets for token spend, latency, handoff count, and watchdog interventions → `watchdog-jobs.json` budgets + watchdog step 6 + WI `first_claimed_at`/`handoff_count`

### Priority 1 — Validation and Recovery Hardening ✓

- [x] Build session crash recovery logic (commit-as-savepoint + attempt journals + loop-state + git log → resume) → `references/recovery-protocol.md` + WAL recovery in `state-commit`
- [x] Implement `build-vrm-prompt` and `vrm-evidence-input.schema.json` → `scripts/build-vrm-prompt` + `schema/vrm-evidence-input.schema.json`
- [x] Implement `PreToolUse` hooks for destructive command blocking → `hooks/on-pre-tool-use.sh`
- [x] Implement quality gate hooks → `hooks/on-task-completed.sh` (forward-compatible; `TaskCompleted`/`TeammateIdle` are Agent SDK events, not registrable in Claude Code CLI — activate on SDK migration)
- [x] Create `.claude/settings.json` with project-level permission rules → `.claude/settings.json`; plugin hooks registered in `hooks.json`
- [x] Connect `success-metrics.md` to prioritization, review synthesis, and human-gate routing without adding metrics to Builder Verify checks → `references/success-metrics-routing.md`

### Priority 2 — Full Role Graph Expansion ✓

- [x] Write full role prompts for each agent (expand skeletons in Section 9 with embedded domain knowledge) → `references/prompts/` (10 files)
- [x] Implement flat Agent Teams configuration (team spawn logic, conditional role lifecycle) → `skills/run/SKILL.md` (TeamCreate → phase-based activation → requestShutdown → TeamDelete)
- [x] Implement PM's Explore subagent pattern for codebase investigation → embedded in `references/prompts/pm.md`
- [x] Expand Section 9 prompts from pilot-grade base prompts to production-grade prompt files if the role set stabilizes → `references/prompts/` are the production prompts
- [ ] Optionally build custom MCP tooling for State Manager after pilot if `write()`-based coordination proves too noisy — **deferred: pilot evidence required**
- [ ] Test with a pilot project and add roles only when they beat the minimal loop on quality or throughput — **operational: requires real project**
