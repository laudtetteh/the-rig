#!/usr/bin/env bats
#
# tests/test_upgrade_agent_contract.bats — Coverage for the agent-driven
# upgrade contract added under issue #444 (lane 444-A): --strategy agent-plan
# and --strategy agent-upgrade.
#
# Run with: bats tests/test_upgrade_agent_contract.bats
#
# Both strategies reuse the exact same discovery/classification code path as
# --strategy upgrade (see install.sh's AGENT_DRY_RUN gating). agent-plan must
# never write to the target; agent-upgrade applies the same safe/convergeable
# actions as upgrade. Both emit one JSON document on stdout and refuse
# (status "refused", exit 3) whenever any file needs manual review.

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
  # Convenience wrapper mirroring tests/test_install.bats' run_installer:
  # always project-only, into TEST_PROJECT, with a fixed name and repo
  # tracking (keeps the fixture fully inside TEMP_DIR).
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# install.sh has a known, pre-existing, documented ordering issue (see this
# repo's own CLAUDE.md "Known gotchas": "`main` substitution runs after
# `write_manifest_entry`"): [BASE_BRANCH]/[Project Name] substitution runs
# AFTER the manifest hash is recorded for a file, so a handful of template
# files always show as "customized" after the very first install, even with
# zero real user edits. That is unrelated to the 444-A agent contract under
# test here. Stabilize the manifest for those known files to their actual
# post-substitution content so a test can construct a genuinely-unmodified
# fixture and isolate what this lane actually changed.
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

# Content+path snapshot of the whole target tree. Used to prove agent-plan
# performs zero writes: two snapshots taken before/after a run must be
# byte-for-byte identical (same files, same content, same names).
tree_snapshot() {
  find "$TEST_PROJECT" -type f | sort | xargs cksum
}

# Extracts the final JSON line from bats' $output (the agent contract always
# emits exactly one JSON document as the last line of stdout).
last_json_line() {
  printf '%s\n' "$output" | tail -1
}

# json_field <python-expression>  — expression must reference `d`, e.g.
# "d['status']" or "len(d['artifacts'])". Evaluates against the JSON on the
# final line of $output.
json_field() {
  printf '%s\n' "$output" | tail -1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)
"
}

@test "agent-plan on a fresh clean upgrade emits a valid success JSON plan with zero writes" {
  # Establish a real, unmodified install first (so the manifest baseline
  # matches every installed file exactly — the "fresh/clean" case).
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan
  [ "$status" -eq 0 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  [[ "$(last_json_line)" == \{* ]] || return 1
  [ "$(json_field "d['schema_version']")" = "1" ]
  [ "$(json_field "d['mode']")" = "plan" ]
  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "d['conflicts']")" = "[]" ]
  [ "$(json_field "len(d['artifacts'])")" != "0" ]
}

@test "agent-plan is idempotent after agent-upgrade in stealth tracking" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  run env HOME="$fake_home" bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking stealth \
    --strategy agent-upgrade \
    --project-agent claude
  [ "$status" -eq 0 ]

  local before after
  before="$(find "$TEST_PROJECT" "$fake_home" -type f | sort | xargs cksum)"

  run env HOME="$fake_home" bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking stealth \
    --strategy agent-plan \
    --project-agent claude
  [ "$status" -eq 0 ]

  after="$(find "$TEST_PROJECT" "$fake_home" -type f | sort | xargs cksum)"
  [ "$before" = "$after" ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "d['summary']['updated']")" = "0" ]
  [ "$(json_field "d['summary']['merged']")" = "0" ]
  [ "$(json_field "d['summary']['converged']")" = "0" ]
}

@test "agent-plan stdout is exactly one JSON document, not preflight narration followed by JSON (retro-audit finding, PR #446)" {
  # The documented contract (UPGRADE_WORKFLOW.md, and this PR's own code
  # comment) is "prints exactly one JSON document on stdout." The preflight
  # narrative summary ("Target matrix: ...", "Missing prerequisites: ...",
  # etc.) was gated only on JSON_OUTPUT (true only for the separate,
  # explicit --preflight --json mode) -- never on AGENT_MODE -- so it
  # always printed several lines of human-oriented text before the real
  # result on every agent-plan/agent-upgrade run. A caller doing
  # json.loads(stdout) on the first (or only) line would break.
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  run_installer --strategy agent-plan
  [ "$status" -eq 0 ]

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"Target matrix:"* ]] || return 1
  [[ "$output" != *"Missing prerequisites:"* ]] || return 1
  [[ "$output" == \{* ]] || return 1
}

