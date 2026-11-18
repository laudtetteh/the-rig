#!/usr/bin/env bats
#
# tests/test_rig_upgrade_snippets.bats — executes the shell snippets that
# /rig-upgrade and UPGRADE_WORKFLOW.md tell an agent to run (issue #663).
#
# Each test extracts one fenced ```bash block from the shipped markdown (by a
# marker string unique to that block) and runs it with /bin/bash against a
# throwaway git repository, so the documented commands are exercised exactly
# as written rather than re-implemented here.
#
# Run with: bats tests/test_rig_upgrade_snippets.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RIG_UPGRADE="$REPO_ROOT/templates/project/.claude/commands/rig-upgrade.md"
UPGRADE_WORKFLOW="$REPO_ROOT/templates/project/.rig/processes/UPGRADE_WORKFLOW.md"

setup() {
  TEST_TMP="$(mktemp -d)"
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1
  git config --global user.email "test@example.com"
  git config --global user.name "Test"
  git config --global init.defaultBranch main
  PROJECT="$TEST_TMP/project"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Print the first ```bash block in $1 that contains the literal marker $2.
_extract_block() {
  python3 - "$1" "$2" <<'PY'
import sys
path, marker = sys.argv[1:]
blocks, current = [], None
for line in open(path).read().splitlines():
    stripped = line.strip()
    if current is None and stripped.startswith("```bash"):
        current = []
    elif current is not None and stripped.startswith("```"):
        blocks.append("\n".join(current))
        current = None
    elif current is not None:
        current.append(line)
for block in blocks:
    if marker in block:
        print(block)
        sys.exit(0)
sys.exit("marker not found: " + marker)
PY
}

# Write a runnable script: a preamble of variable assignments plus the block.
_snippet_script() {
  local file="$1" marker="$2" preamble="$3" out="$TEST_TMP/snippet-$RANDOM.sh"
  { printf '%s\n' "$preamble"; _extract_block "$file" "$marker"; } > "$out"
  echo "$out"
}

_write_manifest_fixture() {
  local rig_dir="$1"
  mkdir -p "$rig_dir/memory"
  cat > "$rig_dir/memory/.rig-manifest" <<'EOF'
# The Rig manifest
1111111111111111111111111111111111111111111111111111111111111111  .claude/commands/ship.md
2222222222222222222222222222222222222222222222222222222222222222  .claude/hooks/pre-tool.sh
3333333333333333333333333333333333333333333333333333333333333333  .rig/processes/SHIP_WORKFLOW.md
4444444444444444444444444444444444444444444444444444444444444444  .rig/VERSION
EOF
  cat > "$rig_dir/memory/.rig-manifest.json" <<'EOF'
{"schema_version": 1, "entries": {
  ".claude/commands/ship.md": {"sha256": "1111111111111111111111111111111111111111111111111111111111111111", "owner": "rig"},
  ".claude/hooks/pre-tool.sh": {"sha256": "2222222222222222222222222222222222222222222222222222222222222222", "owner": "rig"}
}}
EOF
}

