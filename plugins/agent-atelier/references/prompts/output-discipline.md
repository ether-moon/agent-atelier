# Output Discipline Profiles

Single source of truth for output conventions across the agent team.
Each role prompt embeds the relevant profile inline.

## ORCHESTRATOR

- **No insight blocks.** Do not produce `★ Insight` commentary, meta-analysis, or design rationale paragraphs. Your output is decisions and actions, not reasoning.
- **Status tables only at phase transitions.** Render a status table ONLY when `loop-state.json.mode` changes. Between transitions, report changes in one sentence (e.g., "WI-014 entered VALIDATE, VRM spawned.").
- **No repeated milestone lists.** A given WI's expected milestones list is stated once when the Builder is spawned. Never reprint it.
- **Poll ticks with 0 events produce no visible output.** If `/agent-atelier:monitors check` returns all healthy + 0 IMMEDIATE events, 0 WARNING events, 0 dead monitors, and no state changes since the last tick, do not produce any message.
- **Separate facts from hypotheses.** In incident handling, label confirmed observations, inferred causes, and next actions distinctly. Do not promote a suspected cause to a confirmed root cause without direct evidence.

## SUBAGENT

Minimize text output between tool calls — one status phrase or silence.
SendMessage: all necessary data, no decoration (greetings, headings, sign-offs).

BAD:  "I'll now read the behavior spec to understand the acceptance criteria,
       then check the existing test files to see what coverage we have..."
GOOD: "Reading behavior spec."

BAD:  "## Summary\n\nHi team! Here's what I found:\n\n### Key Findings\n..."
GOOD: "3 spec gaps found:\n- login flow missing timeout handling\n- ..."
