#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory" "$CASE_DIR/.claude/commands" "$CASE_DIR/.git/info" "$FAKE_BIN"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-path.py" "$CASE_DIR/bin/rig-path.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-sprint" "$CASE_DIR/bin/rig-sprint"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-snapshot.py" "$CASE_DIR/bin/rig-snapshot.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-tracker-config.py" "$CASE_DIR/bin/rig-tracker-config.py"
  chmod +x "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-sprint"
  printf '{"hooks":{}}\n' > "$CASE_DIR/.claude/settings.json"
  printf 'issue-tracking: none\n' > "$CASE_DIR/CLAUDE.md"
  printf 'issue-tracking: github\nissue-tracking: linear\nissue-tracking: trello\nissue-tracking: gus\nissue-tracking: none\n' > "$CASE_DIR/.claude/commands/task.md"
  cp "$CASE_DIR/.claude/commands/task.md" "$CASE_DIR/.claude/commands/rig-ship.md"
  printf 'hash .claude/commands/task.md\nhash .claude/commands/rig-ship.md\n' > "$CASE_DIR/.rig/memory/.rig-manifest"
  local launcher
  for launcher in "$CASE_DIR"/bin/*; do
    printf 'hash bin/%s\n' "${launcher##*/}" >> "$CASE_DIR/.rig/memory/.rig-manifest"
  done
  git -C "$CASE_DIR" init -q
  unset CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
}

json_assert() {
  JSON_OUTPUT="$output" python3 -c "$1"
}

make_generated_skill() {
  local name="$1" skill_dir="$CASE_DIR/.agents/skills/$1"
  mkdir -p "$skill_dir/references"
  cp "$CASE_DIR/.claude/commands/$name.md" "$skill_dir/references/command.md"
  printf '%s\n' '---' "name: $name" \
    "description: Run The Rig $name workflow for this repository." '---' '' \
    "# $name" '' \
    'Follow the complete workflow in [the command reference](references/command.md).' \
    > "$skill_dir/SKILL.md"
  if [ -f "$CASE_DIR/.rig/memory/.rig-manifest" ]; then
    printf 'hash .agents/skills/%s/references/command.md\n' "$name" >> "$CASE_DIR/.rig/memory/.rig-manifest"
  fi
}

