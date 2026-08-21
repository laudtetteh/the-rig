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

_sha256_stdin() {
  { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}'
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

@test "agent-upgrade preserves a customized JSON key the incoming template did not change" {
  run_installer --strategy upgrade --project-agent codex
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local hooks="$TEST_PROJECT/.codex/hooks.json"

  # Change an EXISTING key's value. Before issue #560 there was no trusted
  # base, so "current and incoming disagree" was reported as a conflict --
  # the engine could not tell who had changed it. With a base proven by hash,
  # incoming == base shows Rig never touched this key, so the user's value is
  # kept. That is a convergence, not a guess.
  python3 -c "
import json
p = '$hooks'
data = json.load(open(p))
data['description'] = 'locally customized description'
json.dump(data, open(p, 'w'), indent=2)
"

  run_installer --strategy agent-upgrade --project-agent codex
  [ "$status" -eq 0 ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "'.codex/hooks.json' in [a['path'] for a in d['artifacts'] if a['classification'] == 'converged']")" = "True" ]

  # The user's value survived and the rest of the document is intact.
  python3 -c "
import json
data = json.load(open('$hooks'))
assert data['description'] == 'locally customized description', data['description']
assert 'hooks' in data
"

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

@test "agent-upgrade converging a frontmatter+Markdown file preserves a user comment inside frontmatter (retro-audit finding, PR #452)" {
  # render()'s dict-mode reconstruction (merge-frontmatter-markdown.py) has
  # to parse frontmatter into a flat dict to merge it -- and dicts can't
  # represent comment/blank lines, so parse_fields() drops them. Previously
  # this reconstruction ran unconditionally on every successful merge,
  # silently deleting any comment a user added inside a command/agent
  # frontmatter block, reported as a clean "converged" success.
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local agent_file="$TEST_PROJECT/.claude/agents/code-reviewer.md"
  [ -f "$agent_file" ]

  # Add both a comment and a new key to the frontmatter -- the comment must
  # survive, and the new key must still be applied.
  python3 -c "
p = '$agent_file'
text = open(p).read()
marker = 'description:'
idx = text.index(marker)
end_of_line = text.index(chr(10), idx)
new_text = text[:end_of_line + 1] + '# note: do not remove this comment\ntools: read\n' + text[end_of_line + 1:]
open(p, 'w').write(new_text)
"
  grep -q '^# note: do not remove this comment$' "$agent_file"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]
  [ "$(json_field "'.claude/agents/code-reviewer.md' in [a['path'] for a in d['artifacts'] if a['classification'] == 'converged']")" = "True" ]

  grep -q '^# note: do not remove this comment$' "$agent_file"
  grep -q "^tools: read$" "$agent_file"
  grep -q "^name: code-reviewer$" "$agent_file"
}

@test "agent-upgrade converges a frontmatter+Markdown file whose prose body was customized" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local agent_file="$TEST_PROJECT/.claude/agents/code-reviewer.md"
  echo "locally customized body content" >> "$agent_file"

  # Before issue #561 the body was one atomic value, so any body edit refused
  # outright. With a proven base the body merges line-level: Rig did not touch
  # this document, so the user's addition is simply kept.
  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "'.claude/agents/code-reviewer.md' in [a['path'] for a in d['artifacts'] if a['classification'] == 'converged']")" = "True" ]

  grep -q "locally customized body content" "$agent_file"
  # The merged file must not carry conflict markers.
  run grep -q '^<<<<<<<' "$agent_file"
  [ "$status" -ne 0 ]
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

@test "agent-upgrade converges a customized shell hook through the plain-text path" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # .claude/hooks/pre-tool.sh has no known structure (not JSON/TOML/
  # frontmatter), so it falls through to the plain-text three-way path.
  echo "# locally customized by the user" >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "'.claude/hooks/pre-tool.sh' in [a['path'] for a in d['artifacts'] if a['classification'] == 'converged']")" = "True" ]

  grep -q "# locally customized by the user" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  run grep -q '^<<<<<<<' "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  [ "$status" -ne 0 ]
  # Executable mode must survive convergence -- a hook that loses +x is dead.
  [ -x "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]
}

