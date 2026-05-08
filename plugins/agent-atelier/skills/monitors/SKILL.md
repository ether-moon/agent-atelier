---
name: monitors
description: "[INTERNAL — invoked by orchestrator/cron, not for direct user use] Background monitor lifecycle — spawn continuous monitors, poll for events, stop monitors, or check health. Triggers on 'spawn monitors', 'check monitors', 'stop monitors', 'monitor status', 'spawn ci monitor', 'poll events', 'respawn'."
argument-hint: "spawn | check <task-ids-json> | stop [all | <name>] | status | spawn-ci --run-id <ID> | --pr <NUM>"
---

# Monitors — Internal Skill Shim

This skill is invoked **only** by the orchestrator or cron jobs. Users should not invoke it directly. Full procedure is documented in `${CLAUDE_PLUGIN_ROOT}/references/monitor-runtime.md` — read that file before executing any subcommand.

## Behavior

Read `references/monitor-runtime.md` and execute the requested subcommand per its procedure. The subcommand argument is in `$ARGS` (e.g., `spawn`, `check '{...}'`, `stop all`).

## Output

JSON per subcommand as documented in `references/monitor-runtime.md`. No deviation.

## Idempotency

Each subcommand's idempotency is documented in the reference.
