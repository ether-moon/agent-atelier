"""Plan-level hashing helpers — used by state-commit and wi script.

Hash is stable against IMPLEMENT-phase status mutations (claim, heartbeat, etc.)
because lifecycle status is collapsed into status_class buckets.

Plan-affecting field set:
  id, title, description, depends_on, owned_paths, verify, complexity, status_class
"""
import hashlib
import json
import os

PLAN_FIELDS = ("id", "title", "description", "depends_on", "owned_paths", "verify", "complexity")

STATUS_CLASS = {
    "pending": "unstarted",
    "ready": "unstarted",
    "implementing": "in_progress_or_done",
    "candidate_queued": "in_progress_or_done",
    "candidate_validating": "in_progress_or_done",
    "reviewing": "in_progress_or_done",
    "done": "in_progress_or_done",
    "blocked_on_human_gate": "blocked",
}


def _canonicalize(items):
    """Reduce a list of WIs to plan-shape dicts, sorted by id."""
    canonical = []
    for wi in items:
        d = {f: wi.get(f) for f in PLAN_FIELDS}
        d["status_class"] = STATUS_CLASS.get(wi.get("status"), "unstarted")
        # Stable list ordering
        for k in ("depends_on", "owned_paths", "verify"):
            v = d.get(k)
            if isinstance(v, list):
                d[k] = sorted(v)
        canonical.append(d)
    canonical.sort(key=lambda x: x.get("id") or "")
    return canonical


def wi_plan_hash(items):
    """Compute SHA-256 of canonicalized plan-shape JSON. Returns 'sha256:<hex>'."""
    canonical = _canonicalize(items or [])
    payload = json.dumps(canonical, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    h = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    return f"sha256:{h}"


def spec_hash(path):
    """SHA-256 of a file. Returns 'sha256:<hex>' or string 'null' when missing."""
    if not os.path.exists(path):
        return "null"
    with open(path, "rb") as fh:
        h = hashlib.sha256(fh.read()).hexdigest()
    return f"sha256:{h}"