assert_bounded_doctor_rejects() {
  local path="$1"
  run python3 - "$CASE_DIR" "$path" <<'PY'
import json, os, signal, subprocess, sys
project, path = sys.argv[1:]
process = subprocess.Popen([project + "/bin/rig", "doctor", "--json"], cwd=project,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                           start_new_session=True)
try:
    output, error = process.communicate(timeout=4)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.communicate()
    raise AssertionError("doctor blocked on " + path)
assert process.returncode == 1, (process.returncode, output, error)
checks = json.loads(output)["checks"]
unsafe = next(item for item in checks if item["name"] == "content_file_types")
assert unsafe["state"] == "fail" and path in unsafe["detail"], (path, unsafe)
PY
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

@test "doctor refuses named pipes in every content-reading skill surface" {
  make_generated_skill task
  make_generated_skill rig-ship
  mkdir -p "$CASE_DIR/.claude/skills/copied" "$CASE_DIR/.agents/skills/copied"
  printf 'source\n' > "$CASE_DIR/.claude/skills/copied/SKILL.md"
  printf 'mirror\n' > "$CASE_DIR/.agents/skills/copied/SKILL.md"
  local relative original
  for relative in .agents/skills/task/SKILL.md \
                  .agents/skills/task/references/command.md \
                  .claude/commands/task.md \
                  .agents/skills/copied/SKILL.md \
                  .claude/skills/copied/SKILL.md \
                  .claude/settings.json; do
    original="$BATS_TEST_TMPDIR/original-content-file"
    mv "$CASE_DIR/$relative" "$original"
    mkfifo "$CASE_DIR/$relative"
    assert_bounded_doctor_rejects "$relative"
    rm "$CASE_DIR/$relative"
    mv "$original" "$CASE_DIR/$relative"
  done
}

@test "doctor parity repair returns a refusal instead of blocking on a named pipe" {
  make_generated_skill task
  make_generated_skill rig-ship
  mv "$CASE_DIR/.agents/skills/task/SKILL.md" "$BATS_TEST_TMPDIR/original-wrapper"
  mkfifo "$CASE_DIR/.agents/skills/task/SKILL.md"
  run python3 - "$CASE_DIR" <<'PY'
import json, os, signal, subprocess, sys
project = sys.argv[1]
process = subprocess.Popen([project + "/bin/rig", "doctor", "fix", "--check",
                            "codex_skill_parity", "--json"], cwd=project,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                           start_new_session=True)
try:
    output, error = process.communicate(timeout=4)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.communicate()
    raise AssertionError("doctor parity repair blocked on a named pipe")
result = json.loads(output)
assert process.returncode == 3 and result["status"] == "refused", (process.returncode, result, error)
PY
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

@test "doctor refuses symlinked copied skill directories before reading outside content" {
  make_generated_skill task
  make_generated_skill rig-ship
  mkdir -p "$BATS_TEST_TMPDIR/outside" "$CASE_DIR/.claude/skills" "$CASE_DIR/.agents/skills/copied"
  printf 'outside content\n' > "$BATS_TEST_TMPDIR/outside/SKILL.md"
  printf 'mirror content\n' > "$CASE_DIR/.agents/skills/copied/SKILL.md"
  ln -s "$BATS_TEST_TMPDIR/outside" "$CASE_DIR/.claude/skills/copied"
  run env RIG_DOCTOR_PARITY_PLAN=1 "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["content_file_types"]["state"]=="fail" and ".claude/skills/copied" in c["content_file_types"]["detail"] and "symlink" in c["content_file_types"]["detail"]; assert "b3V0c2lkZSBjb250ZW50Cg==" not in os.environ["JSON_OUTPUT"]'
}

@test "doctor names a copied skill FIFO even when file lists differ" {
  mkdir -p "$CASE_DIR/.claude/skills/copied" "$CASE_DIR/.agents/skills/copied"
  printf 'source\n' > "$CASE_DIR/.claude/skills/copied/SKILL.md"
  printf 'extra\n' > "$CASE_DIR/.agents/skills/copied/notes.md"
  mkfifo "$CASE_DIR/.agents/skills/copied/SKILL.md"
  assert_bounded_doctor_rejects ".agents/skills/copied/SKILL.md"
}

@test "healthy doctor emits one JSON object and succeeds" {
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is True and d["command"] == "doctor"; c={x["name"]:x for x in d["checks"]}; assert all(c[n]["state"]=="skipped" for n in ("worktree_bootstrap","connector_declarations")); assert d["summary"]["skipped"] >= 2'

  run "$CASE_DIR/bin/rig" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  rig_directory:"* ]] || return 1
  [[ "$output" == *"Rig doctor: healthy"* ]] || return 1
}

@test "doctor skips dependent tracker guidance when command sources are missing" {
  rm "$CASE_DIR/.claude/commands/task.md" "$CASE_DIR/.claude/commands/rig-ship.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["claude_commands"]["state"]=="fail"; assert c["tracker_command_guidance"]["state"]=="skipped" and "task.md" in c["tracker_command_guidance"]["detail"]'
}

@test "doctor skips tracker-dependent checks when issue-tracking configuration is ambiguous" {
  printf 'issue-tracking: github\nissue-tracking: linear\n' > "$CASE_DIR/CLAUDE.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["issue_tracking"]["state"]=="fail"; assert all(c[n]["state"]=="skipped" for n in ("github_auth","tracker_command_guidance","recent_commit_references","recent_pr_references"))'
}

@test "doctor accepts a custom tracker and checks its commit references" {
  printf "issue-tracking: Jira # team\nissue-ref-pattern: '[A-Z]+-[0-9]+'\n" > "$CASE_DIR/CLAUDE.md"
  printf 'issue-ref-pattern:\n' >> "$CASE_DIR/.claude/commands/task.md"
  printf 'issue-ref-pattern:\n' >> "$CASE_DIR/.claude/commands/rig-ship.md"
  git -C "$CASE_DIR" -c user.name=Test -c user.email=test@example.test -c core.hooksPath=/dev/null commit --allow-empty -qm 'feat: valid [APP-123]'
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; c={x["name"]:x for x in json.loads(os.environ["JSON_OUTPUT"])["checks"]}; assert c["issue_tracking"]["state"]=="pass"; assert c["recent_commit_references"]["state"]=="pass"'
}

@test "Codex-only project does not fail checks for absent Claude artifacts" {
  rm -rf "$CASE_DIR/.claude"
  rm "$CASE_DIR/.rig/memory/.rig-manifest"
  printf '{"schema_version":1,"agents":["codex"]}\n' > "$CASE_DIR/.rig/install-targets.json"
  mkdir -p "$CASE_DIR/.codex"
  printf '{"hooks":{}}\n' > "$CASE_DIR/.codex/hooks.json"
  printf 'project_doc_fallback_filenames = ["CLAUDE.md"]\n' > "$CASE_DIR/.codex/config.toml"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert all(c[n]["state"]=="skipped" for n in ("claude_commands","codex_skill_parity","tracker_command_guidance")); assert c["settings_json"]["state"]==c["codex_project_instructions"]["state"]=="pass"'
}

@test "legacy manifest requires Claude settings when target metadata is absent or malformed" {
  rm "$CASE_DIR/.claude/settings.json"
  printf 'hash .claude/settings.json\nhash .claude/commands/task.md\nhash .claude/commands/rig-ship.md\n' > "$CASE_DIR/.rig/memory/.rig-manifest"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["settings_json"]["state"]=="fail" and ".claude/settings.json" in c["settings_json"]["detail"]; assert c["claude_commands"]["state"]=="pass"'

  printf '{broken\n' > "$CASE_DIR/.rig/install-targets.json"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["settings_json"]["state"]=="fail" and ".claude/settings.json" in c["settings_json"]["detail"]'
}

@test "invalid install-target metadata fails without treating Codex as unselected" {
  local payload
  for payload in '{broken' '{"schema_version":1,"agents":["unknown"]}' '{"agents":[]}'; do
    printf '%s\n' "$payload" > "$CASE_DIR/.rig/install-targets.json"
    run env CODEX_THREAD_ID=doctor-thread "$CASE_DIR/bin/rig" doctor --json
    [ "$status" -eq 1 ]
    json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["install_targets"]["state"]=="fail"; assert all(c[n]["state"]=="skipped" and "valid install-target" in c[n]["detail"] for n in ("codex_project_instructions","codex_project_target_runtime","codex_session_runtime"))'
  done
}

@test "Codex target without either manifest keeps source parity but leaves inventory advisory" {
  printf '{"schema_version":1,"agents":["codex"]}\n' > "$CASE_DIR/.rig/install-targets.json"
  rm "$CASE_DIR/.rig/memory/.rig-manifest"
  make_generated_skill task
  make_generated_skill rig-ship
  mkdir -p "$CASE_DIR/.codex"
  printf 'project_doc_fallback_filenames = ["CLAUDE.md"]\n' > "$CASE_DIR/.codex/config.toml"
  mkdir -p "$CASE_DIR/.agents/skills/extra"
  printf 'extra\n' > "$CASE_DIR/.agents/skills/extra/SKILL.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; c={x["name"]:x for x in json.loads(os.environ["JSON_OUTPUT"])["checks"]}; assert c["codex_skill_parity"]["state"]=="advisory" and "inventory" in c["codex_skill_parity"]["detail"]'

  printf '\nPARITY-DRIFT-CANARY\n' >> "$CASE_DIR/.agents/skills/task/references/command.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; c={x["name"]:x for x in json.loads(os.environ["JSON_OUTPUT"])["checks"]}; assert c["codex_skill_parity"]["state"]=="fail" and "task" in c["codex_skill_parity"]["detail"]'
}

@test "absent target metadata and manifests leave extra Codex inventory unverified" {
  make_generated_skill task
  make_generated_skill rig-ship
  rm "$CASE_DIR/.rig/memory/.rig-manifest"
  mkdir -p "$CASE_DIR/.agents/skills/rig-status/references"
  printf '%s\n' '---' 'name: rig-status' '---' > "$CASE_DIR/.agents/skills/rig-status/SKILL.md"
  printf 'status\n' > "$CASE_DIR/.agents/skills/rig-status/references/command.md"

  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; c={x["name"]:x for x in json.loads(os.environ["JSON_OUTPUT"])["checks"]}; assert c["codex_skill_parity"]["state"]=="advisory" and "inventory" in c["codex_skill_parity"]["detail"]'

  printf '\nPARITY-DRIFT-CANARY\n' >> "$CASE_DIR/.agents/skills/task/references/command.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; c={x["name"]:x for x in json.loads(os.environ["JSON_OUTPUT"])["checks"]}; assert c["codex_skill_parity"]["state"]=="fail" and "task" in c["codex_skill_parity"]["detail"]'
}

@test "a malformed manifest skips checks that depend on its entries" {
  printf '{bad\n' > "$CASE_DIR/.rig/memory/.rig-manifest.json"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["manifest_mode_hash"]["state"]=="fail"; assert c["stale_manifest_entries"]["state"]=="skipped" and "manifest" in c["stale_manifest_entries"]["detail"]'
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
  rm "$CASE_DIR/.claude/commands/rig-ship.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); failed={x["name"] for x in d["checks"] if not x["ok"]}; assert {"settings_json","claude_commands"} <= failed'
  [ "$(find "$CASE_DIR" -name '*.bak' -o -name '*.tmp' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "stealth path validates exclusions and future Codex paths only when detected" {
  local external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external/memory" "$CASE_DIR/.agents/skills/task" "$CASE_DIR/.agents/skills/rig-ship"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.rigpath\n' > "$CASE_DIR/.git/info/exclude"
  make_generated_skill task
  make_generated_skill rig-ship
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

  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' doctor fix --check worktree_bootstrap --json"
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["status"]=="preview" and d["check"]=="worktree_bootstrap" and "worktree bootstrap" in d["command"]'
  [ ! -e "$linked/.rigpath" ]
  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' doctor fix --check manifest_mode_hash --confirm --json"
  [ "$status" -eq 64 ]
  [ ! -e "$linked/.rigpath" ]
  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' doctor fix --check worktree_bootstrap --confirm --json"
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["status"]=="applied" and d["check"]=="worktree_bootstrap"'
  grep -q '^linked customization$' "$linked/CLAUDE.md"
  [ -f "$linked/.rigpath" ]
  [ -x "$linked/bin/rig" ]
  [ -x "$linked/bin/rig-sprint" ]
  [ -f "$linked/.claude/settings.json" ]
  [ -f "$linked/.gitleaks.toml" ]

  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="worktree_bootstrap"); assert c["ok"] and c["detail"]=="complete"'
  run bash -c "cd '$linked' && '$linked/bin/rig' sprint audit --all --json"
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] and d["command"]=="audit"'

  rm "$linked/bin/rig-sprint"
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="worktree_bootstrap"); assert not c["ok"] and "bin/rig-sprint" in c["detail"]'
  run bash -c "cd '$linked' && '$linked/bin/rig' worktree bootstrap"
  [ "$status" -eq 0 ]
  [ -x "$linked/bin/rig-sprint" ]

  rm "$linked/.gitleaks.toml"
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="worktree_bootstrap"); assert c["state"]=="fail" and ".gitleaks.toml" in c["detail"]'
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor fix --check worktree_bootstrap --json"
  [ "$status" -eq 0 ]
  [ ! -e "$linked/.gitleaks.toml" ]
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor fix --check worktree_bootstrap --confirm --json"
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["status"]=="applied"'
  [ -f "$linked/.gitleaks.toml" ]

  rm "$linked/bin/rig-snapshot.py"
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="worktree_bootstrap"); assert not c["ok"] and "bin/rig-snapshot.py" in c["detail"]'
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor fix --check worktree_bootstrap --confirm --json"
  [ "$status" -eq 0 ]
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 0 ]

  rm "$linked/bin/rig-snapshot.py"
  ln -s "$BATS_TEST_TMPDIR/outside-snapshot" "$linked/bin/rig-snapshot.py"
  run bash -c "cd '$linked' && '$linked/bin/rig' worktree bootstrap"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bin/rig-snapshot.py"* && "$output" == *"symlink"* ]] || return 1
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor fix --check worktree_bootstrap --confirm --json"
  [ "$status" -eq 1 ]
  [ -L "$linked/bin/rig-snapshot.py" ]
  [ ! -e "$BATS_TEST_TMPDIR/outside-snapshot" ]

  rm -rf "$linked/bin"
  mkdir -p "$BATS_TEST_TMPDIR/outside-bin"
  ln -s "$BATS_TEST_TMPDIR/outside-bin" "$linked/bin"
  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' worktree bootstrap"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]] || return 1
  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' doctor fix --check worktree_bootstrap --confirm --json"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/outside-bin/rig" ]
}

