# State Machine — Phases, Transitions, and Completion

> Referenced from `SKILL.md` Phase 3. This file covers mode transitions, phase details, review findings persistence, DONE cleanup, and cleanup verification.

## Table of Contents

- [Mode Transition Protocol](#mode-transition-protocol)
- [Phase Details](#phase-details)
- [Fast-Track Review](#fast-track-review)
- [Review Findings Persistence](#review-findings-persistence)
- [DONE Cleanup Checklist](#done-cleanup-checklist)
- [Cleanup Verification](#cleanup-verification)

## Mode Transition Protocol

All mode transitions are explicit -- the Orchestrator directs the State Manager to update `loop-state.json.mode` via `state-commit`. No implicit transitions.

**Valid transitions:**

| From | To | Trigger |
|------|----|---------|
| DISCOVER | SPEC_DRAFT | PM confirms spec ready for hardening |
| SPEC_DRAFT | SPEC_HARDEN | First complete draft exists |
| SPEC_HARDEN | BUILD_PLAN | Spec stable -- no open challenges |
| BUILD_PLAN | IMPLEMENT | WIs created, at least one `ready` |
| IMPLEMENT | VALIDATE | `active_candidate_set` set |
| VALIDATE | IMPLEMENT | VRM passed + fast-track conditions met -> skip review |
| VALIDATE | REVIEW_SYNTHESIS | VRM passed + fast-track not met -> full review |
| VALIDATE | IMPLEMENT | Validation failed |
| REVIEW_SYNTHESIS | AUTOFIX | Bugs found |
| REVIEW_SYNTHESIS | SPEC_DRAFT | Spec gaps found |
| REVIEW_SYNTHESIS | IMPLEMENT | Review clean -- continue next WI |
| AUTOFIX | VALIDATE | New candidate produced |
| AUTOFIX | IMPLEMENT | Builder needs to re-implement (not just patch) |
| SPEC_HARDEN | SPEC_DRAFT | Spec fundamentally inadequate -- needs rewrite |
| Any | DONE | All WIs `done` with evidence |

**Overlap:** IMPLEMENT and VALIDATE may be active concurrently -- a Builder can work on the next WI while VRM validates the current candidate.

**Invalid transitions:** Any transition not in the table above is rejected. The State Manager must refuse the write and report the invalid pair.

## Phase Details

### DISCOVER
- **Actors:** Orchestrator, PM
- **Activity:** PM reads/reviews the behavior spec, identifies gaps, updates open questions
- **Transition:** -> SPEC_DRAFT when PM confirms spec is ready for hardening

### SPEC_DRAFT
- **Actors:** PM, Architect (consultation)
- **Activity:** PM drafts or revises the behavior spec with verifiable behaviors
- **Transition:** -> SPEC_HARDEN when first complete draft exists

### SPEC_HARDEN
- **Actors:** PM, Architect (mutual auditing)
- **Activity:** Architect challenges spec, PM revises. Multiple rounds until both agree.
- **Transition:** -> BUILD_PLAN when spec is stable (no open challenges)

### BUILD_PLAN
- **Actors:** Architect
- **Activity:** Architect decomposes spec into vertical-slice work items via `wi upsert`
- **Verify hard gate:** Before transitioning to IMPLEMENT, verify ALL `ready` WIs have `verify.length >= 1`. If any WI has an empty verify array, reject the transition and report the WI IDs.
- **Complexity hard gate:** Before transitioning to IMPLEMENT, verify ALL `ready` WIs have non-null `complexity`. `null` means "not yet assessed" and must be fixed by the Architect before execution begins.
- **Transition:** -> IMPLEMENT when all WIs are created, at least one is `ready`, and both hard gates pass

### IMPLEMENT
- **Actors:** Builder(s), Architect (support)
- **Activity:** Builders claim WIs, implement in worktrees, produce atomic commits
- **On candidate ready:** Builder signals completion -> `candidate enqueue` -> continue to next WI
- **Transition:** -> VALIDATE when `active_candidate_set` is set (can overlap with ongoing implementation)

### VALIDATE
- **Actors:** VRM
- **Activity:** VRM runs full validation suite against `active_candidate_set`, produces evidence bundle
- **Information barrier:** VRM input from `build-vrm-prompt` only -- no Builder context
- **On result:** `validate record` -> if passed, evaluate fast-track; if failed, -> back to IMPLEMENT

### REVIEW_SYNTHESIS
- **Actors:** QA Reviewer, UX Reviewer, PM
- **Activity:**
  1. Reviewers independently assess evidence bundle (first-pass)
  2. PM synthesizes findings and initiates debate if needed
  3. PM classifies each finding: `bug` | `spec_gap` | `ux_polish` | `product_level_change`
  4. Orchestrator cross-verifies PM's classification
- **On result:** Bugs -> AUTOFIX; spec gaps -> back to SPEC_DRAFT; product changes -> human gate; polish -> log for later; review clean -> back to IMPLEMENT (continue next WI)

### AUTOFIX
- **Actors:** Builder(s)
- **Activity:** Fix bugs identified in review, produce new candidate
- **Transition:** -> VALIDATE with new candidate (loop until clean)

## Fast-Track Review

When VRM passes, check whether the candidate set qualifies for fast-track (skip REVIEW_SYNTHESIS). **ALL conditions must be met** (per-batch, conservative):

1. Every WI in `active_candidate_set` has `complexity == "simple"`
2. VRM `status == "passed"`
3. Total diff (from candidate branch) is <= 30 lines
4. No WI's `owned_paths` contains auth, payment, schema-migration, or public-api paths

If all conditions met: -> IMPLEMENT (skip review, proceed to complete or next WI)
If any condition not met: -> REVIEW_SYNTHESIS (full review cycle)

`complexity == null` always disqualifies fast-track -- the Architect must explicitly set complexity.

## Review Findings Persistence

Review findings are persisted to disk so they survive cold resume and session crashes. This is the source of truth for review state recovery.

**Path:** `.agent-atelier/reviews/<WI-ID>/findings.json`

**Schema:**

```json
{
  "work_item_id": "WI-014",
  "findings": [
    {
      "id": "F-WI014-01",
      "source": "qa-reviewer | ux-reviewer",
      "severity": "critical | major | minor",
      "classification": "bug | spec_gap | ux_polish | product_level_change",
      "summary": "One-sentence description of the finding",
      "evidence_refs": [".agent-atelier/validation/RUN-.../manifest.json"],
      "disposition": "open | fixed | deferred | wontfix"
    }
  ],
  "synthesis": {
    "classified_by": "pm",
    "classified_at": "2026-04-08T15:30:00Z",
    "cross_verified_by": "orchestrator"
  }
}
```

On cold resume, the Orchestrator reads this file to restore review state. If a WI is in `reviewing` status but no `findings.json` exists, the review must be re-initiated from the REVIEW_SYNTHESIS phase.

## DONE Cleanup Checklist

All WIs complete with evidence. Execute the team cleanup checklist in order:

1. **Verify completion:** Confirm all WIs have status `done` and `active_candidate_set` is null.
2. **Stop monitors:** Stop all monitors via `/agent-atelier:monitors stop all`.
3. **Cancel cron jobs:** `CronDelete` both the stored monitor poll job ID and the stored watchdog recovery job ID.
4. **Shutdown teammates:** Send `SendMessage({type: "shutdown_request"})` to each active teammate. Wait for all to reach idle/stopped state.
5. **Clean up team:** Call `TeamDelete` to remove team resources. **Only the lead (Orchestrator) may run cleanup** -- teammates running cleanup can leave resources inconsistent.
6. **Report results and recommend next step:** Present a concise completion report followed by one recommended action.

   **Completion report** -- two parts only:
   - **What was built:** One sentence summarizing the outcome in user terms, derived from WI titles/descriptions. Never list raw WI counts or commit SHAs -- the user cares about capabilities, not bookkeeping.
   - **Issues to flag** (only if present): Validation gaps, failed attempts that were worked around, warnings from the review phase. Omit this section entirely if everything is clean.

   **Recommended next step** -- pick the single most logical action based on current state, in this priority order:
   1. Validation gaps exist -> flag which WIs lack evidence and offer to run validation
   2. On a feature branch with commits not yet in a PR -> offer to create the PR
   3. PR already exists but CI hasn't run -> offer to check CI status
   4. Everything clean -> report complete, ask if there's anything else

   Present the recommendation as a direct offer, not a menu of options. The user can always redirect. If the user picks the offered action, execute it immediately without further confirmation.

## Cleanup Verification

After executing the cleanup checklist, verify each step actually succeeded before reporting to the user:

**Primary success conditions** (all must pass):
1. Re-read `work-items.json` and `loop-state.json` -- confirm zero non-`done` items and `active_candidate_set` is null.
2. Call `CronList` -- confirm no remaining orchestration cron jobs (monitor poll or watchdog recovery). If any exist, `CronDelete` them.
3. Team cleanup completed successfully -- the lead executed cleanup and no active teammates remain.

**Secondary confirmation** (informational, not blocking):
4. Check whether `~/.claude/teams/<team_name>/` still exists on disk. Directory absence confirms cleanup, but presence alone is not a failure -- the canonical signal is step 3 (successful cleanup execution). Log a warning if the directory persists after successful cleanup.

**On failure:**
5. If primary conditions 1-3 fail, retry the shutdown/cleanup sequence once. If still failing, report discrepancies to the user with manual remediation commands.

**Do NOT report "loop completed" until all primary verification checks pass.**
