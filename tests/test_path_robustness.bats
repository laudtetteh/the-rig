#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/My App & Co|O'Brien"
  TEST_RIG="$TEMP_DIR/Rig Data & | O'Brien"
  mkdir -p "$TEST_PROJECT" "$TEMP_DIR/home"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test
}

teardown() { rm -rf "$TEMP_DIR"; }

@test "shared Rig path reader preserves spaces and shell metacharacters" {
  printf '%s\n' "$TEST_RIG" > "$TEST_PROJECT/.rigpath"
  run python3 "$REPO_ROOT/templates/project/bin/rig-path.py" "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_RIG" ]
}

@test "special project and Rig paths survive install, hook rendering, and upgrade" {
  run env HOME="$TEMP_DIR/home" bash "$INSTALLER" --project-only \
    --project-agent both --target "$TEST_PROJECT" --project-name "My App & Co|O'Brien" \
    --tracking external --rig-dir "$TEST_RIG" --strategy merge
  [ "$status" -eq 0 ]
  [ -f "$TEST_RIG/memory/.rig-manifest" ]
  [ "$(python3 "$TEST_PROJECT/bin/rig-path.py" "$TEST_PROJECT")" = "$TEST_RIG" ]
  [ "$("$TEST_PROJECT/bin/rig" version --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')" != unknown ]

  run python3 - "$TEST_PROJECT" <<'PY'
import json, pathlib, shlex, sys
root = pathlib.Path(sys.argv[1])
settings = json.loads((root / '.claude/settings.json').read_text())
commands = [hook['command'] for groups in settings['hooks'].values() for group in groups for hook in group['hooks']]
assert commands
for command in commands:
    args = shlex.split(command)
    assert args[0] == 'bash'
    assert pathlib.Path(args[1]).is_file(), command
PY
  [ "$status" -eq 0 ]

  # Simulate a prior release's unquoted Rig hook registration. Upgrade must
  # replace it without leaving a duplicate broken command behind.
  python3 - "$TEST_PROJECT" "$TEMP_DIR" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
other = pathlib.Path(sys.argv[2]) / 'other-project/.claude/hooks/pre-tool.sh'
other.parent.mkdir(parents=True)
other.write_text('#!/bin/sh\n')
path = root / '.claude/settings.json'
settings = json.loads(path.read_text())
settings['hooks']['PreToolUse'][0]['hooks'][0]['command'] = 'bash ' + str(root) + '/.claude/hooks/pre-tool.sh'
settings['hooks']['PostToolUse'][0]['hooks'][0]['command'] = 'bash ' + str(root).replace('&', '[REPO_ROOT]') + '/.claude/hooks/post-tool.sh'
settings['hooks']['PreToolUse'].append({'matcher': '.*', 'hooks': [{'type': 'command', 'command': 'bash ' + str(other)}]})
path.write_text(json.dumps(settings, indent=2) + '\n')
PY

  run bash -c 'cd "$1" && HOME="$2" bash "$3" --project-only --project-agent both --target "$4" --strategy upgrade' \
    bash "$TEMP_DIR" "$TEMP_DIR/home" "$INSTALLER" "$(basename "$TEST_PROJECT")"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_PROJECT/.rigpath")" = "$TEST_RIG" ]
  [ -f "$TEST_RIG/memory/.rig-manifest" ]
  [ ! -e "${TEST_RIG// /}/memory/.rig-manifest" ]
  run python3 - "$TEST_PROJECT" "$TEMP_DIR" <<'PY'
import json, pathlib, shlex, sys
root = pathlib.Path(sys.argv[1])
other = pathlib.Path(sys.argv[2]) / 'other-project/.claude/hooks/pre-tool.sh'
settings = json.loads((root / '.claude/settings.json').read_text())
commands = [hook['command'] for groups in settings['hooks'].values() for group in groups for hook in group['hooks']]
for groups in settings['hooks'].values():
    event_commands = [hook['command'] for group in groups for hook in group['hooks']]
    assert len(event_commands) == len(set(event_commands)), event_commands
assert 'bash ' + str(other) in commands, commands
assert 'bash ' + str(root) + '/.claude/hooks/pre-tool.sh' not in commands, commands
assert not any('[REPO_ROOT]' in command for command in commands), commands
assert all(pathlib.Path(shlex.split(command)[1]).is_file() for command in commands)
PY
  [ "$status" -eq 0 ]
}

@test "special project name remains intact in the default stealth Rig directory" {
  run env HOME="$TEMP_DIR/home" bash "$INSTALLER" --project-only \
    --project-agent claude --target "$TEST_PROJECT" \
    --project-name "My App & Co|O'Brien" --tracking stealth --strategy merge
  [ "$status" -eq 0 ]
  expected="$TEMP_DIR/home/.rig/projects/My App & Co|O'Brien"
  [ "$(cat "$TEST_PROJECT/.rigpath")" = "$expected" ]
  [ -f "$expected/memory/.rig-manifest" ]
  grep -Fq "My App & Co|O'Brien" "$TEST_PROJECT/CLAUDE.md"
}

