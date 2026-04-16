# Native Task Sync

After a successful state-commit for an upsert, sync the work item to the native Agent Teams task list. This creates a visibility layer with automatic dependency resolution. **Sync failures are non-fatal** -- log a warning to stderr but do not fail the upsert. `work-items.json` is always the source of truth.

## Find the Canonical Native Task

Call `TaskList` and collect all tasks whose subject starts with `"WI-NNN:"` (matching the target WI's ID prefix). Apply the deduplication rule:

- **0 matches:** No native task exists yet -- proceed to Create and Wire Dependencies.
- **1 match:** This is the canonical native task -- done. No dependency rewiring needed.
- **2+ matches:** Log a warning to stderr listing all duplicate task IDs. Use the task with the highest ID as the canonical one (newest). Ignore the others. This can happen after response loss during TaskCreate, partial retry, or manual cleanup failure. Done.

## Create If New

Only if Find found 0 matches (this is a new WI), call `TaskCreate` with:

- `subject`: `"WI-NNN: <title>"`
- `description`: The WI's `title` and `why_now` fields, plus `"Tracked in .agent-atelier/work-items.json. Use /agent-atelier:status for detailed state."`
- `metadata`: `{"work_item_id": "WI-NNN"}`

## Wire Forward Dependencies

Only after Create (new task creation). If `depends_on` is non-empty, for each dependency WI ID:

1. Search `TaskList` for a task whose subject starts with the dependency WI's ID prefix.
2. Collect the found native task IDs.
3. Call `TaskUpdate` on the current WI's native task with `addBlockedBy` set to the collected IDs.
4. Skip any dependencies whose native tasks do not exist yet (they will be wired by Reverse Dependencies when created).

## Wire Reverse Dependencies

Only after Create. Search `TaskList` for any tasks whose corresponding WIs (in `work-items.json`) have `depends_on` containing the current WI's ID. For each found, call `TaskUpdate` on that task with `addBlockedBy` pointing to the current WI's native task. This handles the case where a depending WI was created before its dependency.

## Why Create-Only

Dependency wiring runs once at task creation. The `depends_on` field is immutable after first upsert (see normalization rule 8 in `wi-schema.md`), so re-wiring on subsequent updates would be redundant. Since the Agent Teams API only supports `addBlockedBy` (no removal), re-applying would at best be a no-op and at worst mask drift.
