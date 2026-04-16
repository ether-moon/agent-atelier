#!/bin/bash
set -euo pipefail

# UserPromptSubmit hook: injects additional context before each user prompt.
#
# Pattern: fast-exit when there's nothing to report, emit JSON when there is.
#
# Replace the condition and message below with your own logic.
# Common use cases:
#   - Remind the agent about a config/database it should query
#   - Warn about environment state (missing deps, wrong branch)
#   - Inject project-specific guidelines

# ── Fast exit: check your condition ──────────────────────────────────
# Example: exit early if a required file doesn't exist.
ROOT=""
if command -v git >/dev/null 2>&1; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi

if [ -z "$ROOT" ]; then
  exit 0
fi

# ── Collect signals and emit context if any are active ───────────────
python3 - "$ROOT" <<'PY' 2>/dev/null || true
import json, os, sys

state_dir = os.path.join(sys.argv[1], '.agent-atelier')
signals = []

# Signal 1: open gates
try:
    ls = json.load(open(os.path.join(state_dir, 'loop-state.json')))
    gates = ls.get('open_gates', [])
    if gates:
        signals.append(f'{len(gates)} open gate(s)')
    # Signal 2: active candidate set
    active_set = ls.get('active_candidate_set')
    if active_set:
        wi_ids = active_set.get('work_item_ids', [])
        set_id = active_set.get('id', 'unknown')
        if wi_ids:
            signals.append(f'active_candidate_set={set_id} ({", ".join(wi_ids)})')
        else:
            signals.append(f'active_candidate_set={set_id}')
except Exception:
    pass

# Signal 3: pending WAL
wal_path = os.path.join(state_dir, '.pending-tx.json')
if os.path.isfile(wal_path):
    signals.append('pending WAL — replay before mutating')

if signals:
    msg = 'agent-atelier active: ' + '; '.join(signals)
    json.dump({'additionalContext': msg}, sys.stdout)
    print()
PY

exit 0
