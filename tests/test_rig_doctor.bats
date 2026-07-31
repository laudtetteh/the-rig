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
  [[ "$output" == *"PASS  rig_directory:"* ]]
  [[ "$output" == *"Rig doctor: healthy"* ]]
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

@test "adversarial rigpath and unknown option fail closed without execution" {
  printf '%s\n' '$(touch /tmp/rig-doctor-injected)' > "$CASE_DIR/.rigpath"
  run "$CASE_DIR/bin/rig" doctor --json
  [ "$status" -eq 1 ]
  [ ! -e /tmp/rig-doctor-injected ]
  run "$CASE_DIR/bin/rig" doctor --repair --json
  [ "$status" -eq 64 ]
  json_assert 'import json,os; assert json.loads(os.environ["JSON_OUTPUT"])["error"] == "usage"'
}
