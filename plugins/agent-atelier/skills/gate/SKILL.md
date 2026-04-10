---
name: gate
description: "Human decision gate lifecycle — list open gates, create a new gate for user decisions, or resolve an existing gate. Use when the orchestrator needs to escalate a decision to the user, when viewing pending decisions, or when the user responds to a gate. Triggers on 'gate', 'human gate', 'escalate', 'decision needed', 'open gate', 'resolve gate', 'HDR', 'pending decisions', or when the 3-test criteria (irreversibility, blast radius, product meaning) indicate a human decision is required."
argument-hint: "list | open <json> | resolve <HDR-ID> <chosen-option>"
---

# Gate — Human Decision Gates

Human gates are the system's mechanism for pausing when a decision is too consequential for the agent team to make alone. They exist because some decisions — breaking API changes, auth flow modifications, data model pivots — are irreversible or affect too many people to risk getting wrong.

## When This Skill Runs

- Orchestrator detects a Level 4 escalation
- User asks to see pending decisions
- User provides a decision on an open gate
- Recovery after session restart (check for open gates)

## Prerequisites

- Orchestration must be initialized

## Allowed Tools

- Read (state files, HDR files), Bash (git root, state-commit), Glob

## Write Protocol

Gate operations touch multiple files (HDR, work-items.json, loop-state.json, _index.md). All writes go through a single `state-commit` transaction to prevent partial updates. If the session stops between read and commit, no files change. If it stops after commit, all files are consistent.

```bash
echo '<transaction-json>' | <plugin-root>/scripts/state-commit --root <repo-root>
```

The transaction includes every file that needs to change, with `expected_revision` set for JSON files that have revision tracking. The `_index.md` and new HDR files use `expected_revision: null` since they're created or have no revision field.

## The 3-Test Gate Criteria

Before opening a gate, apply these three tests. If ANY scores HIGH, a human gate is warranted:

1. **Irreversibility** — Can this be undone without significant cost? (HIGH = no easy undo)
2. **Blast Radius** — How many components, users, or systems are affected? (HIGH = many)
3. **Product Meaning** — Does this change what the product IS, not just how it works? (HIGH = yes)

## Subcommands

### `list`

1. Scan both `.agent-atelier/human-gates/open/` and `.agent-atelier/human-gates/resolved/` for HDR JSON files.
2. Deduplicate: if a gate ID appears in both `open/` and `resolved/` (orphaned from an interrupted resolve), treat it as resolved. The `resolved/` copy is authoritative.
3. Render a summary:

```
Open Gates (2):
  HDR-007: "API shape: preserve current or allow breaking change?"
    Blocking: WI-014  |  Created: 2026-04-07T14:30:00Z (18h ago)
    Options: [A] Preserve backward compat  [B] Allow breaking change
    Recommended: A

  HDR-009: "Add Stripe dependency for payments?"
    Blocking: WI-018  |  Created: 2026-04-08T09:00:00Z (3h ago)
    Options: [A] Use Stripe  [B] Build in-house  [C] Defer payments
    Recommended: A

Resolved Gates (1):
  HDR-005: "Guest checkout policy" → Chosen: B (Allow guest checkout)
    Resolved: 2026-04-06T16:00:00Z
```

### `open`

Creates a new human decision request. The orchestrator provides the decision context; this skill writes the HDR file and updates affected work items.

1. **Assign ID.** Scan existing HDR files (both open and resolved) to find the highest HDR number. Assign the next one (e.g., `HDR-010`).

2. **Build the HDR.** Read `references/state-defaults.md` for the template structure. Fill in:
   - `id` — the assigned ID
   - `created_at` — now (UTC)
   - `state_revision` — current loop-state revision
   - `triggered_by` — who/what triggered this gate
   - `question` — the decision question (clear, specific, answerable)
   - `why_now` — why this can't be deferred
   - `context` — relevant background
   - `gate_criteria` — the 3-test scores
   - `options` — array of choices with labels and descriptions
   - `recommended_option` — the team's recommendation (if any)
   - `blocking` — true if this blocks work items
   - `blocked_work_items` — IDs of affected work items

3. **Read current state.** Read `.agent-atelier/work-items.json` and `.agent-atelier/loop-state.json`. Note both revisions.

4. **Prepare all changes in memory** (do not write yet):
   - HDR file content for `.agent-atelier/human-gates/open/<HDR-ID>.json`
   - Updated work-items.json with blocked WIs:
     - `status` → `blocked_on_human_gate`
     - `blocked_by_gate` → the HDR ID
     - `resume_target` → the mode to resume after resolution (e.g., `IMPLEMENT`, `BUILD_PLAN`)
     - Bump item and store revisions
   - Updated loop-state.json with HDR ID added to `open_gates`, revision bumped
   - Updated `_index.md` with new row in "Open Gates" table