@test "pre-commit scans staged filenames containing spaces" {
  cp "$REPO_ROOT/templates/project/.gitleaks.toml" "$TEST_PROJECT/.gitleaks.toml"
  printf 'console.log("leftover");\n' > "$TEST_PROJECT/file with spaces.js" # rig-debug-ok
  git -C "$TEST_PROJECT" add -- "file with spaces.js"
  run sh -c 'cd "$1" && RIG_GITLEAKS_PATH_ONLY=1 sh "$2"' sh \
    "$TEST_PROJECT" "$REPO_ROOT/templates/project/.husky/pre-commit"
  [ "$status" -ne 0 ]
  [[ "$output" == *"file with spaces.js"* ]] || return 1
}

@test "pre-commit scans staged filenames Git would C-quote" {
  cp "$REPO_ROOT/templates/project/.gitleaks.toml" "$TEST_PROJECT/.gitleaks.toml"
  filename='file "quoted".js'
  printf 'console.log("leftover");\n' > "$TEST_PROJECT/$filename" # rig-debug-ok
  git -C "$TEST_PROJECT" add -- "$filename"
  run sh -c 'cd "$1" && RIG_GITLEAKS_PATH_ONLY=1 sh "$2"' sh \
    "$TEST_PROJECT" "$REPO_ROOT/templates/project/.husky/pre-commit"
  [ "$status" -ne 0 ]
  [[ "$output" == *"quoted"* ]] || return 1
  [[ "$output" == *"Debug artifact check blocked"* ]] || return 1
}

@test "rig CLI refuses malformed pointer before any stateful command" {
  mkdir -p "$TEST_PROJECT/bin"
  cp "$REPO_ROOT/templates/project/bin/rig" "$TEST_PROJECT/bin/rig"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$TEST_PROJECT/bin/rig-path.py"
  printf '%s\n%s\n' "$TEST_RIG" "$TEMP_DIR/other" > "$TEST_PROJECT/.rigpath"
  run bash "$TEST_PROJECT/bin/rig" memory append-progress --message check
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_PROJECT/memory" ]
  rm "$TEST_PROJECT/.rigpath"
  ln -s "$TEMP_DIR/missing" "$TEST_PROJECT/.rigpath"
  run bash "$TEST_PROJECT/bin/rig" memory append-progress --message check
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_PROJECT/memory" ]
}

@test "installer refuses malformed and dangling .rigpath before choosing storage" {
  printf '%s\n%s\n' "$TEST_RIG" "$TEMP_DIR/other" > "$TEST_PROJECT/.rigpath"
  run env HOME="$TEMP_DIR/home" bash "$INSTALLER" --project-only \
    --project-agent claude --target "$TEST_PROJECT" --strategy merge --preflight --json
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_PROJECT/.rig" ]
  rm "$TEST_PROJECT/.rigpath"
  ln -s "$TEMP_DIR/missing" "$TEST_PROJECT/.rigpath"
  run env HOME="$TEMP_DIR/home" bash "$INSTALLER" --project-only \
    --project-agent claude --target "$TEST_PROJECT" --strategy merge --preflight --json
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_PROJECT/.rig" ]
}

@test "pre-tool rejects malformed pointers before write policy" {
  mkdir -p "$TEST_PROJECT/bin" "$TEST_PROJECT/.claude/hooks"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$TEST_PROJECT/bin/rig-path.py"
  cp "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  printf '%s\n%s\n' "$TEST_RIG" "$TEMP_DIR/other" > "$TEST_PROJECT/.rigpath"
  payload='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/rig660-write.txt"}}'
  run bash -c 'printf "%s" "$1" | bash "$2"' bash "$payload" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"project .rigpath is invalid"* ]] || return 1
}

@test "pre-tool never executes a target worktree's path helper" {
  mkdir -p "$TEST_PROJECT/bin" "$TEST_PROJECT/.claude/hooks"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$TEST_PROJECT/bin/rig-path.py"
  cp "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  git -C "$TEST_PROJECT" commit --allow-empty -qm initial
  linked="$TEMP_DIR/linked"
  git -C "$TEST_PROJECT" worktree add -qb linked "$linked"
  mkdir -p "$linked/bin"
  sentinel="$TEMP_DIR/foreign-helper-ran"
  python3 - "$sentinel" "$linked/bin/rig-path.py" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[2]).write_text('from pathlib import Path\nPath(' + repr(sys.argv[1]) + ').touch()\n')
PY
  printf 'invalid\npointer\n' > "$linked/.rigpath"
  payload=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":sys.argv[1]}}))' "$linked/new.txt")
  run bash -c 'printf "%s" "$1" | bash "$2"' bash "$payload" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"write target .rigpath is invalid"* ]] || return 1
  [ ! -e "$sentinel" ]
}