@test "linked Codex-only worktree requires present primary artifacts but not absent Claude assets" {
  local external="$BATS_TEST_TMPDIR/external-rig"
  local linked="$BATS_TEST_TMPDIR/linked"
  rm -rf "$CASE_DIR/.claude"
  mkdir -p "$external/memory" "$CASE_DIR/.codex" "$CASE_DIR/.agents/skills"
  local launcher
  for launcher in "$CASE_DIR"/bin/*; do
    printf 'hash bin/%s\n' "${launcher##*/}" >> "$external/memory/.rig-manifest"
  done
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf '{"hooks":{}}\n' > "$CASE_DIR/.codex/hooks.json"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.codex/\n.agents/\n.rigpath\n' > "$CASE_DIR/.git/info/exclude"
  printf 'seed\n' > "$CASE_DIR/README.md"
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" add README.md
  git -C "$CASE_DIR" commit -qm seed
  git -C "$CASE_DIR" worktree add -q -b linked-test "$linked"

  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' worktree bootstrap"
  [ "$status" -eq 0 ]
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="worktree_bootstrap"); assert c["state"]=="pass" and ".claude" not in c["detail"]'

  rm -rf "$linked/.codex"
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="worktree_bootstrap"); assert c["state"]=="fail" and ".codex" in c["detail"]'
}

