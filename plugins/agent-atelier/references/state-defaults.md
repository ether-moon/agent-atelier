# Default State Objects

When initializing state files, use these exact defaults. Timestamps should be UTC ISO-8601 with `Z` suffix (e.g., `2026-04-08T12:00:00Z`).

## loop-state.json

```json
{
  "revision": 1,
  "updated_at": "<now>",
  "mode": "DISCOVER",
  "active_spec": "docs/product/behavior-spec.md",
  "active_spec_revision": 1,
  "open_gates": [],
  "active_candidate": null,
  "candidate_activated_at": null,
  "candidate_queue": [],
  "next_action": {
    "owner": "orchestrator",
    "type": "draft_first_work_item",
    "target": null
  }
}
```

## work-items.json

```json
{
  "revision": 1,
  "updated_at": "<now>",
  "items": []
}
```

## watchdog-jobs.json

```json
{
  "revision": 1,
  "updated_at": "<now>",
  "defaults": {
    "implementing_timeout_minutes": 90,
    "candidate_timeout_minutes": 30,
    "review_timeout_minutes": 30,
    "gate_warn_after_hours": 24
  },
  "budgets": {
    "max_wall_clock_minutes_per_wi": 480,
    "max_handoffs_per_wi": 6,
    "max_watchdog_interventions_per_wi": 3,
    "max_attempts_per_wi": 5
  },
  "open_alerts": [],
  "last_tick_at": "<now>"
}
```

## human-gates/_index.md

```markdown
# Human Gate Dashboard

## Open Gates

| ID | Question | Triggered By | Blocking? | Blocked Items | Created |
|----|----------|-------------|-----------|---------------|---------|
| — | (none) | — | — | — | — |

## Resolved Gates

| ID | Question | Chosen Option | Resolved At |
|----|----------|--------------|-------------|
| — | (none) | — | — |
```

## human-decision-request.json (template)

```json
{
  "id": "HDR-000",
  "created_at": null,
  "state_revision": null,
  "triggered_by": null,
  "state": "open",
  "question": null,
  "why_now": null,
  "context": null,
  "gate_criteria": {
    "irreversibility": null,
    "blast_radius": null,
    "product_meaning_change": null
  },
  "options": [],
  "recommended_option": null,
  "blocking": false,
  "blocked_work_items": [],
  "unblocked_work_items": [],
  "resume_target": null,
  "default_if_no_response": "continue_unblocked_work",
  "linked_escalations": [],
  "resolution": {
    "resolved_at": null,
    "chosen_option": null,
    "user_notes": null,
    "follow_up_actions": []
  }
}
```
