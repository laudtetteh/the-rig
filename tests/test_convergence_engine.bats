#!/usr/bin/env bats
#
# tests/test_convergence_engine.bats — Coverage for the structure-aware and
# three-way convergence engine added under issue #444 (lane 444-C).
#
# Run with: bats tests/test_convergence_engine.bats
#
# Lane 444-A (--strategy agent-plan/agent-upgrade, tested in
# tests/test_upgrade_agent_contract.bats) refuses every customized file
# outright. This lane adds a real merge attempt before that refusal: JSON
# (installer/merge-json.py), TOML (installer/merge-toml.py), frontmatter+
# Markdown (installer/merge-frontmatter-markdown.py), and a plain-text
# fallback (installer/merge-text3way.py) that always reports a specific,
# actionable conflict rather than guessing. Only agent-plan/agent-upgrade are
# affected -- interactive/skip/overwrite/merge/plain upgrade are unchanged.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/test-project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email "test@test.com"
  git -C "$TEST_PROJECT" config user.name "Test"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

run_installer() {
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}

_sha256() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'
}

# Same known pre-existing ordering issue documented in
# tests/test_upgrade_agent_contract.bats and this repo's CLAUDE.md ("`main`
# substitution runs after `write_manifest_entry`"): stabilize the handful of
# affected files' manifest entries to their actual post-substitution content
# so a test can construct a genuinely-unmodified fixture. None of the files
# this test file tampers with (.codex/hooks.json, .claude/agents/code-
# reviewer.md, .gitleaks.toml, .claude/hooks/pre-tool.sh) are on that list,
# but the helper is kept for parity with the 444-A test file and in case a
# future test here needs it.
stabilize_substitution_baseline() {
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  local rel f
  for rel in CLAUDE.md .claude/commands/ship.md .claude/commands/post-merge.md \
             .rig/processes/POST_MERGE_WORKFLOW.md .rig/processes/SHIP_WORKFLOW.md; do
    f="$TEST_PROJECT/$rel"
    [[ -f "$f" ]] || continue
    grep -v "  ${rel}\$" "$manifest" > "$manifest.tmp"
    printf '%s  %s\n' "$(_sha256 "$f")" "$rel" >> "$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
  done
}

last_json_line() {
  printf '%s\n' "$output" | tail -1
}

json_field() {
  printf '%s\n' "$output" | tail -1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)
"
}

@test "agent-upgrade converges a JSON file when the customization and incoming template touch different keys" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local hooks="$TEST_PROJECT/.codex/hooks.json"
  [ -f "$hooks" ]
  # A brand-new top-level key is a pure addition -- the incoming template
  # (unchanged from what was just installed) never touches it, so there is
  # no colliding key and the merge should succeed cleanly.
  python3 -c "
import json
p = '$hooks'
data = json.load(open(p))
data['userCustomKey'] = 'kept-by-user'
json.dump(data, open(p, 'w'), indent=2)
"

  run_installer --strategy agent-upgrade --project-agent codex
  [ "$status" -eq 0 ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "d['summary']['converged']")" -ge 1 ]
  [ "$(json_field "'.codex/hooks.json' in [a['path'] for a in d['artifacts'] if a['classification'] == 'converged']")" = "True" ]

  # Byte-correct verification: the merged file is valid JSON that both kept
  # the user's addition AND still has the original "hooks" content intact.
  python3 -c "
import json
data = json.load(open('$hooks'))
assert data['userCustomKey'] == 'kept-by-user'
assert 'SessionStart' in data['hooks']
assert 'PreToolUse' in data['hooks']
"
}

@test "agent-plan reports the specific conflicting JSON key when customization and incoming touch the same key" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local hooks="$TEST_PROJECT/.codex/hooks.json"
  local original_description
  original_description="$(python3 -c "import json; print(json.load(open('$hooks'))['description'])")"

  # Change an EXISTING key's value. The incoming template still has the
  # original value for that same key -- current and incoming now disagree
  # on "description" with no trusted base to arbitrate, so this must be a
  # conflict, not a guess.
  python3 -c "
import json
p = '$hooks'
data = json.load(open(p))
data['description'] = 'locally customized description'
json.dump(data, open(p, 'w'), indent=2)
"

  run_installer --strategy agent-plan --project-agent codex
  [ "$status" -eq 3 ]

  [ "$(json_field "d['status']")" = "refused" ]
  local conflict_entry
  conflict_entry="$(json_field "next(c for c in d['conflicts'] if c['path'] == '.codex/hooks.json')")"
  [[ -n "$conflict_entry" ]]
  [ "$(json_field "any(x['path'] == 'description' for x in next(c for c in d['conflicts'] if c['path'] == '.codex/hooks.json')['details'])")" = "True" ]

  # agent-plan must never write -- the tampered value is still there.
  grep -q "locally customized description" "$hooks"
  [[ "$(python3 -c "import json; print(json.load(open('$hooks'))['description'])")" != "$original_description" ]]
}