@test "linked stealth worktree bootstrap restores session queries through an external .rigpath" {
  local external="$BATS_TEST_TMPDIR/external-rig"
  local linked="$BATS_TEST_TMPDIR/linked"
  local session_file="$external/memory/sessions/session-linked.json"
  export EXPECTED_SESSION_FILE="$session_file"
  mkdir -p "$external/memory/sessions"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.rigpath\nbin/rig\n' > "$CASE_DIR/.git/info/exclude"
  printf '%s\n' '{"anchor":"linked-session","status":"active","branch":"feat/linked"}' > "$session_file"
  printf 'seed\n' > "$CASE_DIR/README.md"
  git -C "$CASE_DIR" config user.email test@example.com
  git -C "$CASE_DIR" config user.name Test
  git -C "$CASE_DIR" add README.md
  git -C "$CASE_DIR" commit -qm seed
  git -C "$CASE_DIR" worktree add -q -b linked-test "$linked"

  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' worktree bootstrap"
  [ "$status" -eq 0 ]
  [ -f "$linked/bin/rig-session-resolve.py" ]
  run env RIG_SESSION_FILE="$session_file" "$linked/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] and d["anchor"]=="linked-session" and d["session_file"]==os.path.realpath(os.environ["EXPECTED_SESSION_FILE"])'

  rm "$linked/bin/rig-session-resolve.py"
  run bash -c "cd '$linked' && '$linked/bin/rig' doctor --json"
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="worktree_bootstrap"); assert not c["ok"] and "bin/rig-session-resolve.py" in c["detail"] and "worktree bootstrap" in c["detail"]'

  run bash -c "cd '$linked' && '$CASE_DIR/bin/rig' worktree bootstrap"
  [ "$status" -eq 0 ]
  run env RIG_SESSION_FILE="$session_file" "$linked/bin/rig" session resolve --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"anchor": "linked-session"'* ]] || return 1
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
  make_generated_skill task
  printf '%s\n' '---' > "$CASE_DIR/.agents/skills/unrelated/SKILL.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert "ship" in c["detail"] and "unrelated" in c["detail"]'
}

