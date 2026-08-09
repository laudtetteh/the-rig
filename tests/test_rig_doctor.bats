#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory" "$CASE_DIR/.claude/commands" "$CASE_DIR/.git/info" "$FAKE_BIN"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  chmod +x "$CASE_DIR/bin/rig"
  printf '{"hooks":{}}\n' > "$CASE_DIR/.claude/settings.json"
  printf 'issue-tracking: none\n' > "$CASE_DIR/CLAUDE.md"
  printf 'issue-tracking: github\nissue-tracking: linear\nissue-tracking: trello\nissue-tracking: gus\nissue-tracking: none\n' > "$CASE_DIR/.claude/commands/task.md"
  cp "$CASE_DIR/.claude/commands/task.md" "$CASE_DIR/.claude/commands/ship.md"
  printf 'hash .claude/commands/task.md\nhash .claude/commands/ship.md\n' > "$CASE_DIR/.rig/memory/.rig-manifest"
  git -C "$CASE_DIR" init -q
}

json_assert() {
  JSON_OUTPUT="$output" python3 -c "$1"
}

@test "healthy doctor emits one JSON object and succeeds" {
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is True and d["command"] == "doctor"'

  run "$CASE_DIR/bin/rig" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  rig_directory:"* ]] || return 1
  [[ "$output" == *"Rig doctor: healthy"* ]] || return 1
}

@test "doctor validates connector declarations without claiming session callability" {
  mkdir -p "$CASE_DIR/.rig/connectors"
  cp "$BATS_TEST_DIRNAME/../templates/project/.rig/connectors/skill-dependencies.v1.json" "$CASE_DIR/.rig/connectors/skill-dependencies.v1.json"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="connector_declarations"); assert c["ok"] and "session evidence required" in c["detail"]'
  printf '{bad\n' > "$CASE_DIR/.rig/connectors/skill-dependencies.v1.json"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
}

@test "invalid settings and missing manifest command fail diagnostically" {
  printf '{bad\n' > "$CASE_DIR/.claude/settings.json"
  rm "$CASE_DIR/.claude/commands/ship.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); failed={x["name"] for x in d["checks"] if not x["ok"]}; assert {"settings_json","claude_commands"} <= failed'
  [ "$(find "$CASE_DIR" -name '*.bak' -o -name '*.tmp' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "stealth path validates exclusions and future Codex paths only when detected" {
  local external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external/memory" "$CASE_DIR/.agents/skills/task" "$CASE_DIR/.agents/skills/ship"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.rigpath\n' > "$CASE_DIR/.git/info/exclude"
  printf '%s\n' '---' > "$CASE_DIR/.agents/skills/task/SKILL.md"
  printf '%s\n' '---' > "$CASE_DIR/.agents/skills/ship/SKILL.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert not c["stealth_exclusions"]["ok"] and ".agents" in c["stealth_exclusions"]["detail"]; assert c["codex_skill_parity"]["ok"]'
  printf '.agents/\n' >> "$CASE_DIR/.git/info/exclude"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
}

@test "linked stealth worktree doctor reports and bootstrap repairs without overwriting" {
  local external="$BATS_TEST_TMPDIR/external-rig"
  local linked="$BATS_TEST_TMPDIR/linked"
  mkdir -p "$external/memory"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.rigpath\n.gitleaks.toml\nbin/rig\n' > "$CASE_DIR/.git/info/exclude"
  printf 'secret config\n' > "$CASE_DIR/.gitleaks.toml"
  printf 'seed\n' > "$CASE_DIR/README.md"
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" add README.md
  git -C "$CASE_DIR" commit -qm seed
  git -C "$CASE_DIR" worktree add -q -b linked-test "$linked"

  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' doctor --json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"worktree bootstrap"* ]] || return 1
  printf 'linked customization\nissue-tracking: none\n' > "$linked/CLAUDE.md"

  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' worktree bootstrap"
  [ "$status" -eq 0 ]
  grep -q '^linked customization$' "$linked/CLAUDE.md"
  [ -f "$linked/.rigpath" ]
  [ -x "$linked/bin/rig" ]
  [ -f "$linked/.claude/settings.json" ]
  [ -f "$linked/.gitleaks.toml" ]

  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="worktree_bootstrap"); assert c["ok"] and c["detail"]=="complete"'
}

