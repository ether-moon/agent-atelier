# Success Metrics Routing

How `docs/product/success-metrics.md` connects to the orchestration workflow without polluting executable acceptance checks.

## Core Principle

**Metrics inform; they don't execute.** Business metrics (conversion rate, engagement, revenue impact) are valid inputs for routing decisions but are NEVER added to Builder `verify` checks or VRM acceptance criteria. Executable acceptance remains binary and tool-verifiable.

## Where Metrics Flow

### 1. Orchestrator Prioritization

When selecting the next WI to dispatch from `ready` pool:
- Read `success_metric_refs` from each candidate WI
- Cross-reference with `docs/product/success-metrics.md` to assess business impact
- Higher-impact WIs get priority in dispatch order
- This is a soft signal — dependency order and blocking gates take precedence

### 2. PM Review Synthesis

During REVIEW_SYNTHESIS phase:
- PM reads reviewer findings + relevant success metrics
- Findings affecting primary metrics (e.g., checkout conversion) receive higher severity
- Findings affecting guardrail metrics (e.g., page load time regression) trigger immediate attention
- PM classifies findings: `bug` | `spec_gap` | `ux_polish` | `product_level_change`
- Metric context helps distinguish `ux_polish` (low metric impact) from `product_level_change` (high metric impact)

### 3. Human Gate Routing

When the 3-test gate criteria are applied:
- **Product Meaning** test considers: does this change affect a primary success metric?
- If a decision could shift a primary metric by a significant margin → product meaning is HIGH → gate warranted
- Guardrail metric violations (performance regression, error rate spike) inform blast radius assessment

### 4. Watchdog Budget Checks

Operating budgets in `watchdog-jobs.json` are informed by metric priorities:
- WIs linked to primary metrics may justify higher `max_wall_clock_minutes_per_wi`
- This is configured by the PM/Orchestrator at WI creation time, not auto-derived

## What Metrics Do NOT Do

- Metrics do NOT become `verify` checks on work items
- Metrics do NOT gate `execute complete` (evidence is binary pass/fail from VRM)
- Metrics do NOT override the information barrier (VRM never sees metric context)
- Metrics do NOT auto-prioritize — the Orchestrator applies judgment with metric context as one input
- Metrics do NOT create human gates by themselves — only the 3-test criteria trigger gates