@test "Codex skill parity compares generated content with provider invocation and base-branch transforms" {
  printf 'base-branch: main\nissue-tracking: none\n' > "$CASE_DIR/CLAUDE.md"
  printf '# /task on [BASE_BRANCH]; use /rig-gaps; keep /not-a-rig-command\nissue-tracking: none\n' > "$CASE_DIR/.claude/commands/task.md"
  printf '# /rig-ship on [BASE_BRANCH]\nissue-tracking: none\n' > "$CASE_DIR/.claude/commands/rig-ship.md"
  make_generated_skill task
  make_generated_skill rig-ship
  printf '# $task on main; use $rig-gaps; keep /not-a-rig-command\nissue-tracking: none\n' > "$CASE_DIR/.agents/skills/task/references/command.md"
  printf '# $rig-ship on main\nissue-tracking: none\n' > "$CASE_DIR/.agents/skills/rig-ship/references/command.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert c["state"]=="pass"'

  printf '# $task on main; use $rig-gaps; keep $not-a-rig-command\nissue-tracking: none\n' > "$CASE_DIR/.agents/skills/task/references/command.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert c["state"]=="fail" and "task" in c["detail"]'
  printf '# $task on main; use $rig-gaps; keep /not-a-rig-command\nissue-tracking: none\n' > "$CASE_DIR/.agents/skills/task/references/command.md"

  printf '\nPARITY-DRIFT-CANARY\n' >> "$CASE_DIR/.claude/commands/rig-ship.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert c["state"]=="fail" and "ship" in c["detail"]'

  printf '# /rig-ship on [BASE_BRANCH]\nissue-tracking: none\n' > "$CASE_DIR/.claude/commands/rig-ship.md"
  printf '\nPARITY-DRIFT-CANARY\n' >> "$CASE_DIR/.agents/skills/rig-ship/SKILL.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert c["state"]=="fail" and "ship" in c["detail"] and "wrapper" in c["detail"]'
}

