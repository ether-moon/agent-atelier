---
name: wi
description: "Work item planning — list all work items, show details of one, or create/update work items. Use for backlog management, viewing work item details, creating new work items, or updating existing ones. Triggers on 'work item', 'WI', 'backlog', 'list items', 'show WI-NNN', 'create work item', 'update work item', or 'upsert'. For execution-phase operations (claim, heartbeat, complete), use the execute skill instead."
argument-hint: "list | show <id> | upsert <json-or-fields>"
---

# WI — Work Item Planning

## When This Skill Runs

- Listing the backlog or checking work item status
- Viewing details of a specific work item
- Creating a new work item during planning
- Updating an existing work item's fields

## Prerequisites

- Orchestration must be initialized (`/agent-atelier:init`)

## Allowed Tools

- Read (state files), Bash (git root, state-commit), Glob, TaskCreate, TaskList, TaskUpdate

## Input

One of three subcommands:
- `list` — show all work items
- `show <WI-ID>` — show one work item in detail
- `upsert <json-or-fields>` — create or update a work item

For `upsert`, the caller provides either:
- Inline JSON: `upsert {"id": "WI-015", "title": "...", "status": "ready"}`
- Natural language that you translate into the correct JSON structure

## Execution Steps

### Subcommand: `list`

1. Read `.agent-atelier/work-items.json`.
2. Render a table of all items:

```
| ID     | Title                          | Status       | Owner          |
|--------|--------------------------------|--------------|----------------|
| WI-014 | Checkout empty/loading states   | implementing | exec-WI-014-02 |
| WI-015 | Payment retry logic             | ready        | —              |
```

3. Show the store revision at the bottom: `Store revision: 42`

### Subcommand: `show <WI-ID>`

1. Read `.agent-atelier/work-items.json`.
2. Find the item matching the given ID.
3. Display all fields in a readable format, highlighting:
   - Status and ownership
   - Lease expiry (if implementing)
   - Blocked gate (if blocked)
   - Attempt count and last finding
   - Promotion status

### Subcommand: `upsert`

This is the only subcommand that writes. Follow these steps carefully because the work item store uses revision-based concurrency control.

1. **Read current store.** Read `.agent-atelier/work-items.json`. Note the current `revision`.

2. **Validate the payload.** The payload must have an `id` field. Read `references/wi-schema.md` in this plugin for the full schema and normalization rules.

3. **Merge and normalize.** Apply the merge logic from `references/wi-schema.md`:
   - If item exists: defaults → existing → new payload
   - If item is new: defaults → new payload
   - Apply all normalization rules (array fields, promotion object, lease clearing, gate clearing, revision bump, depends_on immutability, complexity)

4. **Bump store revision.** Increment the store's `revision` by 1 and set `updated_at` to now.

5. **Commit via state-commit.** Build a transaction and pipe it to the state-commit script. This ensures atomic writes and revision checking. The script rejects the entire transaction if any revision is stale.

   ```bash
   echo '{"writes":[{"path":".agent-atelier/work-items.json","expected_revision":<current>,"content":<new-store>}]}' \
     | <plugin-root>/scripts/state-commit --root <repo-root>
   ```

6. **Check the result.** If `committed: true`, report success. If `committed: false` with `reason: stale_revision`, re-read the store and retry.

### Native Task Sync (after successful upsert)

After a successful state-commit, sync the work item to the native Agent Teams task list. This creates a visibility layer with automatic dependency resolution. **Sync failures are non-fatal** — log a warning to stderr but do not fail the upsert. `work-items.json` is always the source of truth.