@test "agent-plan still refuses when the user and the incoming template edited the same region" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local hook="$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"

  # Point the recorded baseline at this file's content in an older release, so
  # the resolved base genuinely differs from the incoming template -- the real
  # 4Culture shape. Then edit the same first lines the upstream change touched.
  local old_tag old_hash
  old_tag="$(git -C "$REPO_ROOT" tag --list 'v1.2*' | sort -V | head -1)"
  # A hard failure, not a skip. These are the only tests proving a genuine
  # three-way conflict still refuses with exit 3 rather than silently
  # converging; skipping them leaves CI green while proving nothing, which is
  # exactly what ci.yml's fetch-depth: 0 exists to prevent.
  [ -n "$old_tag" ] || { echo "no release tags reachable — fetch-depth: 0 required" >&2; return 1; }
  old_hash="$(git -C "$REPO_ROOT" show "$old_tag:templates/project/.claude/hooks/pre-tool.sh" 2>/dev/null | _sha256_stdin)"
  # `git show | shasum` emits the SHA of the EMPTY stream when git fails, so a
  # plain -n test can never fire. Check git's own exit status instead.
  git -C "$REPO_ROOT" cat-file -e "$old_tag:templates/project/.claude/hooks/pre-tool.sh" 2>/dev/null \
    || { echo "pre-tool.sh absent at $old_tag" >&2; return 1; }

  git -C "$REPO_ROOT" show "$old_tag:templates/project/.claude/hooks/pre-tool.sh" > "$hook"
  # Overlap has to be constructed, not assumed: editing arbitrary early lines
  # merges cleanly whenever the upstream change happens to sit elsewhere in the
  # file. Locate a region that genuinely differs between base and incoming, and
  # rewrite exactly that region locally so all three sides touch it.
  python3 - "$hook" "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" <<'PYEOF'
import difflib, sys
base_path, incoming_path = sys.argv[1:3]
with open(base_path) as fh:
    base = fh.readlines()
with open(incoming_path) as fh:
    incoming = fh.readlines()
matcher = difflib.SequenceMatcher(None, base, incoming, autojunk=False)
target = None
for tag, i1, i2, _, _ in matcher.get_opcodes():
    if tag in ("replace", "delete") and i2 > i1:
        target = (i1, i2)
        break
if target is None:
    raise SystemExit("no differing region between base and incoming")
start, end = target
base[start:end] = ["# user rewrote this exact region\n"]
with open(base_path, "w") as fh:
    fh.writelines(base)
PYEOF
  python3 - "$manifest" "$old_hash" <<'PYEOF'
import sys
manifest, old_hash = sys.argv[1:3]
out = []
for line in open(manifest):
    if line.rstrip("\n").endswith("  .claude/hooks/pre-tool.sh"):
        out.append("%s  .claude/hooks/pre-tool.sh\n" % old_hash)
    else:
        out.append(line)
open(manifest, "w").writelines(out)
PYEOF

  run_installer --strategy agent-plan
  [ "$status" -eq 3 ]

  [ "$(json_field "d['status']")" = "refused" ]
  [ "$(json_field "any(c['path'] == '.claude/hooks/pre-tool.sh' for c in d['conflicts'])")" = "True" ]
  # The refusal names the overlapping hunks, not a generic "customized".
  [ "$(json_field "len(next(c for c in d['conflicts'] if c['path'] == '.claude/hooks/pre-tool.sh')['details'])")" != "0" ]

  # agent-plan never writes.
  grep -q "user rewrote this exact region" "$hook"
}

@test "agent-plan reports missing tags as the historical-base refusal reason" {
  local no_tags_source="$TEMP_DIR/no-tags-source"
  git clone --quiet --no-tags --single-branch "$REPO_ROOT" "$no_tags_source"
  cp "$REPO_ROOT/install.sh" "$no_tags_source/install.sh"
  rm -rf "$no_tags_source/installer"
  cp -R "$REPO_ROOT/installer" "$no_tags_source/installer"
  [ "$(git -C "$no_tags_source" tag --list | wc -l | tr -d ' ')" = "0" ]

  run bash "$no_tags_source/install.sh" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    --strategy merge
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local hook="$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  local old_tag old_hash
  old_tag="$(git -C "$REPO_ROOT" tag --list 'v1.2*' | sort -V | head -1)"
  [ -n "$old_tag" ] || { echo "no release tags reachable — fetch-depth: 0 required" >&2; return 1; }
  git -C "$REPO_ROOT" cat-file -e "$old_tag:templates/project/.claude/hooks/pre-tool.sh" 2>/dev/null \
    || { echo "pre-tool.sh absent at $old_tag" >&2; return 1; }
  git -C "$REPO_ROOT" show "$old_tag:templates/project/.claude/hooks/pre-tool.sh" > "$hook"
  old_hash="$(_sha256 "$hook")"
  printf '\n# local customization on an old baseline\n' >> "$hook"

  python3 - "$manifest" "$old_hash" <<'PYEOF'
import sys
manifest, old_hash = sys.argv[1:3]
out = []
for line in open(manifest):
    if line.rstrip("\n").endswith("  .claude/hooks/pre-tool.sh"):
        out.append("%s  .claude/hooks/pre-tool.sh\n" % old_hash)
    else:
        out.append(line)
open(manifest, "w").writelines(out)
PYEOF

  run bash "$no_tags_source/install.sh" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    --strategy agent-plan
  [ "$status" -eq 3 ]

  [ "$(json_field "d['status']")" = "refused" ]
  [ "$(json_field "any('git fetch --tags' in item.get('current', '') for c in d['conflicts'] for item in c.get('details', []))")" = "True" ]
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
  [[ "$output" == *"RIG_UPGRADE_REVIEW_REQUIRED=1"* ]] || return 1
  [[ "$output" != *'"schema_version"'* ]] || return 1
  grep -q "locally customized description" "$TEST_PROJECT/.codex/hooks.json"
}