@test "Codex parity accepts a copied Claude skill as an intentional extra" {
  make_generated_skill task
  make_generated_skill rig-ship
  mkdir -p "$CASE_DIR/.claude/skills/custom" "$CASE_DIR/.agents/skills/custom" \
    "$CASE_DIR/.claude/skills/assets" "$CASE_DIR/.agents/skills/assets"
  printf '%s\n' '---' 'name: custom' '---' > "$CASE_DIR/.claude/skills/custom/SKILL.md"
  cp "$CASE_DIR/.claude/skills/custom/SKILL.md" "$CASE_DIR/.agents/skills/custom/SKILL.md"
  printf 'copied resource\n' > "$CASE_DIR/.claude/skills/assets/notes.txt"
  cp "$CASE_DIR/.claude/skills/assets/notes.txt" "$CASE_DIR/.agents/skills/assets/notes.txt"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert c["state"]=="pass" and "copied" in c["detail"]'

  printf '\nPARITY-DRIFT-CANARY\n' >> "$CASE_DIR/.agents/skills/custom/SKILL.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert c["state"]=="fail" and "copied skill drift: custom" in c["detail"]'
}

@test "copied Claude skill names are not allowed slash-command rewrites" {
  make_generated_skill task
  make_generated_skill rig-ship
  mkdir -p "$CASE_DIR/.claude/skills/foo" "$CASE_DIR/.agents/skills/foo"
  printf 'copied skill\n' > "$CASE_DIR/.claude/skills/foo/SKILL.md"
  cp "$CASE_DIR/.claude/skills/foo/SKILL.md" "$CASE_DIR/.agents/skills/foo/SKILL.md"
  printf 'Use /foo\n' >> "$CASE_DIR/.claude/commands/task.md"
  printf 'Use $foo\n' >> "$CASE_DIR/.agents/skills/task/references/command.md"

  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; c={x["name"]:x for x in json.loads(os.environ["JSON_OUTPUT"])["checks"]}; assert c["codex_skill_parity"]["state"]=="fail" and "task" in c["codex_skill_parity"]["detail"]'
}

@test "Codex parity is advisory when a generator base branch is unknowable" {
  printf '/task on [BASE_BRANCH]\nissue-tracking: none\n' > "$CASE_DIR/.claude/commands/task.md"
  make_generated_skill task
  make_generated_skill rig-ship
  printf '$task on main\nissue-tracking: none\n' > "$CASE_DIR/.agents/skills/task/references/command.md"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert c["state"]=="advisory" and "base-branch" in c["detail"]'
}