@test "rig-upgrade 2b-classic: manifest update rewrites only the exact path entry" {
  _write_manifest_fixture "$PROJECT/.rig"
  mkdir -p "$PROJECT/.claude/commands"
  printf 'accepted template\n' > "$PROJECT/.claude/commands/ship.md"
  local script
  script=$(_snippet_script "$RIG_UPGRADE" 'REL="$rel"' "RIG_DIR='$PROJECT/.rig'
rel='.claude/commands/ship.md'
installed_path='$PROJECT/.claude/commands/ship.md'
CUSTOMIZED_ACCEPTED=()")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  local expected
  expected=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$PROJECT/.claude/commands/ship.md")
  grep -qx "$expected  .claude/commands/ship.md" "$PROJECT/.rig/memory/.rig-manifest"
  grep -qx '2222222222222222222222222222222222222222222222222222222222222222  .claude/hooks/pre-tool.sh' "$PROJECT/.rig/memory/.rig-manifest"
  grep -qx '3333333333333333333333333333333333333333333333333333333333333333  .rig/processes/SHIP_WORKFLOW.md' "$PROJECT/.rig/memory/.rig-manifest"
  [ "$(grep -c '^[0-9a-f]' "$PROJECT/.rig/memory/.rig-manifest")" -eq 4 ]
  python3 - "$PROJECT/.rig/memory/.rig-manifest.json" "$expected" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["entries"][".claude/commands/ship.md"]["sha256"] == sys.argv[2]
assert data["entries"][".claude/hooks/pre-tool.sh"]["sha256"] == "2" * 64
PY
}

@test "rig-upgrade 3a: VERSION repair updates the external manifest entry" {
  local rig_dir="$HOME/.rig/projects/demo"
  _write_manifest_fixture "$rig_dir"
  local script
  script=$(_snippet_script "$RIG_UPGRADE" 'REL=".rig/VERSION"' "RIG_DIR='$rig_dir'
EXPECTED_VERSION='9.9.9'
INSTALLED_VERSION='1.0.0'
FIXED=()")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [ "$(cat "$rig_dir/VERSION")" = "9.9.9" ]
  local expected
  expected=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$rig_dir/VERSION")
  grep -qx "$expected  .rig/VERSION" "$rig_dir/memory/.rig-manifest"
  grep -qx '1111111111111111111111111111111111111111111111111111111111111111  .claude/commands/ship.md' "$rig_dir/memory/.rig-manifest"
}

_detect_tracking() {
  local script
  script=$(_snippet_script "$RIG_UPGRADE" 'TRACKING_ARGS=(--tracking "$TRACKING")' "REPO='$PROJECT'
INSTALLER_SRC='$REPO_ROOT'")
  printf 'echo "TRACKING=$TRACKING HOOKS=${HOOKS_DIR#$REPO/} ARGS=${TRACKING_ARGS[*]}"\n' >> "$script"
  /bin/bash "$script"
}

@test "rig-upgrade 1c: .rigpath under ~/.rig/projects is stealth even with .husky/" {
  mkdir -p "$HOME/.rig/projects/demo" "$PROJECT/.husky"
  echo "$HOME/.rig/projects/demo" > "$PROJECT/.rigpath"
  run _detect_tracking
  [ "$status" -eq 0 ]
  [ "$output" = "TRACKING=stealth HOOKS=.git/hooks ARGS=--tracking stealth --rig-dir $HOME/.rig/projects/demo" ]
}

@test "rig-upgrade 1c: .rigpath elsewhere is external even without .husky/" {
  mkdir -p "$TEST_TMP/shared-rig"
  echo "$TEST_TMP/shared-rig" > "$PROJECT/.rigpath"
  run _detect_tracking
  [ "$status" -eq 0 ]
  [ "$output" = "TRACKING=external HOOKS=.husky ARGS=--tracking external --rig-dir $TEST_TMP/shared-rig" ]
}

@test "rig-upgrade 1c: tracked .rig/ is repo and excluded .rig/ is local" {
  mkdir -p "$PROJECT/.rig"
  echo "1.0.0" > "$PROJECT/.rig/VERSION"
  git -C "$PROJECT" add .rig/VERSION
  run _detect_tracking
  [ "$output" = "TRACKING=repo HOOKS=.husky ARGS=--tracking repo" ]

  git -C "$PROJECT" rm -q --cached .rig/VERSION
  printf '.rig/\n' >> "$PROJECT/.git/info/exclude"
  run _detect_tracking
  [ "$output" = "TRACKING=local HOOKS=.husky ARGS=--tracking local" ]
}

@test "rig-upgrade 5a: staging skips ignored files, worktrees, and excluded .rig/" {
  printf '.rig/\n' >> "$PROJECT/.git/info/exclude"
  printf 'ignored-by-project.txt\n' > "$PROJECT/.gitignore"
  mkdir -p "$PROJECT/.rig/processes" "$PROJECT/.claude/commands" "$PROJECT/.claude/worktrees/wt" "$PROJECT/bin"
  echo base > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md .gitignore
  git -C "$PROJECT" commit -qm init
  echo cmd > "$PROJECT/.claude/commands/ship.md"
  echo '{}' > "$PROJECT/.claude/settings.local.json"
  echo proc > "$PROJECT/.rig/processes/SHIP_WORKFLOW.md"
  echo launcher > "$PROJECT/bin/rig"
  echo mine > "$PROJECT/bin/user-tool"
  git -C "$PROJECT/.claude/worktrees/wt" init -q
  echo user > "$PROJECT/notes.txt"
  local script
  script=$(_snippet_script "$RIG_UPGRADE" 'RIG_STAGE_CANDIDATES=(' "REPO='$PROJECT'
TRACKING=local")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  local staged
  staged=$(git -C "$PROJECT" diff --cached --name-only)
  echo "$staged" | grep -qx '.claude/commands/ship.md'
  echo "$staged" | grep -qx 'bin/rig'
  [[ "$staged" != *settings.local.json* ]] || false
  [[ "$staged" != *worktrees* ]] || false
  [[ "$staged" != *.rig/* ]] || false
  [[ "$staged" != *user-tool* ]] || false
  [[ "$staged" != *notes.txt* ]] || false
}

@test "rig-upgrade 2c: stealth hook check reports without overwriting a customized hook" {
  mkdir -p "$PROJECT/.git/hooks"
  printf '#!/bin/sh\n# customized\n' > "$PROJECT/.git/hooks/pre-commit"
  local before script
  before=$(cat "$PROJECT/.git/hooks/pre-commit")
  script=$(_snippet_script "$RIG_UPGRADE" 'echo "differs:    .git/hooks/$f"' "REPO='$PROJECT'
TRACKING=stealth
TEMPLATES='$REPO_ROOT/templates/project'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"differs:    .git/hooks/pre-commit"* ]] || false
  [ "$(cat "$PROJECT/.git/hooks/pre-commit")" = "$before" ]
}

@test "rig-upgrade 5: Codex mirror check honours opt-ins and runs on /bin/bash" {
  mkdir -p "$PROJECT/.claude/commands" "$PROJECT/.agents/skills"
  local script
  script=$(_snippet_script "$RIG_UPGRADE" 'CODEX_STAGE=$(mktemp -d)' "REPO='$PROJECT'
INSTALLER_SRC='$REPO_ROOT'
BASE_BRANCH=main")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing: .agents/skills/wrap/SKILL.md"* ]] || false
  [[ "$output" != *"doc-feature"* ]] || false
  [[ "$output" != *"rig-gaps"* ]] || false
  [ ! -e "$PROJECT/.agents/skills/wrap" ]

  touch "$PROJECT/.claude/commands/rig-gaps.md"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing: .agents/skills/rig-gaps/SKILL.md"* ]] || false
  [[ "$output" == *"missing: .agents/skills/rig-propose/SKILL.md"* ]] || false
  [[ "$output" != *"doc-feature"* ]] || false
}

@test "UPGRADE_WORKFLOW step 2: survey reports CHANGED and resolves stealth paths" {
  local rig_dir="$HOME/.rig/projects/demo"
  local tpl="$REPO_ROOT/templates/project"
  mkdir -p "$rig_dir/processes" "$PROJECT/.claude/hooks" "$PROJECT/.git/hooks"
  echo "$rig_dir" > "$PROJECT/.rigpath"
  printf 'base-branch: main\n' > "$PROJECT/CLAUDE.md"
  sed 's/\[BASE_BRANCH\]/main/g' "$tpl/.rig/processes/SHIP_WORKFLOW.md" > "$rig_dir/processes/SHIP_WORKFLOW.md"
  echo "locally edited" > "$rig_dir/processes/NEW_TASK_WORKFLOW.md"
  cp "$tpl/.husky/pre-commit" "$PROJECT/.git/hooks/pre-commit"
  cp "$tpl/.claude/hooks/stop.sh" "$PROJECT/.claude/hooks/stop.sh"
  echo "changed" > "$PROJECT/.claude/hooks/pre-tool.sh"
  local script
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'installed="$RIG_DIR/${src#.rig/}"' "export RIG_INSTALLER_SRC='$REPO_ROOT'
cd '$PROJECT'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"same:    .rig/processes/SHIP_WORKFLOW.md"* ]] || false
  [[ "$output" == *"CHANGED: .rig/processes/NEW_TASK_WORKFLOW.md"* ]] || false
  [[ "$output" == *"same:    .husky/pre-commit"* ]] || false
  [[ "$output" == *"same:    .claude/hooks/stop.sh"* ]] || false
  [[ "$output" == *"CHANGED: .claude/hooks/pre-tool.sh"* ]] || false
  [[ "$output" == *"MISSING: .rig/processes/POST_MERGE_WORKFLOW.md"* ]] || false
}
