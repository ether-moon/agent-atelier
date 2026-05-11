#!/usr/bin/env bash
# init-helpers.sh — Bootstrap and migrate orchestration state files.
#
# Usage:
#   init-helpers.sh [--root <path>]
#
# Output: JSON to stdout: {"changed": bool, "created": [...], "migrated_keys": {...}, "wal_recovered": bool}
# Exit codes: 0 success, 3 no git root, 4 IO failure.

set -euo pipefail

ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo '{"error":"no_git_root"}' >&2; exit 3; }
fi

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$ROOT/.agent-atelier"

mkdir -p "$STATE_DIR/human-gates/open" "$STATE_DIR/human-gates/resolved" "$STATE_DIR/human-gates/templates" "$STATE_DIR/attempts" "$STATE_DIR/plan-conversations"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# WAL replay first so the wal_recovered field can be emitted in the composite
# JSON below. (The previous ordering printed JSON before replay, so consumers
# saw the documented wal_recovered field as undefined.)
WAL="$STATE_DIR/.pending-tx.json"
WAL_RECOVERED=false
if [ -f "$WAL" ]; then
  if "$PLUGIN_ROOT/scripts/state-commit" --root "$ROOT" --replay >/dev/null 2>&1; then
    WAL_RECOVERED=true
  fi
fi

# Extract default JSON blocks from state-defaults.md and merge missing top-level keys
python3 - "$PLUGIN_ROOT" "$STATE_DIR" "$NOW" "$WAL_RECOVERED" <<'PYEOF'
import sys, os, re, json

plugin_root, state_dir, now, wal_recovered_arg = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4],
)
wal_recovered = wal_recovered_arg == "true"
defaults_path = os.path.join(plugin_root, "references", "state-defaults.md")

# Parse JSON blocks under "## <filename>" headers
with open(defaults_path) as fh:
    text = fh.read()

blocks = {}
for m in re.finditer(r'^## ([\w.-]+\.json)\s*\n+```json\n(.*?)\n```', text, re.MULTILINE | re.DOTALL):
    name, body = m.group(1), m.group(2).replace('"<now>"', f'"{now}"')
    blocks[name] = json.loads(body)

results = {
    "changed": False,
    "created": [],
    "migrated_keys": {},
    "wal_recovered": wal_recovered,
}

for name, default_obj in blocks.items():
    if name == "human-decision-request.json":
        target = os.path.join(state_dir, "human-gates", "templates", name)
    elif name == "_index.md":
        continue  # markdown, handled below
    else:
        target = os.path.join(state_dir, name)

    if not os.path.exists(target):
        with open(target, "w") as fh:
            json.dump(default_obj, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        results["created"].append(os.path.relpath(target, state_dir))
        results["changed"] = True
    else:
        # Merge missing top-level keys (NEVER overwrite values, NEVER touch nested)
        with open(target) as fh:
            existing = json.load(fh)
        added = []
        for k, v in default_obj.items():
            if k not in existing:
                existing[k] = v
                added.append(k)
        if added:
            with open(target, "w") as fh:
                json.dump(existing, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            results["migrated_keys"][os.path.relpath(target, state_dir)] = added
            results["changed"] = True

# Bootstrap _index.md (markdown) only when missing
index_path = os.path.join(state_dir, "human-gates", "_index.md")
if not os.path.exists(index_path):
    m = re.search(r'^## human-gates/_index\.md\s*\n+```markdown\n(.*?)\n```', text, re.MULTILINE | re.DOTALL)
    if m:
        with open(index_path, "w") as fh:
            fh.write(m.group(1) + "\n")
        results["created"].append("human-gates/_index.md")
        results["changed"] = True

print(json.dumps(results, ensure_ascii=False))
PYEOF