@test "agent-plan stdout stays exactly one JSON document when gitleaks is missing (retro-audit finding, PR #446 follow-up)" {
  # The previous test proved the render-preflight.py narrative summary no
  # longer leaks ahead of the JSON. It missed a second, unrelated leak in
  # the same file: the GITLEAKS CHECK block's remediation lines ("Install
  # it: ...", "Docs: ...") were plain echo, never routed through the
  # warn()/blank() AGENT_MODE-gating convention the rest of that block
  # already uses. This is invisible on any machine that happens to have
  # gitleaks installed (including wherever the previous test normally
  # runs), which is exactly how it shipped undetected and then broke CI,
  # where gitleaks isn't installed. _RIG_TEST_MISSING_COMMANDS forces the
  # check to behave as if gitleaks is absent regardless of the actual
  # host, so this test is portable and doesn't depend on the machine's
  # actual gitleaks state.
  run env _RIG_TEST_MISSING_COMMANDS=gitleaks bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" --project-name "TestProject" --tracking repo \
    --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  run env _RIG_TEST_MISSING_COMMANDS=gitleaks bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" --project-name "TestProject" --tracking repo \
    --strategy agent-plan
  [ "$status" -eq 0 ]

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"Install it:"* ]] || return 1
  [[ "$output" != *"Docs: https://github.com/gitleaks"* ]] || return 1
  [[ "$output" == \{* ]] || return 1
}

@test "agent-plan on a convergeable customized file predicts convergence and still writes nothing" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # Tamper with a Rig-owned file after the manifest baseline was recorded —
  # its hash now differs from the manifest, making it "customized".
  #
  # Since issue #561 this file CONVERGES: a trusted base is proven from the
  # manifest hash, the incoming template is unchanged from that base, so only
  # the user's edit exists and it is simply kept. The zero-write assertion is
  # the point of this test — the AGENT_DRY_RUN guard inside the convergence
  # branch is now the only thing keeping agent-plan read-only for a file it
  # would otherwise rewrite.
  echo "# locally customized by the user" >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan
  [ "$status" -eq 0 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "'.claude/hooks/pre-tool.sh' in [a['path'] for a in d['artifacts'] if a['classification'] == 'converged']")" = "True" ]

  # The customized file itself must be untouched on disk.
  grep -q "locally customized by the user" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  run grep -q '^<<<<<<<' "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  [ "$status" -ne 0 ]
}

@test "agent-plan on a true conflict emits refused with populated conflicts, exits 3, and writes nothing" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local hook="$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"

  # A genuine conflict has to be constructed, not assumed: appending to a file
  # Rig did not otherwise change merges cleanly. Point the recorded baseline at
  # an older release, then rewrite exactly the region that differs between that
  # base and the incoming template, so all three sides touch it.
  local old_tag old_hash
  old_tag="$(git -C "$REPO_ROOT" tag --list 'v1.2*' | sort -V | head -1)"
  # A hard failure, not a skip. These are the only tests proving a genuine
  # three-way conflict still refuses with exit 3 rather than silently
  # converging; skipping them leaves CI green while proving nothing, which is
  # exactly what ci.yml's fetch-depth: 0 exists to prevent.
  [ -n "$old_tag" ] || { echo "no release tags reachable — fetch-depth: 0 required" >&2; return 1; }
  old_hash="$(git -C "$REPO_ROOT" show "$old_tag:templates/project/.claude/hooks/pre-tool.sh" 2>/dev/null | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  # `git show | shasum` emits the SHA of the EMPTY stream when git fails, so a
  # plain -n test can never fire. Check git's own exit status instead.
  git -C "$REPO_ROOT" cat-file -e "$old_tag:templates/project/.claude/hooks/pre-tool.sh" 2>/dev/null \
    || { echo "pre-tool.sh absent at $old_tag" >&2; return 1; }

  git -C "$REPO_ROOT" show "$old_tag:templates/project/.claude/hooks/pre-tool.sh" > "$hook"
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

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan
  [ "$status" -eq 3 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  [ "$(json_field "d['status']")" = "refused" ]
  [ "$(json_field "len(d['conflicts'])")" != "0" ]
  [ "$(json_field "'.claude/hooks/pre-tool.sh' in [c['path'] for c in d['conflicts']]")" = "True" ]
  [ "$(json_field "bool(d['conflicts'][0]['repair_guidance'])")" = "True" ]

  # The customized file itself must be untouched.
  grep -q "user rewrote this exact region" "$hook"
}