@test "worktree bootstrap: never copies .claude/worktrees/ into a linked worktree (self-recursion guard)" {
  printf '%s\n' "$BATS_TEST_TMPDIR/external-rig" > "$CASE_DIR/.rigpath"
  printf 'secret config\n' > "$CASE_DIR/.gitleaks.toml"
  printf 'seed\n' > "$CASE_DIR/README.md"
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" add README.md
  git -C "$CASE_DIR" commit -qm seed

  # A linked worktree living inside the primary's own .claude/worktrees/ is
  # this repo's real convention. Seed a sibling worktree dir there too --
  # both conditions together (worktree nested under .claude/, siblings
  # already present) are what made shutil.copytree walk into its own output
  # mid-copy and recurse with no base case (found live: ~110MB / 30+ nested
  # directory levels from a single bootstrap call).
  mkdir -p "$CASE_DIR/.claude/worktrees/sibling/.claude"
  git -C "$CASE_DIR" worktree add -q -b child-branch "$CASE_DIR/.claude/worktrees/child"

  run bash -c "cd '$CASE_DIR/.claude/worktrees/child' && '$CASE_DIR/bin/rig' worktree bootstrap"
  [ "$status" -eq 0 ]

  # The fix: never copy "worktrees" at all -- neither the sibling nor a
  # self-referential copy of the child's own destination.
  [ ! -e "$CASE_DIR/.claude/worktrees/child/.claude/worktrees" ]

  # Everything else the bootstrap is actually meant to restore still arrives.
  [ -f "$CASE_DIR/.claude/worktrees/child/.gitleaks.toml" ]
  [ -f "$CASE_DIR/.claude/worktrees/child/.rigpath" ]
  [ -x "$CASE_DIR/.claude/worktrees/child/bin/rig" ]
  [ -f "$CASE_DIR/.claude/worktrees/child/.claude/settings.json" ]
  [ -f "$CASE_DIR/.claude/worktrees/child/.claude/commands/task.md" ]
}

@test "Codex skill ambiguity is reported without guessing" {
  mkdir -p "$CASE_DIR/.agents/skills/task" "$CASE_DIR/.agents/skills/unrelated"
  printf '%s\n' '---' > "$CASE_DIR/.agents/skills/task/SKILL.md"
  printf '%s\n' '---' > "$CASE_DIR/.agents/skills/unrelated/SKILL.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert "ship" in c["detail"] and "unrelated" in c["detail"]'
}

@test "Codex target requires an effective project instruction source" {
  printf '{"schema_version":1,"agents":["codex"]}\n' > "$CASE_DIR/.rig/install-targets.json"
  mkdir -p "$CASE_DIR/.codex"
  printf 'project_doc_fallback_filenames = ["OTHER.md"]\n' > "$CASE_DIR/.codex/config.toml"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_project_instructions"); assert not c["ok"] and "no effective" in c["detail"]'

  printf 'project_doc_fallback_filenames = ["OTHER.md", "CLAUDE.md"]\n' > "$CASE_DIR/.codex/config.toml"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_project_instructions"); assert c["ok"] and "CLAUDE.md" in c["detail"]'
}

@test "native AGENTS files take precedence for Codex without being modified" {
  printf '{"schema_version":1,"agents":["codex"]}\n' > "$CASE_DIR/.rig/install-targets.json"
  printf 'native guidance\n' > "$CASE_DIR/AGENTS.override.md"
  before="$(cksum "$CASE_DIR/AGENTS.override.md")"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_project_instructions"); assert c["ok"] and "AGENTS.override.md takes precedence" == c["detail"]'
  [ "$before" = "$(cksum "$CASE_DIR/AGENTS.override.md")" ]
}

@test "Python 3.9 doctor rejects fallback nested under a project table" {
  printf '{"schema_version":1,"agents":["codex"]}\n' > "$CASE_DIR/.rig/install-targets.json"
  mkdir -p "$CASE_DIR/.codex"
  cat > "$CASE_DIR/.codex/config.toml" <<'EOF'
[projects."/tmp/example"]
trust_level = "trusted"
project_doc_fallback_filenames = ["CLAUDE.md"]
EOF
  run env _RIG_TEST_NO_TOMLLIB=1 "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_project_instructions"); assert not c["ok"] and "top-level" in c["detail"]'
}

@test "GitHub tracker uses safely stubbed auth and detects commit drift" {
  printf 'issue-tracking: github\n' > "$CASE_DIR/CLAUDE.md"
  cat > "$FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then exit "${FAKE_GH_STATUS:-0}"; fi
if [[ "$1 $2" == "pr list" ]]; then printf '%s\n' '[{"title":"feat: healthy","body":"Closes #12"}]'; exit 0; fi
exit 99
SH
  chmod +x "$FAKE_BIN/gh"
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" remote add origin git@github.com:example/project.git
  git -C "$CASE_DIR" add . && git -C "$CASE_DIR" commit -qm 'feat: healthy [#12]'
  run env PATH="$FAKE_BIN:$PATH" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["github_auth"]["ok"] and c["recent_commit_references"]["ok"] and c["recent_pr_references"]["ok"]'
  printf x > "$CASE_DIR/drift" && git -C "$CASE_DIR" add drift && git -C "$CASE_DIR" commit -qm 'feat: missing reference'
  run env PATH="$FAKE_BIN:$PATH" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert not next(x for x in d["checks"] if x["name"]=="recent_commit_references")["ok"]'
}