@test "agent-upgrade converges a frontmatter+Markdown file when only a new frontmatter key was added" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local agent_file="$TEST_PROJECT/.claude/agents/code-reviewer.md"
  [ -f "$agent_file" ]
  local original_body
  original_body="$(sed -n '/^---$/,/^---$/!p' "$agent_file")"

  # Add a new frontmatter key without touching "name", "description", or the
  # prose body. The incoming template's frontmatter is unchanged, so this is
  # a pure addition on the current side only.
  python3 -c "
p = '$agent_file'
text = open(p).read()
marker = 'description:'
idx = text.index(marker)
end_of_line = text.index(chr(10), idx)
new_text = text[:end_of_line + 1] + 'tools: read\n' + text[end_of_line + 1:]
open(p, 'w').write(new_text)
"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "'.claude/agents/code-reviewer.md' in [a['path'] for a in d['artifacts'] if a['classification'] == 'converged']")" = "True" ]

  grep -q "^tools: read$" "$agent_file"
  grep -q "^name: code-reviewer$" "$agent_file"
  local merged_body
  merged_body="$(sed -n '/^---$/,/^---$/!p' "$agent_file")"
  [ "$merged_body" = "$original_body" ]
}

@test "agent-plan reports a body conflict for a frontmatter+Markdown file when the prose body was customized" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local agent_file="$TEST_PROJECT/.claude/agents/code-reviewer.md"
  echo "locally customized body content" >> "$agent_file"

  run_installer --strategy agent-plan
  [ "$status" -eq 3 ]

  [ "$(json_field "d['status']")" = "refused" ]
  local conflict_entry
  conflict_entry="$(json_field "next(c for c in d['conflicts'] if c['path'] == '.claude/agents/code-reviewer.md')")"
  [[ -n "$conflict_entry" ]]
  [ "$(json_field "any(x['path'] == 'body' for x in next(c for c in d['conflicts'] if c['path'] == '.claude/agents/code-reviewer.md')['details'])")" = "True" ]

  grep -q "locally customized body content" "$agent_file"
}

@test "agent-upgrade converges a TOML file when the customization adds a whole new table" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local gitleaks="$TEST_PROJECT/.gitleaks.toml"
  [ -f "$gitleaks" ]
  printf '\n[mycustom]\nkeepme = "yes"\n' >> "$gitleaks"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "'.gitleaks.toml' in [a['path'] for a in d['artifacts'] if a['classification'] == 'converged']")" = "True" ]

  grep -q '\[mycustom\]' "$gitleaks"
  grep -q 'keepme = "yes"' "$gitleaks"
  # The pre-existing [extend]/[allowlist] content must still be there.
  grep -q '\[extend\]' "$gitleaks"
  grep -q '\[allowlist\]' "$gitleaks"
}

@test "agent-plan reports specific line-range detail for a plain-text fallback conflict" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # .claude/hooks/pre-tool.sh has no known structure (not JSON/TOML/
  # frontmatter), so it must fall through to the plain-text three-way
  # fallback -- which has no trusted base in this lane and therefore always
  # conflicts on a real difference, but must say specifically where.
  echo "# locally customized by the user" >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy agent-plan
  [ "$status" -eq 3 ]

  [ "$(json_field "d['status']")" = "refused" ]
  local conflict_entry
  conflict_entry="$(json_field "next(c for c in d['conflicts'] if c['path'] == '.claude/hooks/pre-tool.sh')")"
  [[ -n "$conflict_entry" ]]
  [ "$(json_field "len(next(c for c in d['conflicts'] if c['path'] == '.claude/hooks/pre-tool.sh')['details'])")" != "0" ]
  [ "$(json_field "'lines' in next(c for c in d['conflicts'] if c['path'] == '.claude/hooks/pre-tool.sh')['details'][0]['path']")" = "True" ]
  [ "$(json_field "'locally customized by the user' in next(c for c in d['conflicts'] if c['path'] == '.claude/hooks/pre-tool.sh')['details'][0]['current']")" = "True" ]
}

@test "existing --strategy upgrade behavior is unchanged by the convergence engine" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  python3 -c "
import json
p = '$TEST_PROJECT/.codex/hooks.json'
data = json.load(open(p))
data['description'] = 'locally customized description'
json.dump(data, open(p, 'w'), indent=2)
"

  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]

  # Plain upgrade never invokes the convergence engine -- it still just
  # skips-with-review, still prints the legacy marker, still emits no JSON.
  [[ "$output" == *"RIG_UPGRADE_REVIEW_REQUIRED=1"* ]]
  [[ "$output" != *'"schema_version"'* ]]
  grep -q "locally customized description" "$TEST_PROJECT/.codex/hooks.json"
}