7. **Find the canonical native task.** Call `TaskList` and collect all tasks whose subject starts with `"WI-NNN:"` (matching the target WI's ID prefix). Apply the deduplication rule:
   - **0 matches:** No native task exists yet — proceed to step 8 (create) and steps 9–10 (wire dependencies).
   - **1 match:** This is the canonical native task — skip to end (no dependency rewiring needed).
   - **2+ matches:** Log a warning to stderr listing all duplicate task IDs. Use the task with the highest ID as the canonical one (newest). Ignore the others. This can happen after response loss during TaskCreate, partial retry, or manual cleanup failure. Skip to end.

8. **Create if new.** Only if step 7 found 0 matches (this is a new WI), call `TaskCreate` with:
   - `subject`: `"WI-NNN: <title>"`
   - `description`: The WI's `title` and `why_now` fields, plus `"Tracked in .agent-atelier/work-items.json. Use /agent-atelier:status for detailed state."`
   - `metadata`: `{"work_item_id": "WI-NNN"}`

9. **Wire forward dependencies (create only).** Only after step 8 (new task creation). If `depends_on` is non-empty, for each dependency WI ID:
   - Search `TaskList` for a task whose subject starts with the dependency WI's ID prefix
   - Collect the found native task IDs
   - Call `TaskUpdate` on the current WI's native task with `addBlockedBy` set to the collected IDs
   - Skip any dependencies whose native tasks do not exist yet (they will be wired in step 10 when created)

10. **Wire reverse dependencies (create only).** Only after step 8. Search `TaskList` for any tasks whose corresponding WIs (in `work-items.json`) have `depends_on` containing the current WI's ID. For each found, call `TaskUpdate` on that task with `addBlockedBy` pointing to the current WI's native task. This handles the case where a depending WI was created before its dependency.

   **Why create-only:** Dependency wiring runs once at task creation. The `depends_on` field is immutable after first upsert (see normalization rule 8 in `wi-schema.md`), so re-wiring on subsequent updates would be redundant. Since the Agent Teams API only supports `addBlockedBy` (no removal), re-applying would at best be a no-op and at worst mask drift.

## Write Protocol

All mutations to `.agent-atelier/**` go through the `state-commit` script, which is the sole writer for orchestration state. This maintains cross-file consistency and provides crash recovery via a write-ahead log.

The script validates all revision checks before any write happens. If a revision is stale, the entire transaction is rejected — no partial writes.

**Revision checking is always enforced.** The skill reads the current store revision and passes it as `expected_revision`. There is no escape hatch — even in interactive use, the skill must read-then-write with the observed revision. This prevents lost updates in multi-agent scenarios.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage or validation error (missing `id` in upsert, malformed JSON) |
| `2` | Stale revision on upsert |
| `3` | Work item not found for `show` |
| `4` | Runtime or environment failure |

## Input Conventions

The `upsert` subcommand accepts payload via:
- `--json '<inline-json>'` — inline JSON string
- `--input <path>` — path to a JSON file

Required flags for `upsert`:
- `--request-id <id>` — unique request identifier for idempotency tracking
- `--based-on-revision <N>` — the store revision observed at read time

## Output Contract

**`list`** returns JSON to stdout:

```json
{
  "revision": 12,
  "items": [
    {"id": "WI-014", "title": "Checkout empty/loading states", "status": "implementing", "owner_session_id": "exec-WI-014-02"},
    {"id": "WI-015", "title": "Payment retry logic", "status": "ready", "owner_session_id": null}
  ]
}
```

**`show`** returns the full work item JSON object to stdout.

**`upsert`** returns the mutation response:

```json
{
  "request_id": "REQ-104",
  "accepted": true,
  "committed_revision": 13,
  "changed": true,
  "artifacts": [
    ".agent-atelier/work-items.json"
  ]
}
```

When presenting `list` or `show` to a human user, additionally render a readable table or detail view. Diagnostic messages go to stderr.

## Idempotency

For `upsert`:
- Same `request_id` + same payload → return previous result with `"changed": false, "replayed": true`
- Same `request_id` + different payload → reject with exit code `1`
- Stale `based_on_revision` → reject with exit code `2`

## Error Handling

| Condition | Exit Code | Action |
|-----------|-----------|--------|
| Missing `id` in upsert payload | `1` | Reject and explain |
| Work item not found for `show` | `3` | List available IDs |
| Malformed JSON | `1` | Report the parse error clearly |
| Stale revision on upsert | `2` | Report current vs expected, ask caller to re-read |

## Constraints

- The `wi` skill handles planning operations only. For execution lifecycle (claim, heartbeat, requeue, complete), use `/agent-atelier:execute`.
- Always preserve fields you're not explicitly changing — the merge logic is additive.