@test "agent-plan never writes .codex/config.toml, even with --project-agent codex (retro-audit finding, PR #446)" {
  # Every other direct-writer mutation in install.sh (.rig/VERSION,
  # .rigpath, CLAUDE.md/settings.json substitution, the stealth git-hook
  # install loop) is wrapped in an AGENT_DRY_RUN guard. The Codex project-
  # config merge (merge-codex-config.py, invoked whenever --project-agent
  # is codex/both) had no such guard at all -- agent-plan actually mutated
  # .codex/config.toml on disk, violating the documented "zero writes,
  # read-only" contract this whole file exists to prove.
  #
  # The merge is idempotent once CLAUDE.md is already in
  # project_doc_fallback_filenames, so a fixture starting from that already-
  # merged state would mask the bug: the second write reuses identical
  # bytes and a plain content snapshot can't tell a real skipped write from
  # a same-content rewrite. A real prior --project-agent both install is
  # still required first, so every other Codex artifact (.codex/hooks.json,
  # .codex/hooks/rig-adapter.sh, .agents/skills) exists and agent-plan's own
  # postflight smoke check passes -- then the merged config.toml is reset
  # to an unmerged state (simulating a pre-existing Codex config Rig hasn't
  # touched yet) so a real (buggy) merge would visibly change its content.
  run_installer --strategy upgrade --project-agent both
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline
  [ -f "$TEST_PROJECT/.codex/config.toml" ]

  printf 'model = "gpt-5"\n' > "$TEST_PROJECT/.codex/config.toml"

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan --project-agent both
  [ "$status" -eq 0 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]
  grep -q '^model = "gpt-5"$' "$TEST_PROJECT/.codex/config.toml"
  if grep -q 'project_doc_fallback_filenames' "$TEST_PROJECT/.codex/config.toml"; then return 1; fi
}

@test "agent-plan preserves Claude-only project metadata under a Codex runtime when selector is omitted" {
  # A release-pilot run from Codex should not implicitly retrofit Codex project
  # surfaces on a downstream project whose install-target metadata says Claude
  # only. Agent upgrade planning must classify the selected target, not the
  # coordinator's runtime.
  run_installer --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline
  [ ! -e "$TEST_PROJECT/.codex" ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"

  local before after
  before="$(tree_snapshot)"

  run env CODEX_THREAD_ID=codex-runtime bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    --strategy agent-plan
  [ "$status" -eq 0 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]
  [ "$(json_field "d['status']")" = "success" ]
  [ ! -e "$TEST_PROJECT/.codex" ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"
}

@test "agent-upgrade preserves user-owned PROJECT_BRIEF.md after accepted baseline" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local brief="$TEST_PROJECT/PROJECT_BRIEF.md"
  printf '# Project Brief: Real Product\n\nReal user-owned project details.\n' > "$brief"
  local brief_hash
  brief_hash="$(_sha256 "$brief")"
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  /usr/bin/grep -v '  PROJECT_BRIEF.md$' "$manifest" > "$manifest.tmp"
  printf '%s  PROJECT_BRIEF.md\n' "$brief_hash" >> "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  python3 - "$TEST_PROJECT/.rig/memory/.rig-manifest.json" "$brief_hash" <<'PY'
import json, sys
path, digest = sys.argv[1:]
with open(path) as fh:
    data = json.load(fh)
entry = data.setdefault("entries", {}).setdefault("PROJECT_BRIEF.md", {})
entry.update({
    "sha256": digest,
    "owner": "user",
    "source": "project-user",
    "type": "file",
    "mode": "644",
    "base_revision": data.get("installer_version", "0.0.0"),
    "installer_version": data.get("installer_version", "0.0.0"),
    "generator": "install.sh",
    "provider": "claude",
})
with open(path, "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]
  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "any(a['path'] == 'PROJECT_BRIEF.md' and a['classification'] == 'user-owned-preserved' for a in d['artifacts'])")" = "True" ]
  grep -q 'Real user-owned project details.' "$brief"
  run grep -q '\[What does this product do' "$brief"
  [ "$status" -ne 0 ]
}

@test "agent-upgrade preserves structurally user-owned PROJECT_BRIEF.md with legacy flat manifest only" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local brief="$TEST_PROJECT/PROJECT_BRIEF.md"
  local original_hash
  original_hash="$(_sha256 "$brief")"
  printf '# Project Brief: Legacy Product\n\nLegacy user details.\n' > "$brief"

  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  /usr/bin/grep -v '  PROJECT_BRIEF.md$' "$manifest" > "$manifest.tmp"
  printf '%s  PROJECT_BRIEF.md\n' "$original_hash" >> "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  python3 - "$TEST_PROJECT/.rig/memory/.rig-manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data.setdefault("entries", {}).pop("PROJECT_BRIEF.md", None)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]
  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "any(a['path'] == 'PROJECT_BRIEF.md' and a['classification'] == 'user-owned-preserved' for a in d['artifacts'])")" = "True" ]
  grep -q 'Legacy user details.' "$brief"
  run grep -q '\[What does this product do' "$brief"
  [ "$status" -ne 0 ]
}

