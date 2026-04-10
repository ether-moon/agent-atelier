# Agent Atelier

Autonomous product development loop for Claude Code. An AI agent team that cycles through spec drafting, implementation, validation, and self-correction — escalating only irreversible decisions to the human.

## How It Works

Agent Atelier orchestrates a team of specialized agents through a file-based state machine. The human provides a service concept; the team refines it into a behavior spec, decomposes it into work items, implements them in isolated worktrees, validates with an independent runtime, and iterates on review findings until all work items pass.

```
DISCOVER --> SPEC_DRAFT --> SPEC_HARDEN --> BUILD_PLAN --> IMPLEMENT
                                ^                            |
                                |                            v
                           AUTOFIX <--- REVIEW_SYNTHESIS <-- VALIDATE
                                |
                                '------------------------------> DONE
```

Mode transitions follow a formal protocol defined in the run skill. IMPLEMENT and VALIDATE may overlap — a Builder can work on the next work item while the VRM validates the current candidate.

### Agent Team

| Category | Roles | Activation |
|----------|-------|------------|
| Always-on Core | Orchestrator (lead), State Manager, PM, Architect | Every loop iteration |
| Conditional Executors | Builder (full-stack), UI Designer, VRM | On demand per phase |
| Conditional Reviewers | QA Reviewer, Pragmatic UX Reviewer | Most validation loops |
| Milestone-only | Aesthetic UX Reviewer | Release candidates |

10 production role prompts in `references/prompts/`. The Orchestrator role is played by the lead agent; the remaining 3 core roles are spawned as teammates via Agent Teams.

### Key Design Choices

- **Documents are truth, conversations are ephemeral.** Teammates read project context from disk, not conversation history.
- **Information barrier.** VRM and reviewers never see Builder summaries or diffs — inputs are assembled from work items and specs only.
- **Single writer.** All state mutations go through `state-commit` with revision-based optimistic concurrency and WAL crash recovery.
- **Non-blocking human gates.** When a decision requires human approval, the team continues all unblocked work.

## Installation

Add to your project's `.claude/settings.json`:

```json
{
  "permissions": {
    "additionalDirectories": []
  },
  "extraKnownMarketplaces": {
    "agent-atelier": {
      "source": { "source": "github", "repo": "ether-moon/agent-atelier" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": {
    "agent-atelier@agent-atelier": true
  }
}
```

Requires Claude Code with Opus 4.6 (Agent Teams support) and Python 3.

## Usage

```
/agent-atelier:init          # bootstrap .agent-atelier/ state directory
# write or place your behavior spec at docs/product/behavior-spec.md
/agent-atelier:run           # start the autonomous loop
```

The loop runs autonomously. Human gates appear when irreversible or product-level decisions arise — respond in chat and the team resumes.

Monitor progress at any time:

```
/agent-atelier:status        # orchestration dashboard
```

## Skills

| Skill | Purpose |
|-------|---------|
| `init` | Bootstrap orchestration workspace (`.agent-atelier/`) |
| `status` | Show orchestration dashboard — mode, active candidate, open gates, WI summary |
| `wi` | Work item planning: `list`, `show`, `upsert` |
| `execute` | Execution lifecycle: `claim`, `heartbeat`, `requeue`, `complete`, `attempt` |
| `candidate` | Candidate pipeline: `enqueue`, `activate`, `clear` |
| `validate` | Validation evidence recording with manifest and WI status update |
| `gate` | Human decision gates: `list`, `open`, `resolve` |
| `watchdog` | Health check, lease recovery, stale candidate demotion, budget monitoring |
| `run` | Orchestration loop entry point — team spawn, state machine, continuous monitoring |

All skills are invoked as `/agent-atelier:<skill-name>`.

## Architecture

```
plugins/agent-atelier/
├── skills/                          # 9 skills (SKILL.md each)
│   ├── init/    ├── status/   ├── wi/
│   ├── execute/ ├── candidate/├── validate/
│   ├── gate/    ├── watchdog/ └── run/
├── hooks/
│   ├── hooks.json                   # UserPromptSubmit, PreToolUse, Stop, SubagentStop
│   ├── on-prompt.sh                 # Signal collector (open gates, active candidate, pending WAL)
│   ├── on-pre-tool-use.sh           # Destructive command blocking
│   ├── on-task-completed.sh         # Minimum evidence validation
│   └── on-stop.sh                   # Dangling obligation check
├── scripts/
│   ├── state-commit                 # Atomic multi-file writer with WAL and revision checking
│   └── build-vrm-prompt             # VRM evidence input builder (information barrier)
├── schema/
│   └── vrm-evidence-input.schema.json
└── references/
    ├── paths.md                     # Canonical path reference
    ├── state-defaults.md            # Default JSON structures and operating budgets
    ├── wi-schema.md                 # Work item schema and normalization rules
    ├── recovery-protocol.md         # Cold resume algorithm and test scenarios
    ├── success-metrics-routing.md   # Metrics routing (prioritization, synthesis, gates)
    └── prompts/                     # 10 production role prompts
```

### Runtime State

State lives in `.agent-atelier/` (gitignored):

| File | Purpose |
|------|---------|
| `loop-state.json` | Control plane: mode, active candidate, candidate queue, open gates |
| `work-items.json` | WI store: status, lease, promotion, completion |
| `watchdog-jobs.json` | Timeout thresholds and operating budgets |
| `validation/<run-id>/manifest.json` | Validation run evidence |
| `reviews/<WI-ID>/findings.json` | Review findings for cold resume recovery |
| `.pending-tx.json` | WAL for crash recovery (transient) |

## Design Documents

| Document | Scope |
|----------|-------|
| [`system-design.md`](docs/design/system-design.md) | Architecture, roles, state machine, operating principles |
| [`runtime-contracts.md`](docs/design/runtime-contracts.md) | Cross-component ownership, invariants, request/ack contract |
| [`state-schemas.md`](docs/design/state-schemas.md) | Canonical JSON shapes for all state files |
| [`cli-surface.md`](docs/design/cli-surface.md) | Required command interface |
| [`agent-lifecycle.md`](docs/design/agent-lifecycle.md) | Session identity, leases, candidate lifecycle, crash resume |
| [`recovery-spec.md`](docs/design/recovery-spec.md) | Watchdog recovery rules and escalation thresholds |
| [`human-gate-ops.md`](docs/design/human-gate-ops.md) | Human decision gate operations |

## Testing

```bash
bash tests/all.sh
```

47 assertions covering plugin structure, hook wiring, script executability, skill presence, role prompt completeness, state schema validation, and mutation flow.

## License

MIT
