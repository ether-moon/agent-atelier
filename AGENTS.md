# AGENTS.md

agent-atelier — Autonomous product development loop — AI agent team that cycles through spec, implement, validate, and self-correct

## Plugin Structure

- `plugins/agent-atelier/skills/` — Skill definitions (SKILL.md files)
- `plugins/agent-atelier/hooks/` — Lifecycle hooks (hooks.json + shell scripts)
- `plugins/agent-atelier/scripts/` — Bundled CLI tools
- `plugins/agent-atelier/schema/` — Asset files (SQL, config templates, etc.)

## Skill Format

Every skill is a `SKILL.md` with YAML frontmatter:

```yaml
---
name: skill-name
description: "One-line description"
argument-hint: "[optional args]"
---
```

Followed by markdown sections: When This Skill Runs, Prerequisites, Allowed Tools, Input, Output, Execution Steps, Error Handling, Constraints.

## Testing

```bash
bash tests/all.sh
```

## Knowledge Vault
- A UserPromptSubmit hook reminds you to query the vault when active entries exist
- When the hook fires and the task involves code modifications, query before planning:
  - Single file: `knowledge-gate query-paths <file-path>` (summary index by default)
  - Multiple files: `knowledge-gate domain-resolve-path <path>` → `knowledge-gate query-domain <domain>` (summary index by default)
  - Topic search: `knowledge-gate search <keyword>` (summary index by default)
  - Fetch full details only for the specific entries you need: `knowledge-gate get <id>` or `knowledge-gate get-many <id...>`
- MUST/MUST-NOT rules from returned entries must be strictly followed
- For structural changes in areas without related rules, confirm with a human first
- Do not directly read files in the .knowledge/ directory

## Memento
- After every git commit, attach a memento session summary as a git note on `refs/notes/commits`
- The summary follows the 7-section format: Decisions Made, Problems Encountered, Constraints Identified, Open Questions, Context, Recorded Decisions, Vault Entries Referenced
- See `/knowledge-distillery:memento-commit` for the full workflow and format specification
- If the PostToolUse hook fires a reminder, follow it — generate the summary and attach the note