@test "agent-plan preserves structurally user-owned memory files with legacy flat manifest only" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  local progress="$TEST_PROJECT/.rig/memory/PROGRESS.md"
  local original_hash
  original_hash="$(_sha256 "$progress")"
  printf '# Progress\n\nUser progress entry.\n' > "$progress"

  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  /usr/bin/grep -v '  .rig/memory/PROGRESS.md$' "$manifest" > "$manifest.tmp"
  printf '%s  .rig/memory/PROGRESS.md\n' "$original_hash" >> "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  python3 - "$TEST_PROJECT/.rig/memory/.rig-manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data.setdefault("entries", {}).pop(".rig/memory/PROGRESS.md", None)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

  run_installer --strategy agent-plan
  [ "$status" -eq 0 ]
  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "any(a['path'] == '.rig/memory/PROGRESS.md' and a['classification'] == 'user-owned-preserved' for a in d['artifacts'])")" = "True" ]
  grep -q 'User progress entry.' "$progress"
}

@test "agent-plan preserves externalized structurally user-owned memory files with legacy flat manifest only" {
  local fake_home="$TEMP_DIR/fake-home"
  mkdir -p "$fake_home"

  run env HOME="$fake_home" bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking stealth \
    --strategy upgrade
  [ "$status" -eq 0 ]

  local rig_dir="$fake_home/.rig/projects/TestProject"
  local progress="$rig_dir/memory/PROGRESS.md"
  local original_hash
  original_hash="$(_sha256 "$progress")"
  printf '# Progress\n\nExternal user progress entry.\n' > "$progress"

  local manifest="$rig_dir/memory/.rig-manifest"
  /usr/bin/grep -v '  .rig/memory/PROGRESS.md$' "$manifest" > "$manifest.tmp"
  printf '%s  .rig/memory/PROGRESS.md\n' "$original_hash" >> "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  python3 - "$rig_dir/memory/.rig-manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data.setdefault("entries", {}).pop(".rig/memory/PROGRESS.md", None)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

  run env HOME="$fake_home" bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking stealth \
    --strategy agent-plan
  [ "$status" -eq 0 ]
  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "any(a['path'] == '.rig/memory/PROGRESS.md' and a['classification'] == 'user-owned-preserved' for a in d['artifacts'])")" = "True" ]
  grep -q 'External user progress entry.' "$progress"
}

@test "agent-upgrade on a clean target applies updates and exits 0" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # A missing tracked artifact is always safe to (re)create — the simplest
  # reliable way to force a real "updated" action in agent-upgrade.
  rm -f "$TEST_PROJECT/.claude/commands/status.md"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  [ "$(json_field "d['status']")" = "success" ]
  [ "$(json_field "d['summary']['updated']")" != "0" ]
  [ -f "$TEST_PROJECT/.claude/commands/status.md" ]
}

