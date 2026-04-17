# Gate Transactions — State-Commit Details

Detailed transaction formats for gate operations. All writes go through `state-commit` to guarantee atomicity.

## Table of Contents

- [Write Protocol](#write-protocol)
- [Open Gate Transaction](#open-gate-transaction)
- [Resolve Gate Transaction](#resolve-gate-transaction)
- [Revision Rules](#revision-rules)

## Write Protocol

Gate operations touch multiple files (HDR, work-items.json, loop-state.json, _index.md). All writes go through a single `state-commit` transaction to prevent partial updates. If the session stops between read and commit, no files change. If it stops after commit, all files are consistent.

```bash
echo '<transaction-json>' | <plugin-root>/scripts/state-commit --root <repo-root>
```

The transaction includes every file that needs to change, with `expected_revision` set for JSON files that have revision tracking. The `_index.md` and new HDR files use `expected_revision: null` since they are created fresh or have no revision field.

## Open Gate Transaction

When creating a new gate, the transaction writes four files atomically:

```json
{
  "writes": [
    {"path": ".agent-atelier/human-gates/open/HDR-010.json", "expected_revision": null, "content": {"id": "HDR-010", "...": "..."}},
    {"path": ".agent-atelier/work-items.json", "expected_revision": 7, "content": {"revision": 8, "...": "..."}},
    {"path": ".agent-atelier/loop-state.json", "expected_revision": 41, "content": {"revision": 42, "...": "..."}},
    {"path": ".agent-atelier/human-gates/_index.md", "expected_revision": null, "content": "..."}
  ]
}
```

If any revision check fails, the entire transaction is rejected — no partial state.

### What changes per file

| File | Change |
|------|--------|
| `open/<HDR-ID>.json` | New file with full HDR content |
| `work-items.json` | Blocked WIs: `status` -> `blocked_on_human_gate`, set `blocked_by_gate` and `resume_target` |
| `loop-state.json` | Add HDR ID to `open_gates`, bump revision |
| `_index.md` | New row in "Open Gates" table |

## Resolve Gate Transaction

When resolving a gate, the transaction writes four files and deletes one:

```json
{
  "writes": [
    {"path": ".agent-atelier/human-gates/resolved/HDR-010.json", "expected_revision": null, "content": {"id": "HDR-010", "state": "resolved", "...": "..."}},
    {"path": ".agent-atelier/work-items.json", "expected_revision": 7, "content": {"revision": 8, "...": "..."}},
    {"path": ".agent-atelier/loop-state.json", "expected_revision": 41, "content": {"revision": 42, "...": "..."}},
    {"path": ".agent-atelier/human-gates/_index.md", "expected_revision": null, "content": "..."}
  ],
  "deletes": [".agent-atelier/human-gates/open/HDR-010.json"]
}
```

The delete is part of the transaction — it happens after all writes succeed, and is included in the WAL for crash recovery. No separate delete step is needed.

### What changes per file

| File | Change |
|------|--------|
| `resolved/<HDR-ID>.json` | New file with resolved HDR (state=resolved, resolution fields filled) |
| `open/<HDR-ID>.json` | Deleted |
| `work-items.json` | Unblock each WI: `status` -> `ready`, clear `blocked_by_gate` |
| `loop-state.json` | Remove HDR ID from `open_gates` |
| `_index.md` | Move row from "Open Gates" to "Resolved Gates" |

## Revision Rules

- JSON state files (`work-items.json`, `loop-state.json`) use `expected_revision` matching their current `revision` field.
- New HDR files use `expected_revision: null` (not `0`). The value `0` causes a stale-revision rejection because new files have no prior revision.
- `_index.md` uses `expected_revision: null` since it has no revision tracking.
- HDR files are immutable after creation — they have no `revision` field and are never updated in place. To amend a resolved gate, create a new HDR referencing the original.
