---
name: init
description: "Initialize the orchestration workspace with default state files and directory structure. Use when bootstrapping a new project with agent-atelier, when orchestration files are missing, or when the user says 'init', 'initialize', 'bootstrap', or 'set up the workspace'. Safe to re-run — only creates files that don't already exist."
argument-hint: "[--root <path>]"
---

# Init — Bootstrap Orchestration Workspace

## When This Skill Runs

- First-time project setup
- Recovery after state files were deleted
- User explicitly asks to initialize or bootstrap

## Prerequisites

- Must be inside a git repository (or provide `--root`)

## Allowed Tools

- Read (check for existing files)
- Write (create state files)
- Bash (create directories, detect git root)

## Input

Optional `--root <path>` argument. If omitted, detect via `git rev-parse --show-toplevel`.

## Execution Steps

1. **Detect root.** Run `git rev-parse --show-toplevel` to find the repo root, or use the provided `--root` path.

2. **Create directories.** Ensure these directories exist (create if missing):
   - `.agent-atelier/`
   - `.agent-atelier/human-gates/open/`
   - `.agent-atelier/human-gates/resolved/`
   - `.agent-atelier/human-gates/templates/`
   - `.agent-atelier/attempts/`

3. **Create state files.** For each file below, check if it already exists. Only create it if missing. Read `references/state-defaults.md` in this plugin for the exact default JSON shapes.

   | File | Source Template |
   |------|---------------|
   | `.agent-atelier/loop-state.json` | Default loop state |
   | `.agent-atelier/work-items.json` | Default work items |
   | `.agent-atelier/watchdog-jobs.json` | Default watchdog jobs |
   | `.agent-atelier/human-gates/_index.md` | Default gate dashboard |
   | `.agent-atelier/human-gates/templates/human-decision-request.json` | Gate template |

   Replace `<now>` placeholders with the current UTC timestamp in ISO-8601 format with `Z` suffix.

4. **Check for incomplete transactions.** If `.agent-atelier/.pending-tx.json` exists, a previous state-commit was interrupted mid-write. Replay it with the `--replay` flag, which handles partially applied files (skips already-written files, applies remaining ones):
   ```bash
   cat .agent-atelier/.pending-tx.json | <plugin-root>/scripts/state-commit --root <repo-root> --replay
   ```
   Report the WAL recovery in the output.

5. **Report results.** Print a summary of what was created vs what already existed:

   ```
   Initialized orchestration workspace at <root>
   Created: loop-state.json, work-items.json, watchdog-jobs.json
   Already existed: (none)
   ```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — workspace initialized or already up to date |
| `1` | Usage error (invalid arguments) |
| `3` | Not inside a git repository and no `--root` given |
| `4` | Runtime failure (disk error, WAL replay failure) |

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

If all files already exist: `"changed": false`. Diagnostic messages go to stderr.

## Idempotency

Init is inherently idempotent — re-running when files already exist returns `"changed": false`. WAL recovery is also idempotent: replayed files whose revision already matches the target are skipped.

## Error Handling

- If not inside a git repo and no `--root` given: report the error and suggest providing a root path.
- If a state file exists but contains invalid JSON: warn the user but do not overwrite. The user should fix or delete the corrupted file manually.

## Constraints

- Never overwrite existing state files — they may contain in-progress work.
- Always use UTC timestamps with `Z` suffix.