@test "agent-upgrade on a target with a customized file applies safe updates but exits 3 refused and leaves it untouched" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # A true conflict has to be constructed. Since issue #561 a plain append
  # converges (the incoming template equals the proven base, so only the user
  # changed anything and their edit is kept) — which is correct, but would make
  # this test's exit-3 assertion vacuous. Point the recorded baseline at an
  # older release and rewrite exactly the region that differs from the incoming
  # template, so all three sides touch it.
  local hook="$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  local old_tag old_hash
  old_tag="$(git -C "$REPO_ROOT" tag --list 'v1.2*' | sort -V | head -1)"
  # A hard failure, not a skip. These are the only tests proving a genuine
  # three-way conflict still refuses with exit 3 rather than silently
  # converging; skipping them leaves CI green while proving nothing, which is
  # exactly what ci.yml's fetch-depth: 0 exists to prevent.
  [ -n "$old_tag" ] || { echo "no release tags reachable — fetch-depth: 0 required" >&2; return 1; }
  old_hash="$(git -C "$REPO_ROOT" show "$old_tag:templates/project/.claude/hooks/pre-tool.sh" 2>/dev/null | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  # `git show | shasum` emits the SHA of the EMPTY stream when git fails, so a
  # plain -n test can never fire. Check git's own exit status instead.
  git -C "$REPO_ROOT" cat-file -e "$old_tag:templates/project/.claude/hooks/pre-tool.sh" 2>/dev/null \
    || { echo "pre-tool.sh absent at $old_tag" >&2; return 1; }

  git -C "$REPO_ROOT" show "$old_tag:templates/project/.claude/hooks/pre-tool.sh" > "$hook"
  python3 - "$hook" "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" <<'PYEOF'
import difflib, sys
base_path, incoming_path = sys.argv[1:3]
with open(base_path) as fh:
    base = fh.readlines()
with open(incoming_path) as fh:
    incoming = fh.readlines()
matcher = difflib.SequenceMatcher(None, base, incoming, autojunk=False)
for tag, i1, i2, _, _ in matcher.get_opcodes():
    if tag in ("replace", "delete") and i2 > i1:
        base[i1:i2] = ["# locally customized by the user\n"]
        break
else:
    raise SystemExit("no differing region between base and incoming")
with open(base_path, "w") as fh:
    fh.writelines(base)
PYEOF
  python3 - "$TEST_PROJECT/.rig/memory/.rig-manifest" "$old_hash" <<'PYEOF'
import sys
manifest, old_hash = sys.argv[1:3]
suffix = "  .claude/hooks/pre-tool.sh"
out = []
for line in open(manifest):
    out.append("%s%s\n" % (old_hash, suffix) if line.rstrip("\n").endswith(suffix) else line)
open(manifest, "w").writelines(out)
PYEOF

  rm -f "$TEST_PROJECT/.claude/commands/status.md"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 3 ]

  [ "$(json_field "d['status']")" = "refused" ]
  [ "$(json_field "d['summary']['updated']")" != "0" ]
  [ "$(json_field "d['summary']['skipped_customized']")" != "0" ]

  # Safe/convergeable action was actually applied...
  [ -f "$TEST_PROJECT/.claude/commands/status.md" ]
  # ...but the customized file was never silently overwritten.
  grep -q "locally customized by the user" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
}

@test "agent-plan on a target with a future manifest base_revision emits refused, reports zero writes, and exits 3" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # Simulate a bogus/corrupted or future-installer-written manifest entry:
  # a base_revision newer than the installer currently running (issue #463).
  # Deliberately NOT CLAUDE.md/ship.md/post-merge.md/SHIP_WORKFLOW.md/
  # POST_MERGE_WORKFLOW.md — those 5 are the known "main substitution runs
  # after write_manifest_entry" files (see this repo's own CLAUDE.md "Known
  # gotchas"); agent-upgrade legitimately re-writes them even after
  # stabilize_substitution_baseline, which would reset our tampered
  # base_revision back to a real value before this test could observe it.
  # .claude/hooks/pre-tool.sh is a plain, stable Rig-owned file with no such
  # quirk, so it stays untouched by agent-upgrade unless genuinely flagged.
  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq '.entries[".claude/hooks/pre-tool.sh"].base_revision = "99.0.0"' "$metadata" > "$TEMP_DIR/future-metadata.json"
  mv "$TEMP_DIR/future-metadata.json" "$metadata"

  local before after
  before="$(tree_snapshot)"

  run_installer --strategy agent-plan
  [ "$status" -eq 3 ]

  after="$(tree_snapshot)"
  [ "$before" = "$after" ]

  [ "$(json_field "d['status']")" = "refused" ]
}

