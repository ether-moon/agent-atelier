#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== Plugin Structure Tests ==="

# ── marketplace.json ─────────────────────────────────────────────────
if [ -f "$ROOT/.claude-plugin/marketplace.json" ]; then
  if python3 -c "import json; json.load(open('$ROOT/.claude-plugin/marketplace.json'))" 2>/dev/null; then
    pass "marketplace.json is valid JSON"
  else
    fail "marketplace.json is invalid JSON"
  fi
else
  fail "marketplace.json not found"
fi

# ── plugin.json ──────────────────────────────────────────────────────
PLUGIN_DIR=$(find "$ROOT/plugins" -name "plugin.json" -path "*/.claude-plugin/*" 2>/dev/null | head -1)
if [ -n "$PLUGIN_DIR" ]; then
  if python3 -c "import json; d=json.load(open('$PLUGIN_DIR')); assert 'name' in d; assert 'version' in d" 2>/dev/null; then
    pass "plugin.json has name and version"
  else
    fail "plugin.json missing required fields"
  fi
else
  fail "plugin.json not found under plugins/"
fi

# ── hooks.json ───────────────────────────────────────────────────────
HOOKS_FILE=$(find "$ROOT/plugins" -name "hooks.json" 2>/dev/null | head -1)
if [ -n "$HOOKS_FILE" ]; then
  if python3 -c "import json; json.load(open('$HOOKS_FILE'))" 2>/dev/null; then
    pass "hooks.json is valid JSON"
  else
    fail "hooks.json is invalid JSON"
  fi
else
  fail "hooks.json not found"
fi

# ── Hook type wiring ─────────────────────────────────────────────────
EXPECTED_HOOK_TYPES="UserPromptSubmit PreToolUse Stop SubagentStop"
for htype in $EXPECTED_HOOK_TYPES; do
  if python3 -c "import json; d=json.load(open('$HOOKS_FILE')); assert '$htype' in d['hooks']" 2>/dev/null; then
    pass "hook type '$htype' wired in hooks.json"
  else
    fail "hook type '$htype' missing from hooks.json"
  fi
done

# ── Hook script executability ────────────────────────────────────────
HOOK_SCRIPTS=$(python3 -c "
import json, os
d = json.load(open('$HOOKS_FILE'))
seen = set()
for entries in d['hooks'].values():
    for entry in entries:
        for h in entry.get('hooks', []):
            cmd = h.get('command', '')
            name = os.path.basename(cmd)
            if name and name not in seen:
                seen.add(name)
                print(name)
" 2>/dev/null)
HOOKS_DIR="$(dirname "$HOOKS_FILE")"
if [ -n "$HOOK_SCRIPTS" ]; then
  while IFS= read -r script_name; do
    script_path="$HOOKS_DIR/$script_name"
    if [ -f "$script_path" ] && [ -x "$script_path" ]; then
      pass "hook script '$script_name' exists and is executable"
    else
      fail "hook script '$script_name' not found or not executable at $script_path"
    fi
  done <<< "$HOOK_SCRIPTS"
else
  fail "No hook scripts extracted from hooks.json"
fi

# ── Skills frontmatter ───────────────────────────────────────────────
SKILLS=$(find "$ROOT/plugins" -name "SKILL.md" 2>/dev/null)
SKILL_COUNT=0
if [ -n "$SKILLS" ]; then
  while IFS= read -r skill; do
    rel=$(echo "$skill" | sed "s|$ROOT/||")
    if head -1 "$skill" | grep -q "^---"; then
      header=$(sed -n '1,/^---$/p' "$skill" | tail -n +2)
      if echo "$header" | grep -q "^name:"; then
        if echo "$header" | grep -q "^description:"; then
          pass "$rel has valid frontmatter"
          SKILL_COUNT=$((SKILL_COUNT + 1))
        else
          fail "$rel missing 'description' in frontmatter"
        fi
      else
        fail "$rel missing 'name' in frontmatter"
      fi
    else
      fail "$rel missing YAML frontmatter"
    fi
  done <<< "$SKILLS"
else
  fail "No SKILL.md files found"
fi

# ── Expected skills exist ────────────────────────────────────────────
EXPECTED_SKILLS="init status wi execute gate watchdog candidate validate run"
for skill_name in $EXPECTED_SKILLS; do
  skill_path="$ROOT/plugins/agent-atelier/skills/$skill_name/SKILL.md"
  if [ -f "$skill_path" ]; then
    pass "skill '$skill_name' exists"
  else
    fail "skill '$skill_name' not found at $skill_path"
  fi
done

# ── Reference files exist ────────────────────────────────────────────
EXPECTED_REFS="paths.md state-defaults.md wi-schema.md recovery-protocol.md success-metrics-routing.md"
for ref_name in $EXPECTED_REFS; do
  ref_path="$ROOT/plugins/agent-atelier/references/$ref_name"
  if [ -f "$ref_path" ]; then
    pass "reference '$ref_name' exists"
  else
    fail "reference '$ref_name' not found"
  fi
done

# ── Role prompt files ────────────────────────────────────────────────
PROMPTS_DIR="$ROOT/plugins/agent-atelier/references/prompts"
EXPECTED_PROMPTS="orchestrator state-manager pm architect builder vrm qa-reviewer ux-reviewer ui-designer aesthetic-ux-reviewer"
PROMPT_COUNT=0
for prompt_name in $EXPECTED_PROMPTS; do
  prompt_path="$PROMPTS_DIR/${prompt_name}.md"
  if [ -f "$prompt_path" ]; then
    pass "role prompt '${prompt_name}.md' exists"
    PROMPT_COUNT=$((PROMPT_COUNT + 1))
  else
    fail "role prompt '${prompt_name}.md' not found"
  fi
done
if [ "$PROMPT_COUNT" -eq 10 ]; then
  pass "total role prompt count = 10"
else
  fail "expected 10 role prompts, found $PROMPT_COUNT"
fi

# ── State defaults validation ────────────────────────────────────────
if [ -x "$ROOT/tests/schema_validation.sh" ]; then
  if "$ROOT/tests/schema_validation.sh" >/dev/null 2>&1; then
    pass "State default schemas are valid"
  else
    fail "State default schema validation failed"
  fi
else
  echo "  SKIP: tests/schema_validation.sh not found or not executable"
fi

# ── state-commit script ──────────────────────────────────────────────
COMMIT_SCRIPT=$(find "$ROOT/plugins" -name "state-commit" -path "*/scripts/*" -type f 2>/dev/null | head -1)
if [ -n "$COMMIT_SCRIPT" ] && [ -x "$COMMIT_SCRIPT" ]; then
  if "$COMMIT_SCRIPT" --help >/dev/null 2>&1 || true; then
    pass "state-commit script is executable"
  fi
else
  fail "state-commit script not found or not executable"
fi

# ── Mutation flow tests ──────────────────────────────────────────────
if [ -x "$ROOT/tests/mutation_flow.sh" ]; then
  if "$ROOT/tests/mutation_flow.sh" >/dev/null 2>&1; then
    pass "Mutation flow tests pass"
  else
    fail "Mutation flow tests failed"
  fi
else
  echo "  SKIP: tests/mutation_flow.sh not found or not executable"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed (${SKILL_COUNT} skills found)"
[ "$FAIL" -eq 0 ] || exit 1