write_fixture_provenance_validator() {
  # Minimal stand-in for the real installer/validate-manifest-provenance.py
  # (444-B / #448): same CLI contract (positional metadata path arg), same
  # JSON shape and exit codes (0 ok, 1 malformed found, 2 unreadable/bad
  # schema). Doctor only depends on that contract, not the real script's
  # internals, so this fixture lets 444-H's gate be tested independently of
  # #448 landing.
  mkdir -p "$1"
  cat > "$1/validate-manifest-provenance.py" <<'PYEOF'
#!/usr/bin/env python3
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    print(json.dumps({"ok": False, "error": {"code": "manifest-unreadable", "message": str(exc)}}))
    sys.exit(2)
entries = data.get("entries", {})
malformed, legacy = [], []
known_providers = {"claude", "codex", "both", "none"}
for rel, entry in sorted(entries.items()):
    provider = entry.get("provider")
    if provider is not None and provider not in known_providers:
        malformed.append({"path": rel, "problems": [{"field": "provider", "reason": f"unrecognized value: {provider!r}"}]})
    elif all(entry.get(f) is None for f in ("base_revision", "generator", "provider")):
        legacy.append(rel)
ok = not malformed
print(json.dumps({"ok": ok, "checked": len(entries), "malformed": malformed, "legacy_provenance": legacy}))
sys.exit(0 if ok else 1)
PYEOF
}

write_fixture_stealth_auditor() {
  # Minimal stand-in for the real installer/audit-stealth.py (444-D / #449):
  # same CLI contract (positional target path arg), same JSON shape and exit
  # codes (0 ok/no-leak, 1 leak found, 2 not-a-git-repo). Doctor only depends
  # on that contract.
  mkdir -p "$1"
  cat > "$1/audit-stealth.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys
target = os.path.abspath(sys.argv[1])
if not os.path.isdir(os.path.join(target, ".git")):
    print(json.dumps({"ok": False, "error": {"code": "not-a-git-repo", "message": "not a git repo"}}))
    sys.exit(2)
if not os.path.exists(os.path.join(target, ".rigpath")):
    print(json.dumps({"ok": True, "target": target, "stealth": False, "message": "not a stealth install", "artifacts": []}))
    sys.exit(0)
leak_path = os.path.join(target, "bin", "rig-sprint")
leaks = []
if os.path.exists(leak_path):
    leaks.append({"path": "bin/rig-sprint", "status": "untracked_leak"})
print(json.dumps({"ok": not leaks, "target": target, "stealth": True, "artifacts": leaks, "leak_count": len(leaks)}))
sys.exit(0 if not leaks else 1)
PYEOF
}

@test "manifest provenance and stealth-status gates skip gracefully when tools are absent" {
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}
assert c["manifest_provenance"]["ok"] and "not present" in c["manifest_provenance"]["detail"]
assert c["stealth_status"]["ok"] and "not present" in c["stealth_status"]["detail"]
assert c["manifest_mode_hash"]["ok"] and "no manifest metadata file" in c["manifest_mode_hash"]["detail"]
assert c["stale_manifest_entries"]["ok"] and "no manifest metadata file" in c["stale_manifest_entries"]["detail"]
assert c["idempotence"]["ok"] and "test_install_idempotence.bats" in c["idempotence"]["detail"]'
}

@test "manifest provenance gate reports a malformed entry once the validator is present" {
  write_fixture_provenance_validator "$BATS_TEST_TMPDIR/installer-fixture"
  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<'EOF'
{
  "schema_version": 1,
  "entries": {
    "CLAUDE.md": {"sha256": "x", "owner": "user", "provider": "not-a-real-provider"},
    ".claude/commands/task.md": {"sha256": "x", "owner": "rig", "base_revision": "1.0.0", "generator": "install.sh", "provider": "claude"}
  }
}
EOF
  run env _RIG_INSTALLER_DIR="$BATS_TEST_TMPDIR/installer-fixture" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="manifest_provenance"); assert not c["ok"] and "CLAUDE.md" in c["detail"] and "provider" in c["detail"]'
}

