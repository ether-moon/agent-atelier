---
name: init
description: "Initialize the orchestration workspace with default state files and directory structure. Use when bootstrapping a new project, when orchestration state is missing or corrupt, when the user says 'init', 'initialize', 'bootstrap', 'set up the workspace', 'start a project', 'prepare for agent-atelier', or 'create state files'. Also triggers automatically before /agent-atelier:run if .agent-atelier/ does not exist. Safe to re-run — only creates files that don't already exist."
argument-hint: "[--root <path>]"
---

# Init — Bootstrap Orchestration Workspace

## When This Skill Runs

- First-time project setup
- Recovery after state files were deleted
- User explicitly asks to initialize or bootstrap
- Pre-flight for `/agent-atelier:run` when `.agent-atelier/` is missing

## Prerequisites

- Must be inside a git repository (or provide `--root`)

## Allowed Tools

- Read (check for existing files)
- Write (create state files)
- Bash (create directories, detect git root)

## Usage Examples

```
/agent-atelier:init                     # auto-detect git root
/agent-atelier:init --root /path/to/repo  # explicit root
```

## Execution Steps

1. **Detect root.** Run `git rev-parse --show-toplevel`, or use `--root <path>` if provided. If neither works, exit with code 3.

2. **Create directories.** `mkdir -p` for each (no-ops if they exist):
   - `.agent-atelier/`
   - `.agent-atelier/human-gates/open/`
   - `.agent-atelier/human-gates/resolved/`
   - `.agent-atelier/human-gates/templates/`
   - `.agent-atelier/attempts/`

3. **Create state files.** For each file, check existence first. Only write if missing. Use the default shapes from `references/state-defaults.md` (in this plugin's parent `references/` directory). Replace every `<now>` placeholder with the current UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`).

   | File | Source Template |
   |------|---------------|
   | `.agent-atelier/loop-state.json` | Default loop state |
   | `.agent-atelier/work-items.json` | Default work items |
   | `.agent-atelier/watchdog-jobs.json` | Default watchdog jobs |
   | `.agent-atelier/human-gates/_index.md` | Default gate dashboard |
   | `.agent-atelier/human-gates/templates/human-decision-request.json` | Gate template |

4. **Check for incomplete transactions.** If `.agent-atelier/.pending-tx.json` exists, a previous `state-commit` was interrupted. Replay it:
   ```bash
   cat .agent-atelier/.pending-tx.json | \
     <plugin-root>/scripts/state-commit --root <repo-root> --replay
   ```
   Where `<plugin-root>` is the resolved path to `plugins/agent-atelier` (e.g., via `${CLAUDE_SKILL_DIR}/../..`). The replay is idempotent: already-written files are skipped. Report the recovery in output.

5. **Report results.** Print a summary:
   ```
   Initialized orchestration workspace at /path/to/repo
   Created: loop-state.json, work-items.json, watchdog-jobs.json
   Already existed: human-gates/_index.md
   ```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — workspace initialized or already up to date |
| `1` | Usage error (invalid arguments) |
| `3` | Not inside a git repository and no `--root` given |
| `4` | Runtime failure (disk error, permission denied, WAL replay failure) |

## Output Contract

Returns JSON to stdout:

```json
{
  "request_id": "<id>",
  "accepted": true,
  "committed_revision": 1,
  "changed": true,
  "root": "/path/to/repo",
  "artifacts": [
    ".agent-atelier/loop-state.json",
    ".agent-atelier/work-items.json",
    ".agent-atelier/watchdog-jobs.json"
  ],
  "wal_recovered": false
}
```

`"changed": false` when all files already exist. Diagnostic messages go to stderr.

## Idempotency

Re-running when files exist returns `"changed": false`. WAL replay skips files whose revision already matches the target.

## Error Handling

- **No git root and no `--root`:** Exit 3. Suggest `--root /path/to/repo`.
- **Corrupt state file** (exists but invalid JSON): Warn the user, do not overwrite. The user must fix or delete the file manually before re-running.
- **Directory creation fails** (permission denied): Exit 4. Report the failed path.
- **WAL replay fails:** Exit 4. Report the error. The pending transaction file (`.pending-tx.json`) is preserved for manual inspection.
- **`state-commit` script not found:** Exit 4. Report the expected path (`<plugin-root>/scripts/state-commit`).

## Constraints

- Never overwrite existing state files — they may contain in-progress work.
- Always use UTC timestamps with `Z` suffix.