@test "stealth doctor detects divergent generated reference without changing either file" {
  local external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external/memory"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.agents/\n.rigpath\n' > "$CASE_DIR/.git/info/exclude"
  make_generated_skill task
  make_generated_skill rig-ship
  printf '\nPARITY-DRIFT-CANARY\n' >> "$CASE_DIR/.agents/skills/rig-ship/references/command.md"
  local before_source before_reference
  before_source="$(cksum "$CASE_DIR/.claude/commands/rig-ship.md")"
  before_reference="$(cksum "$CASE_DIR/.agents/skills/rig-ship/references/command.md")"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_skill_parity"); assert c["state"]=="fail" and "ship" in c["detail"]'
  [ "$before_source" = "$(cksum "$CASE_DIR/.claude/commands/rig-ship.md")" ]
  [ "$before_reference" = "$(cksum "$CASE_DIR/.agents/skills/rig-ship/references/command.md")" ]
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

@test "Codex runtime doctor skips Codex runtime gates when project target is Claude-only" {
  run env CODEX_THREAD_ID=doctor-thread "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["codex_project_target_runtime"]["ok"] and "not an installed project target" in c["codex_project_target_runtime"]["detail"]; assert c["codex_session_runtime"]["ok"] and "not required" in c["codex_session_runtime"]["detail"]'
}

@test "Codex-selected runtime doctor reports missing project target infrastructure and retrofit command" {
  printf '{"schema_version":1,"agents":["claude","codex"]}\n' > "$CASE_DIR/.rig/install-targets.json"
  run env CODEX_THREAD_ID=doctor-thread "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert not c["codex_project_target_runtime"]["ok"] and ".codex/hooks.json" in c["codex_project_target_runtime"]["detail"] and "--project-agent both" in c["codex_project_target_runtime"]["detail"]; assert not c["codex_session_runtime"]["ok"] and "session retrofit" in c["codex_session_runtime"]["detail"]'
}

@test "Codex runtime doctor reports malformed nested v1 records as JSON" {
  printf '{"schema_version":1,"agents":["claude","codex"]}\n' > "$CASE_DIR/.rig/install-targets.json"
  mkdir -p "$CASE_DIR/.rig/memory/sessions"
  printf '{"schema_version":1,"agent":"codex","native":"bad type","project":{"identity":"any"},"lifecycle":{"state":"active"}}\n' \
    > "$CASE_DIR/.rig/memory/sessions/session-malformed.json"
  run env CODEX_THREAD_ID=old-thread "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_session_runtime"); assert not c["ok"] and "session-malformed.json" in c["detail"] and "malformed" in c["detail"]'
  printf '{"schema_version":1,"agent":"codex","native":{"session_id":["bad"]},"project":{"identity":"any"},"lifecycle":{"state":"active"}}\n' \
    > "$CASE_DIR/.rig/memory/sessions/session-malformed.json"
  run env CODEX_THREAD_ID=old-thread "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="codex_session_runtime"); assert not c["ok"] and "session-malformed.json" in c["detail"] and "malformed" in c["detail"]'
}

@test "Codex runtime doctor passes after target infrastructure and current-thread binding exist" {
  printf '{"schema_version":1,"agents":["claude","codex"]}\n' > "$CASE_DIR/.rig/install-targets.json"
  mkdir -p "$CASE_DIR/.codex/hooks" "$CASE_DIR/.agents/skills/task" "$CASE_DIR/.agents/skills/rig-ship"
  printf '{"hooks":{}}\n' > "$CASE_DIR/.codex/hooks.json"
  printf 'project_doc_fallback_filenames = ["CLAUDE.md"]\n' > "$CASE_DIR/.codex/config.toml"
  printf '#!/usr/bin/env bash\n' > "$CASE_DIR/.codex/hooks/rig-adapter.sh"
  chmod +x "$CASE_DIR/.codex/hooks/rig-adapter.sh"
  make_generated_skill task
  make_generated_skill rig-ship

  run env CODEX_THREAD_ID=doctor-thread "$CASE_DIR/bin/rig" session retrofit --agent codex --from-env --source resume --json
  [ "$status" -eq 0 ]
  run env CODEX_THREAD_ID=doctor-thread "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["codex_project_target_runtime"]["ok"] and c["codex_session_runtime"]["ok"]'
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

  local base_branch
  base_branch="$(git -C "$CASE_DIR" branch --show-current)"
  git -C "$CASE_DIR" checkout -qb feature
  printf 'side\n' > "$CASE_DIR/side"
  git -C "$CASE_DIR" add side
  git -C "$CASE_DIR" commit -qm 'feat: side [#12]'
  git -C "$CASE_DIR" checkout -q "$base_branch"
  git -C "$CASE_DIR" merge --no-ff -qm 'Merge pull request #42 from example/feature' feature
  [ "$(git -C "$CASE_DIR" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" -eq 3 ]
  run env PATH="$FAKE_BIN:$PATH" "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; c={x["name"]:x for x in json.loads(os.environ["JSON_OUTPUT"])["checks"]}; assert c["recent_commit_references"]["state"]=="pass" and "merge" in c["recent_commit_references"]["detail"]'

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

@test "downstream doctor omits release-engineering gates whose tools never ship" {
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}
assert "manifest_provenance" not in c and "stealth_status" not in c and "idempotence" not in c
assert not any("#448" in x["detail"] or "#449" in x["detail"] or "test_install_idempotence" in x["detail"] for x in d["checks"])
assert c["manifest_mode_hash"]["ok"] and "no manifest metadata file" in c["manifest_mode_hash"]["detail"]
assert c["stale_manifest_entries"]["ok"] and "no manifest metadata file" in c["stale_manifest_entries"]["detail"]'
}