@test "manifest provenance gate accepts legacy entries without failing" {
  write_fixture_provenance_validator "$BATS_TEST_TMPDIR/installer-fixture"
  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<'EOF'
{
  "schema_version": 1,
  "entries": {
    "CLAUDE.md": {"sha256": "x", "owner": "user"},
    ".claude/commands/task.md": {"sha256": "45a050504d3a25441a1882ab4ffdfd0de8c4c6e91ef82910f29986acbb8cf423", "owner": "rig", "mode": "644"}
  }
}
EOF
  run env _RIG_INSTALLER_DIR="$BATS_TEST_TMPDIR/installer-fixture" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="manifest_provenance"); assert c["ok"] and "legacy" in c["detail"]'
}

@test "manifest provenance gate detects a future base_revision using the real validator (issue #463)" {
  # Exercises the actual installer/validate-manifest-provenance.py (not the
  # fixture stand-in above) wired through doctor's --running-version arg, so
  # this covers a real consuming path end to end, not the validator alone.
  printf '1.0.0\n' > "$CASE_DIR/.rig/VERSION"
  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<'EOF'
{
  "schema_version": 1,
  "entries": {
    "CLAUDE.md": {"sha256": "x", "owner": "user", "base_revision": "99.0.0", "generator": "install.sh", "provider": "claude"},
    ".claude/commands/task.md": {"sha256": "x", "owner": "user", "base_revision": "1.0.0", "generator": "install.sh", "provider": "claude"}
  }
}
EOF
  run env _RIG_INSTALLER_DIR="$BATS_TEST_DIRNAME/../installer" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="manifest_provenance"); assert not c["ok"] and "future base_revision" in c["detail"] and "CLAUDE.md" in c["detail"] and "99.0.0" in c["detail"]'
}

@test "manifest provenance gate is unaffected by base_revision equal to or older than the installed VERSION (issue #463)" {
  printf '1.0.0\n' > "$CASE_DIR/.rig/VERSION"
  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<'EOF'
{
  "schema_version": 1,
  "entries": {
    "CLAUDE.md": {"sha256": "x", "owner": "user", "base_revision": "1.0.0", "generator": "install.sh", "provider": "claude"},
    ".claude/commands/task.md": {"sha256": "45a050504d3a25441a1882ab4ffdfd0de8c4c6e91ef82910f29986acbb8cf423", "owner": "rig", "mode": "644", "base_revision": "0.9.0", "generator": "install.sh", "provider": "claude"}
  }
}
EOF
  run env _RIG_INSTALLER_DIR="$BATS_TEST_DIRNAME/../installer" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="manifest_provenance"); assert c["ok"]'
}

@test "stealth-status gate reports an untracked launcher leak once the auditor is present" {
  write_fixture_stealth_auditor "$BATS_TEST_TMPDIR/installer-fixture"
  local external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external/memory"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.rigpath\nbin/rig\n' > "$CASE_DIR/.git/info/exclude"
  printf '#!/usr/bin/env bash\n' > "$CASE_DIR/bin/rig-sprint"
  run env _RIG_INSTALLER_DIR="$BATS_TEST_TMPDIR/installer-fixture" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="stealth_status"); assert not c["ok"] and "bin/rig-sprint" in c["detail"]'
}

@test "stealth-status gate passes clean when the auditor is present and finds no leaks" {
  write_fixture_stealth_auditor "$BATS_TEST_TMPDIR/installer-fixture"
  run env _RIG_INSTALLER_DIR="$BATS_TEST_TMPDIR/installer-fixture" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="stealth_status"); assert c["ok"] and "not a stealth install" in c["detail"]'
}

@test "manifest mode/hash drift is detected for rig-owned entries only" {
  printf 'edited\n' > "$CASE_DIR/.claude/commands/ship.md"
  local good_hash; good_hash="$(python3 -c "import hashlib; print(hashlib.sha256(open('$CASE_DIR/.claude/commands/task.md','rb').read()).hexdigest())")"
  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<EOF
{
  "schema_version": 1,
  "entries": {
    ".claude/commands/task.md": {"sha256": "$good_hash", "owner": "rig", "mode": "644"},
    ".claude/commands/ship.md": {"sha256": "0000000000000000000000000000000000000000000000000000000000000000", "owner": "rig", "mode": "644"},
    "CLAUDE.md": {"sha256": "irrelevant-because-user-owned", "owner": "user", "mode": "644"}
  }
}
EOF
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="manifest_mode_hash"); assert not c["ok"] and "ship.md" in c["detail"] and "hash mismatch" in c["detail"] and "CLAUDE.md" not in c["detail"]'
}