5. **Commit all changes in one transaction** via state-commit. The transaction includes all four files:
   ```json
   {"writes": [
     {"path": ".agent-atelier/human-gates/open/HDR-010.json", "expected_revision": null, "content": {...}},
     {"path": ".agent-atelier/work-items.json", "expected_revision": 7, "content": {...}},
     {"path": ".agent-atelier/loop-state.json", "expected_revision": 41, "content": {...}},
     {"path": ".agent-atelier/human-gates/_index.md", "expected_revision": null, "content": "..."}
   ]}
   ```
   If any revision check fails, the entire transaction is rejected — no partial state.

### `resolve <HDR-ID> <chosen-option>`

Resolves an open gate with the user's decision.

1. **Read all state.** Read the HDR from `open/<HDR-ID>.json`, `work-items.json`, `loop-state.json`, and `_index.md`. Note revisions.

2. **Prepare all changes in memory:**
   - Resolved HDR: set `state` → `resolved`, fill `resolution` fields
   - Updated work-items.json: unblock each WI (`status` → `ready`, clear `blocked_by_gate`). The `resume_target` field is a mode hint for the Orchestrator, not a WI status.
   - Updated loop-state.json: remove HDR ID from `open_gates`
   - Updated `_index.md`: move row from "Open Gates" to "Resolved Gates"

3. **Commit all changes in one transaction** via state-commit, including the `open/` file deletion:
   ```json
   {"writes": [
     {"path": ".agent-atelier/human-gates/resolved/HDR-010.json", "expected_revision": null, "content": {...}},
     {"path": ".agent-atelier/work-items.json", "expected_revision": 7, "content": {...}},
     {"path": ".agent-atelier/loop-state.json", "expected_revision": 41, "content": {...}},
     {"path": ".agent-atelier/human-gates/_index.md", "expected_revision": null, "content": "..."}
   ],
   "deletes": [".agent-atelier/human-gates/open/HDR-010.json"]}
   ```
   The delete is part of the transaction — it happens after all writes succeed, and is included in the WAL for crash recovery. No separate delete step needed.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage or validation error (missing required fields, invalid option) |
| `2` | Precondition failed or stale revision |
| `3` | HDR or work item not found |
| `4` | Runtime or environment failure |

## Input Conventions

The `open` subcommand accepts payload via:
- `--json '<inline-json>'` — inline JSON string
- `--input <path>` — path to a JSON file

Required flags for `open` and `resolve`:
- `--request-id <id>` — unique request identifier for idempotency tracking
- `--based-on-revision <N>` — the store revision observed at read time

## Output Contract

**`list`** returns JSON to stdout:

```json
{
  "open": [{"id": "HDR-007", "question": "...", "blocked_work_items": ["WI-014"], "created_at": "..."}],
  "resolved": [{"id": "HDR-005", "question": "...", "chosen_option": "B", "resolved_at": "..."}]
}
```

**`open`** and **`resolve`** return the mutation response:

```json
{
  "request_id": "REQ-301",
  "accepted": true,
  "committed_revision": 42,
  "changed": true,
  "artifacts": [
    ".agent-atelier/human-gates/open/HDR-010.json",
    ".agent-atelier/work-items.json",
    ".agent-atelier/loop-state.json",
    ".agent-atelier/human-gates/_index.md"
  ]
}
```

Diagnostic messages go to stderr. When presenting `list` to a human user, additionally render the readable dashboard format.

## Idempotency

For `open` and `resolve`:
- Same `request_id` + same payload → return previous result with `"changed": false, "replayed": true`
- Same `request_id` + different payload → reject with exit code `1`
- Stale `based_on_revision` → reject with exit code `2`
- WI already unblocked during `resolve`: skip it (partial idempotency within the operation)

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| HDR not found | `3` | List available open gate IDs |
| Chosen option not in options list | `1` | Show the valid options |
| WI already unblocked | `0` | Skip it (idempotent) |
| Stale revision | `2` | Report current vs expected, ask caller to re-read |

## Constraints

- Gates are never auto-resolved by the agent team. Only the user (or explicit orchestrator override with user pre-approval) can resolve them.
- The `_index.md` file is a human-readable dashboard, not the source of truth. The JSON files in `open/` and `resolved/` are authoritative.
- When context is compressed or a session restarts, always re-scan `open/` to restore awareness of pending gates.