@test "doctor inside a Rig source checkout reports the idempotence test pointer" {
  mkdir -p "$CASE_DIR/tests"
  : > "$CASE_DIR/install.sh"
  : > "$CASE_DIR/tests/test_install_idempotence.bats"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}
assert c["idempotence"]["state"] == "skipped" and "test_install_idempotence.bats" in c["idempotence"]["detail"]'
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
  printf 'edited\n' > "$CASE_DIR/.claude/commands/rig-ship.md"
  local good_hash; good_hash="$(python3 -c "import hashlib; print(hashlib.sha256(open('$CASE_DIR/.claude/commands/task.md','rb').read()).hexdigest())")"
  cat > "$CASE_DIR/.rig/memory/.rig-manifest.json" <<EOF
{
  "schema_version": 1,
  "entries": {
    ".claude/commands/task.md": {"sha256": "$good_hash", "owner": "rig", "mode": "644"},
    ".claude/commands/rig-ship.md": {"sha256": "0000000000000000000000000000000000000000000000000000000000000000", "owner": "rig", "mode": "644"},
    "CLAUDE.md": {"sha256": "irrelevant-because-user-owned", "owner": "user", "mode": "644"}
  }
}
EOF
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c=next(x for x in d["checks"] if x["name"]=="manifest_mode_hash"); assert not c["ok"] and "rig-ship.md" in c["detail"] and "hash mismatch" in c["detail"] and "CLAUDE.md" not in c["detail"]'
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
  write_fixture_provenance_validator "$BATS_TEST_TMPDIR/installer-fixture"
  write_fixture_stealth_auditor "$BATS_TEST_TMPDIR/installer-fixture"
  export _RIG_INSTALLER_DIR="$BATS_TEST_TMPDIR/installer-fixture"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"])
names = {"manifest_provenance","stealth_status","manifest_mode_hash","stale_manifest_entries"}
present = {c["name"] for c in d["checks"]}
assert names <= present
for c in d["checks"]:
    assert set(c) in ({"name","ok","state","detail"}, {"name","ok","state","detail","fix"})
    assert c["state"] in ("pass","fail","skipped","advisory") and c["ok"] is (c["state"] != "fail")
    assert ("fix" in c) <= (c["state"] == "fail")
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
    assert set(c) in ({"name","ok","state","detail"}, {"name","ok","state","detail","fix"})
    assert c["state"] in ("pass","fail","skipped","advisory") and c["ok"] is (c["state"] != "fail")
    assert ("fix" in c) <= (c["state"] == "fail")
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

@test "external install requires only the .rigpath exclusion (#665)" {
  local external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external/memory"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$external/memory/.rig-manifest"
  printf '%s\n' "$external" > "$CASE_DIR/.rigpath"
  printf '.rigpath\n' > "$CASE_DIR/.git/info/exclude"
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" doctor --json
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert c["stealth_exclusions"]["state"] == "pass" and c["stealth_exclusions"]["detail"] == "external: complete", c["stealth_exclusions"]'

  : > "$CASE_DIR/.git/info/exclude"
  run env HOME="$BATS_TEST_TMPDIR/home" "$CASE_DIR/bin/rig" doctor --json
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; assert not c["stealth_exclusions"]["ok"] and c["stealth_exclusions"]["detail"] == "external: missing: .rigpath"'
}

@test "a Rig directory under ~/.rig/projects is checked as stealth even with no exclusions (#665)" {
  local home="$BATS_TEST_TMPDIR/home" stealth
  stealth="$home/.rig/projects/proj"
  mkdir -p "$stealth/memory"
  cp "$CASE_DIR/.rig/memory/.rig-manifest" "$stealth/memory/.rig-manifest"
  printf '%s\n' "$stealth" > "$CASE_DIR/.rigpath"
  : > "$CASE_DIR/.git/info/exclude"
  run env HOME="$home" "$CASE_DIR/bin/rig" doctor --json
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); c={x["name"]:x for x in d["checks"]}; x=c["stealth_exclusions"]; assert not x["ok"] and x["detail"].startswith("stealth: missing: CLAUDE.md, PROJECT_BRIEF.md, .claude, .rigpath"), x'
}