@test "manifest mode/hash gate fails instead of vacuously passing when entries exist but none are Rig-owned (retro-audit finding, PR #450)" {
  # An installed Rig project always has dozens of Rig-owned manifest
  # entries. A manifest with SOME entries but zero owner:rig ones is
  # suspicious -- e.g. an upgrade that only ever needed to record
  # user-owned hashes, never touching a single Rig-owned file that
  # session. Silently passing here would be the same "no evidence
  # recorded, so assume safe" anti-pattern already fixed elsewhere
  # (issue #470/#471) — this must fail, not pass vacuously.
  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<EOF
{
  "schema_version": 1,
  "entries": {
    "CLAUDE.md": {"sha256": "irrelevant-because-user-owned", "owner": "user", "mode": "644"}
  }
}
EOF
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="manifest_mode_hash"); assert not c["ok"] and "none are Rig-owned" in c["detail"]'
}

@test "stale manifest entries are reported for artifacts missing from disk" {
  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<'EOF'
{
  "schema_version": 1,
  "entries": {
    "bin/rig-vanished": {"sha256": "x", "owner": "rig", "mode": "755"}
  }
}
EOF
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="stale_manifest_entries"); assert not c["ok"] and "bin/rig-vanished" in c["detail"]'
}

@test "manifest mode/hash and stale-entry gates resolve .rig/-prefixed entries against the external stealth dir, not project root" {
  local external="$BATS_TEST_TMPDIR/external-rig-manifest"
  mkdir -p "$external/memory" "$external/processes"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.rigpath\n' > "$CASE_DIR/.git/info/exclude"
  printf 'workflow body\n' > "$external/processes/UPGRADE_WORKFLOW.md"
  local good_hash; good_hash="$(python3 -c "import hashlib; print(hashlib.sha256(open('$external/processes/UPGRADE_WORKFLOW.md','rb').read()).hexdigest())")"
  cat > "$external/memory/.rig-manifest.json" <<EOF
{
  "schema_version": 1,
  "entries": {
    ".rig/processes/UPGRADE_WORKFLOW.md": {"sha256": "$good_hash", "owner": "rig", "mode": "644"}
  }
}
EOF
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["manifest_mode_hash"]["ok"] and "UPGRADE_WORKFLOW" not in c["manifest_mode_hash"]["detail"]; assert c["stale_manifest_entries"]["ok"] and "no stale entries" in c["stale_manifest_entries"]["detail"]'

  rm "$external/processes/UPGRADE_WORKFLOW.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert not c["manifest_mode_hash"]["ok"] and ".rig/processes/UPGRADE_WORKFLOW.md: missing" in c["manifest_mode_hash"]["detail"]; assert not c["stale_manifest_entries"]["ok"] and ".rig/processes/UPGRADE_WORKFLOW.md" in c["stale_manifest_entries"]["detail"]'
}

@test "template_placeholder_content gate flags an unfilled CLAUDE.md/PROJECT_BRIEF.md core section" {
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="template_placeholder_content"); assert c["ok"] and "no unfilled" in c["detail"]'

  printf '# proj\n\n## What this project is\n\n[One paragraph: what it does, who it'"'"'s for, and why it exists.]\n' > "$CASE_DIR/CLAUDE.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="template_placeholder_content"); assert not c["ok"] and "CLAUDE.md" in c["detail"] and "lessons-learned" in c["detail"]'
}

@test "postflight gate JSON output stays schema-consistent across pass and fail states" {
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"])
names = {"manifest_provenance","stealth_status","manifest_mode_hash","stale_manifest_entries","idempotence"}
present = {c["name"] for c in d["checks"]}
assert names <= present
for c in d["checks"]:
    assert set(c) == {"name","ok","detail"}
    assert isinstance(c["ok"], bool) and isinstance(c["detail"], str)'

  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<'EOF'
{
  "schema_version": 1,
  "entries": {
    "bin/rig-vanished": {"sha256": "x", "owner": "rig", "mode": "755"}
  }
}
EOF
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"])
for c in d["checks"]:
    assert set(c) == {"name","ok","detail"}
    assert isinstance(c["ok"], bool) and isinstance(c["detail"], str)
assert d["ok"] is False'
}

@test "adversarial rigpath and unknown option fail closed without execution" {
  printf '%s\n' '$(touch /tmp/rig-doctor-injected)' > "$CASE_DIR/.rigpath"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  [ ! -e /tmp/rig-doctor-injected ]
  run "$CASE_DIR/bin/rig" doctor --repair --json
  [ "$status" -eq 64 ]
  json_assert 'import json,os; assert json.loads(os.environ["JSON_OUTPUT"])["error"] == "usage"'
}