@test "agent-upgrade on a target with a future manifest base_revision refuses and exits 3, matching the fail-closed precedent" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  # See the agent-plan test above for why .claude/hooks/pre-tool.sh (not
  # CLAUDE.md) is used: it is not one of the 5 files affected by the
  # documented substitution-ordering quirk, so agent-upgrade's real write
  # path leaves its manifest entry (including our tampered base_revision)
  # untouched — this test needs the entry to survive an actual apply run.
  local metadata="$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  jq '.entries[".claude/hooks/pre-tool.sh"].base_revision = "99.0.0"' "$metadata" > "$TEMP_DIR/future-metadata.json"
  mv "$TEMP_DIR/future-metadata.json" "$metadata"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 3 ]
  [ "$(json_field "d['status']")" = "refused" ]
}

@test "agent-plan on an ordinary manifest (base_revision <= running installer) is unaffected by the future_revision check" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  run_installer --strategy agent-plan
  [ "$status" -eq 0 ]
  [ "$(json_field "d['status']")" = "success" ]
}

@test "existing --strategy upgrade behavior is unchanged by the agent contract" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline

  echo "# locally customized by the user" >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  rm -f "$TEST_PROJECT/.claude/commands/status.md"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  # Plain upgrade still exits 0 even when review is required (only the new
  # agent-* strategies gained exit code 3) and still prints the legacy
  # RIG_UPGRADE_REVIEW_REQUIRED marker instead of JSON.
  [[ "$output" == *"RIG_UPGRADE_REVIEW_REQUIRED=1"* ]] || return 1
  [[ "$output" != *'"schema_version"'* ]] || return 1
  [ -f "$TEST_PROJECT/.claude/commands/status.md" ]
  grep -q "locally customized by the user" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
}

@test "--help documents both new agent strategy values" {
  run bash "$INSTALLER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-plan"* ]] || return 1
  [[ "$output" == *"agent-upgrade"* ]] || return 1
}

@test "an unrecognized --strategy value still falls back to interactive, not agent mode" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy bogus-value < /dev/null
  [[ "$output" != *'"schema_version"'* ]] || return 1
}

# ── Issue #475: CHANGELOG BREAKING-bullet stdout leak ─────────────────────────
#
# _show_breaking_changes() prints each CHANGELOG "BREAKING" bullet via a raw,
# unguarded `echo` inside a while-loop -- unlike every other narrative helper
# in this file (warn/info/blank), which self-gate on AGENT_MODE. It runs
# unconditionally whenever COLLISION_STRATEGY==upgrade, which both
# agent-plan and agent-upgrade set internally, so any run against a target
# whose installed version has a BREAKING changelog entry ahead of it leaked
# these bullet lines onto stdout ahead of the documented single JSON
# document. This repo's own CHANGELOG.md has a real BREAKING section under
# [1.18.0], so this was concretely reachable, not just theoretical.

write_breaking_changelog_fixture() {
  cat > "$TEMP_DIR/fixture-changelog.md" <<'EOF'
# Changelog

## [1.18.0]

### Changed — BREAKING

- Some breaking change bullet one
- Some breaking change bullet two

## [1.17.0]

### Added

- something
EOF
}

@test "agent-plan stdout stays exactly one JSON document when the target has a BREAKING changelog entry ahead of its installed version (issue #475)" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline
  write_breaking_changelog_fixture
  printf '1.17.0\n' > "$TEST_PROJECT/.rig/VERSION"

  run env _RIG_TEST_CHANGELOG="$TEMP_DIR/fixture-changelog.md" \
    bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy agent-plan

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"Some breaking change bullet"* ]] || return 1
  [[ "$output" == \{* ]] || return 1
  [ "$(json_field "d['schema_version']")" = "1" ]
}

@test "agent-upgrade stdout stays exactly one JSON document when the target has a BREAKING changelog entry ahead of its installed version (issue #475)" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  stabilize_substitution_baseline
  write_breaking_changelog_fixture
  printf '1.17.0\n' > "$TEST_PROJECT/.rig/VERSION"

  run env _RIG_TEST_CHANGELOG="$TEMP_DIR/fixture-changelog.md" \
    bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy agent-upgrade

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"Some breaking change bullet"* ]] || return 1
  [[ "$output" == \{* ]] || return 1
  [ "$(json_field "d['schema_version']")" = "1" ]
}
