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

# Write a runnable script: strict mode, a preamble of variable assignments,
# then the block. Every snippet must survive `set -euo pipefail` on the
# stock macOS bash 3.2 the tests run it with.
_snippet_script() {
  local file="$1" marker="$2" preamble="$3" out="$TEST_TMP/snippet-$RANDOM.sh"
  { printf 'set -euo pipefail\n%s\n' "$preamble"; _extract_block "$file" "$marker"; } > "$out"
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
CUSTOMIZED_ACCEPTED=()
RIG_WRITTEN_PATHS=()")
  printf 'echo "accepted=${CUSTOMIZED_ACCEPTED[*]-}"\n' >> "$script"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted=.claude/commands/ship.md"* ]] || false
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

@test "rig-upgrade 2b-classic: manifest helper refuses an absent entry and a missing manifest" {
  _write_manifest_fixture "$PROJECT/.rig"
  mkdir -p "$PROJECT/.claude/commands"
  printf 'new\n' > "$PROJECT/.claude/commands/unlisted.md"
  cp "$PROJECT/.rig/memory/.rig-manifest" "$TEST_TMP/manifest-before"
  local script
  script=$(_snippet_script "$RIG_UPGRADE" 'REL="$rel"' "RIG_DIR='$PROJECT/.rig'
rel='.claude/commands/unlisted.md'
installed_path='$PROJECT/.claude/commands/unlisted.md'
CUSTOMIZED_ACCEPTED=()
RIG_WRITTEN_PATHS=()")
  printf 'echo "accepted=${#CUSTOMIZED_ACCEPTED[@]}"\n' >> "$script"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has no manifest entry"* ]] || false
  [[ "$output" == *"accepted=0"* ]] || false
  cmp -s "$TEST_TMP/manifest-before" "$PROJECT/.rig/memory/.rig-manifest"

  rm "$PROJECT/.rig/memory/.rig-manifest"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"error: manifest not found"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
  [[ "$output" == *"accepted=0"* ]] || false
}

@test "rig-upgrade 3a: VERSION repair updates the external manifest entry" {
  local rig_dir="$HOME/.rig/projects/demo"
  _write_manifest_fixture "$rig_dir"
  local script
  script=$(_snippet_script "$RIG_UPGRADE" 'REL=".rig/VERSION"' "RIG_DIR='$rig_dir'
EXPECTED_VERSION='9.9.9'
INSTALLED_VERSION='1.0.0'
FIXED=()
RIG_WRITTEN_PATHS=()")
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

@test "rig-upgrade 1c: a .rigpath containing spaces is read verbatim" {
  local rig_dir="$HOME/.rig/projects/live st"
  mkdir -p "$rig_dir"
  printf '%s\r\n' "$rig_dir" > "$PROJECT/.rigpath"
  run _detect_tracking
  [ "$status" -eq 0 ]
  [ "$output" = "TRACKING=stealth HOOKS=.git/hooks ARGS=--tracking stealth --rig-dir $rig_dir" ]
  local script
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'installed="$RIG_DIR/${src#.rig/}"' "cd '$PROJECT'")
  printf 'echo "RIG_DIR=$RIG_DIR"\n' >> "$script"
  run /bin/bash "$script"
  [[ "$output" == *"RIG_DIR=$rig_dir"* ]] || false
}

@test "rig-upgrade 1c: local mode is detected inside a linked worktree" {
  echo base > "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  git -C "$PROJECT" commit -qm init
  printf '.rig/\n' >> "$PROJECT/.git/info/exclude"
  git -C "$PROJECT" worktree add -q "$TEST_TMP/linked" -b linked
  mkdir -p "$TEST_TMP/linked/.rig"
  [ -f "$TEST_TMP/linked/.git" ]
  local saved="$PROJECT"
  PROJECT="$TEST_TMP/linked"
  run _detect_tracking
  PROJECT="$saved"
  [ "$status" -eq 0 ]
  [ "$output" = "TRACKING=local HOOKS=.husky ARGS=--tracking local" ]
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

_detect_base_branch() {
  local script
  script=$(_snippet_script "$RIG_UPGRADE" 'TRACKING_ARGS=(--tracking "$TRACKING")' "REPO='$PROJECT'
INSTALLER_SRC='$REPO_ROOT'")
  printf 'echo "BASE=$BASE_BRANCH"\n' >> "$script"
  /bin/bash "$script"
}

@test "rig-upgrade 1c: base branch comes from CLAUDE.md before origin/HEAD" {
  git -C "$PROJECT" commit -q --allow-empty -m initial
  git -C "$PROJECT" update-ref refs/remotes/origin/trunk HEAD
  git -C "$PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  run _detect_base_branch
  [ "$status" -eq 0 ]
  [ "$output" = "BASE=trunk" ]

  printf 'base-branch: release/v2  # integration\n' > "$PROJECT/CLAUDE.md"
  run _detect_base_branch
  [ "$status" -eq 0 ]
  [ "$output" = "BASE=release/v2" ]

  printf 'base-branch: [BASE_BRANCH]\n' > "$PROJECT/CLAUDE.md"
  run _detect_base_branch
  [ "$output" = "BASE=trunk" ]

  printf "base-branch: 'release/v2'\n" > "$PROJECT/CLAUDE.md"
  run _detect_base_branch
  [ "$status" -eq 0 ]
  [ "$output" = "BASE=release/v2" ]

  # Duplicates: no multi-line value and no origin/HEAD guess. BASE stays
  # empty so install.sh receives no usable flag and raises its own error.
  printf 'base-branch: develop\nbase-branch: main\n' > "$PROJECT/CLAUDE.md"
  run _detect_base_branch
  [ "$status" -eq 0 ]
  [[ "$output" == *"sets base-branch: more than once"* ]] || false
  [ "${lines[${#lines[@]}-1]}" = "BASE=" ]

  local duplicate
  for duplicate in $'base-branch: develop\nbase-branch:\n' \
                   $'base-branch:\nbase-branch: develop\n'; do
    printf '%s' "$duplicate" > "$PROJECT/CLAUDE.md"
    run _detect_base_branch
    [ "$status" -eq 0 ]
    [[ "$output" == *"sets base-branch: more than once"* ]] || false
    [ "${lines[${#lines[@]}-1]}" = "BASE=" ]
  done
}

_stage_fixture() {
  printf 'ignored-by-project.txt\n' > "$PROJECT/.gitignore"
  mkdir -p "$PROJECT/.rig/processes" "$PROJECT/.rig/memory" "$PROJECT/.claude/commands" \
    "$PROJECT/.claude/worktrees/wt" "$PROJECT/bin" "$PROJECT/.github"
  echo base > "$PROJECT/README.md"
  echo '{"hooks": {}}' > "$PROJECT/.claude/settings.json"
  echo 'user command' > "$PROJECT/.claude/commands/my-own.md"
  echo old > "$PROJECT/.claude/commands/ship.md"
  echo old > "$PROJECT/.rig/processes/SHIP_WORKFLOW.md"
  echo old > "$PROJECT/.rig/memory/.rig-manifest"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm init
  # Rig writes ...
  echo new > "$PROJECT/.claude/commands/ship.md"
  echo new > "$PROJECT/.rig/processes/SHIP_WORKFLOW.md"
  echo new > "$PROJECT/.rig/memory/.rig-manifest"
  echo template > "$PROJECT/.github/PULL_REQUEST_TEMPLATE.md"
  echo launcher > "$PROJECT/bin/rig"
  # ... and unrelated user state that must never be swept in.
  echo 'user edit' > "$PROJECT/.claude/commands/my-own.md"
  echo '{"hooks": {}, "mine": true}' > "$PROJECT/.claude/settings.json"
  echo '{}' > "$PROJECT/.claude/settings.local.json"
  echo mine > "$PROJECT/bin/user-tool"
  git -C "$PROJECT/.claude/worktrees/wt" init -q
  echo user > "$PROJECT/notes.txt"
}

_run_stage() {
  local script
  script=$(_snippet_script "$RIG_UPGRADE" '_rig_stage_candidate() {' "REPO='$PROJECT'
TRACKING=$1
RIG_WRITTEN_PATHS=(.claude/commands/ship.md .rig/processes/SHIP_WORKFLOW.md .github/PULL_REQUEST_TEMPLATE.md bin/rig .git/hooks/pre-commit)")
  /bin/bash "$script"
}

@test "rig-upgrade 5a: local mode stages only installer-written project files" {
  _stage_fixture
  printf '.rig/\n' >> "$PROJECT/.git/info/exclude"
  git -C "$PROJECT" rm -rq --cached .rig
  git -C "$PROJECT" commit -qm "untrack rig"
  run _run_stage local
  [ "$status" -eq 0 ]
  local staged
  staged=$(git -C "$PROJECT" diff --cached --name-only)
  [ "$staged" = "$(printf '.claude/commands/ship.md\n.github/PULL_REQUEST_TEMPLATE.md\nbin/rig')" ]
}

@test "rig-upgrade 5a: repo mode adds .rig/ writes and bookkeeping, never user edits" {
  _stage_fixture
  run _run_stage repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not staged"* ]] || false
  [[ "$output" == *".claude/commands/my-own.md"* ]] || false
  local staged
  staged=$(git -C "$PROJECT" diff --cached --name-only)
  echo "$staged" | grep -qx '.claude/commands/ship.md'
  echo "$staged" | grep -qx '.rig/processes/SHIP_WORKFLOW.md'
  echo "$staged" | grep -qx '.rig/memory/.rig-manifest'
  echo "$staged" | grep -qx '.github/PULL_REQUEST_TEMPLATE.md'
  [[ "$staged" != *my-own.md* ]] || false
  [[ "$staged" != *settings.json* ]] || false
  [[ "$staged" != *settings.local.json* ]] || false
  [[ "$staged" != *worktrees* ]] || false
  [[ "$staged" != *user-tool* ]] || false
  [[ "$staged" != *notes.txt* ]] || false
}

@test "UPGRADE_WORKFLOW step 7: stealth is detected before branching" {
  local rig_dir="$HOME/.rig/projects/demo"
  mkdir -p "$rig_dir"
  echo "$rig_dir" > "$PROJECT/.rigpath"
  local script
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'echo "Tracking mode: $TRACKING"' "cd '$PROJECT'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [ "$output" = "Tracking mode: stealth" ]
  local branch_line detect_line
  detect_line=$(grep -n 'echo "Tracking mode: $TRACKING"' "$UPGRADE_WORKFLOW" | cut -d: -f1)
  branch_line=$(grep -n 'git checkout -b chore/rig-upgrade-vX.Y.Z' "$UPGRADE_WORKFLOW" | cut -d: -f1)
  [ "$detect_line" -lt "$branch_line" ]
}

@test "UPGRADE_WORKFLOW step 7: stages exactly the files the installer log reports" {
  _stage_fixture
  local log
  log="$(git -C "$PROJECT" rev-parse --absolute-git-dir)/rig-upgrade.log"
  # Real install.sh styles: colourised, with and without a colon after the verb.
  printf '\033[0;32m✓\033[0m Updated: .claude/commands/ship.md\n' > "$log"
  printf '\033[0;32m✓\033[0m Created .github/PULL_REQUEST_TEMPLATE.md\n' >> "$log"
  printf '\033[0;32m✓\033[0m Created bin/rig\n' >> "$log"
  printf '\033[0;32m✓\033[0m Updated: .rig/processes/SHIP_WORKFLOW.md\n' >> "$log"
  printf '\033[0;32m✓\033[0m Created .rigpath → /somewhere/else\n' >> "$log"
  printf 'Updated: 3\n' >> "$log"
  local script
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'done < <(sed "s/${ESC}' "cd '$PROJECT'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  local staged
  staged=$(git -C "$PROJECT" diff --cached --name-only)
  [ "$staged" = "$(printf '.claude/commands/ship.md\n.github/PULL_REQUEST_TEMPLATE.md\n.rig/memory/.rig-manifest\n.rig/processes/SHIP_WORKFLOW.md\nbin/rig')" ]
  # Unrelated user edits under Rig-managed paths are listed, not staged.
  [[ "$output" == *"Not staged"* ]] || false
  [[ "$output" == *".claude/commands/my-own.md"* ]] || false
  [[ "$output" == *".claude/settings.json"* ]] || false
}

@test "UPGRADE_WORKFLOW step 7: refuses a missing or stale installer log" {
  _stage_fixture
  local script log
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'done < <(sed "s/${ESC}' "cd '$PROJECT'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No installer log"* ]] || false
  [ -z "$(git -C "$PROJECT" diff --cached --name-only)" ]

  log="$(git -C "$PROJECT" rev-parse --absolute-git-dir)/rig-upgrade.log"
  printf '\033[0;32m✓\033[0m Updated: .claude/commands/ship.md\n' > "$log"
  touch -t 202001010000 "$log"
  echo 9.9.9 > "$PROJECT/.rig/VERSION"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale log"* ]] || false
  [ -z "$(git -C "$PROJECT" diff --cached --name-only)" ]
}

@test "rig-upgrade 2a-classic: a real classic upgrade log stages created files" {
  local fixture="$REPO_ROOT/tests/fixtures/rig_upgrade_classic_v1.28.1.txt"
  # Recreate the project state behind the captured v1.28.1 -> current log:
  # every "Updated: <path>" file exists before the upgrade and is modified by
  # it; every "Created <path>" file is new.
  local plain updated created p
  plain=$(LC_ALL=C sed "s/$(printf '\033')\[[0-9;]*m//g" "$fixture")
  updated=$(printf '%s\n' "$plain" | LC_ALL=C sed -n 's/^.* Updated: \([^ ]*\)$/\1/p')
  created=$(printf '%s\n' "$plain" | LC_ALL=C sed -n 's/^.* Created \([^ ]*\)$/\1/p')
  [ -n "$updated" ]
  [ -n "$created" ]
  while IFS= read -r p; do
    mkdir -p "$PROJECT/$(dirname "$p")"; echo old > "$PROJECT/$p"
  done <<< "$updated"
  mkdir -p "$PROJECT/.claude/commands"
  echo '{"hooks": {}}' > "$PROJECT/.claude/settings.json"
  echo 'user command' > "$PROJECT/.claude/commands/my-own.md"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "v1.28.1 install"
  while IFS= read -r p; do echo new > "$PROJECT/$p"; done <<< "$updated"
  while IFS= read -r p; do
    mkdir -p "$PROJECT/$(dirname "$p")"; echo new > "$PROJECT/$p"
  done <<< "$created"
  echo '{"hooks": {"x": 1}}' > "$PROJECT/.claude/settings.json"
  echo 'user edit' >> "$PROJECT/.claude/commands/my-own.md"

  local script="$TEST_TMP/classic.sh"
  {
    printf 'set -euo pipefail\n'
    printf "REPO='%s'\nRIG_DIR='%s/.rig'\nTRACKING=repo\n" "$PROJECT" "$PROJECT"
    printf 'UPGRADED=()\nRIG_WRITTEN_PATHS=()\n'
    printf 'installer_output=$(cat %q)\n' "$fixture"
    _extract_block "$RIG_UPGRADE" 'plain_output=$(printf'
    _extract_block "$RIG_UPGRADE" '_rig_stage_candidate() {'
  } > "$script"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  local staged
  staged=$(git -C "$PROJECT" diff --cached --name-only)
  while IFS= read -r p; do
    echo "$staged" | grep -qxF "$p" || { echo "created file not staged: $p"; return 1; }
  done <<< "$created"
  while IFS= read -r p; do
    echo "$staged" | grep -qxF "$p" || { echo "updated file not staged: $p"; return 1; }
  done <<< "$updated"
  echo "$created" | grep -qx 'bin/rig-session-index.py'
  [[ "$staged" != *my-own.md* ]] || false
  [[ "$staged" != *settings.json* ]] || false
  [[ "$output" == *"Not staged"* ]] || false
  [[ "$output" == *".claude/settings.json"* ]] || false
  [[ "$output" == *".claude/commands/my-own.md"* ]] || false
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

@test "UPGRADE_WORKFLOW step 4: passes tracking args and surfaces installer failure" {
  local rig_dir="$HOME/.rig/projects/live st" fake="$TEST_TMP/fake installer"
  mkdir -p "$rig_dir" "$fake"
  echo "$rig_dir" > "$PROJECT/.rigpath"
  cat > "$fake/install.sh" <<'SH'
#!/bin/bash
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
exit 3
SH
  chmod +x "$fake/install.sh"
  local script log
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'INSTALL_STATUS=$(cat "$INSTALL_STATUS_FILE")' "export RIG_INSTALLER_SRC='$fake'
cd '$PROJECT'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[--tracking]"*"ARG[stealth]"*"ARG[--rig-dir]"*"ARG[$rig_dir]"* ]] || false
  [[ "$output" == *"ARG[--base-branch]"*"ARG[main]"* ]] || false
  [[ "$output" == *"install.sh exited 3"* ]] || false
  log="$(git -C "$PROJECT" rev-parse --absolute-git-dir)/rig-upgrade.log"
  [ -f "$log" ]
  [ -f "$log.failed" ]
}

@test "UPGRADE_WORKFLOW step 4: passes the configured base and omits it on duplicates" {
  local fake="$TEST_TMP/fake installer" script
  mkdir -p "$fake"
  printf '#!/bin/bash\nfor a in "$@"; do printf "ARG[%%s]\\n" "$a"; done\n' > "$fake/install.sh"
  chmod +x "$fake/install.sh"
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'INSTALL_STATUS=$(cat "$INSTALL_STATUS_FILE")' "export RIG_INSTALLER_SRC='$fake'
cd '$PROJECT'")

  printf 'base-branch: "release/v2"\n' > "$PROJECT/CLAUDE.md"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG[--base-branch]"*"ARG[release/v2]"* ]] || false

  printf 'base-branch: develop\nbase-branch: main\n' > "$PROJECT/CLAUDE.md"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ARG[--base-branch]"* ]] || false
  [[ "$output" == *"ARG[--target]"* ]] || false
}

@test "UPGRADE_WORKFLOW step 4: re-runs append to the log and clear the failure marker" {
  local fake="$TEST_TMP/fake installer" log
  mkdir -p "$fake"
  printf '#!/bin/bash\nprintf "\\033[0;32m✓\\033[0m Created bin/rig\\n"\n' > "$fake/install.sh"
  chmod +x "$fake/install.sh"
  local script
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'INSTALL_STATUS=$(cat "$INSTALL_STATUS_FILE")' "export RIG_INSTALLER_SRC='$fake'
cd '$PROJECT'")
  log="$(git -C "$PROJECT" rev-parse --absolute-git-dir)/rig-upgrade.log"
  touch "$log.failed"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  printf '#!/bin/bash\nprintf "\\033[0;32m✓\\033[0m Up to date: bin/rig\\n"\n' > "$fake/install.sh"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  grep -q 'Created bin/rig' "$log"
  grep -q 'Up to date: bin/rig' "$log"
  [ ! -e "$log.failed" ]
}

@test "UPGRADE_WORKFLOW step 7: refuses when the last installer run failed" {
  _stage_fixture
  local log script
  log="$(git -C "$PROJECT" rev-parse --absolute-git-dir)/rig-upgrade.log"
  printf '\033[0;32m✓\033[0m Updated: .claude/commands/ship.md\n' > "$log"
  touch "$log.failed"
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'done < <(sed "s/${ESC}' "cd '$PROJECT'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"last Step 4 installer run failed"* ]] || false
  [ -z "$(git -C "$PROJECT" diff --cached --name-only)" ]
}

@test "UPGRADE_WORKFLOW step 7: stops when only bookkeeping files would be staged" {
  _stage_fixture
  local log script
  log="$(git -C "$PROJECT" rev-parse --absolute-git-dir)/rig-upgrade.log"
  # A second run that only re-reports up-to-date files names nothing written.
  printf '\033[0;34m→\033[0m Up to date: .claude/commands/ship.md\n' > "$log"
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'done < <(sed "s/${ESC}' "cd '$PROJECT'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Only .rig bookkeeping files would be staged"* ]] || false
  [ -z "$(git -C "$PROJECT" diff --cached --name-only)" ]
}

@test "rig-upgrade 5a: stops when only bookkeeping files would be staged" {
  _stage_fixture
  local script
  script=$(_snippet_script "$RIG_UPGRADE" '_rig_stage_candidate() {' "REPO='$PROJECT'
TRACKING=repo
RIG_WRITTEN_PATHS=()")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Only .rig bookkeeping files would be staged"* ]] || false
  [ -z "$(git -C "$PROJECT" diff --cached --name-only)" ]
}

@test "external mode: Rig-dir-relative 'Created' lines never stage a same-named project file" {
  local ext="$TEST_TMP/ext rig"
  mkdir -p "$ext/processes" "$PROJECT/processes" "$PROJECT/.claude/commands"
  echo "$ext" > "$PROJECT/.rigpath"
  echo rig > "$ext/processes/SHIP_WORKFLOW.md"
  echo old > "$PROJECT/processes/SHIP_WORKFLOW.md"
  echo old > "$PROJECT/.claude/commands/ship.md"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm init
  echo 'user edit' > "$PROJECT/processes/SHIP_WORKFLOW.md"
  echo new > "$PROJECT/.claude/commands/ship.md"
  local log
  log="$(git -C "$PROJECT" rev-parse --absolute-git-dir)/rig-upgrade.log"
  printf '\033[0;32m✓\033[0m Created processes/SHIP_WORKFLOW.md\n' > "$log"
  printf '\033[0;32m✓\033[0m Updated: .claude/commands/ship.md\n' >> "$log"

  local script staged
  script=$(_snippet_script "$UPGRADE_WORKFLOW" 'done < <(sed "s/${ESC}' "cd '$PROJECT'")
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  staged=$(git -C "$PROJECT" diff --cached --name-only)
  [ "$staged" = ".claude/commands/ship.md" ]

  git -C "$PROJECT" reset -q
  script="$TEST_TMP/classic-ext.sh"
  {
    printf 'set -euo pipefail\n'
    printf "REPO='%s'\nRIG_DIR='%s'\nTRACKING=external\n" "$PROJECT" "$ext"
    printf 'UPGRADED=()\nRIG_WRITTEN_PATHS=()\n'
    printf 'installer_output=$(cat %q)\n' "$log"
    _extract_block "$RIG_UPGRADE" 'plain_output=$(printf'
    _extract_block "$RIG_UPGRADE" '_rig_stage_candidate() {'
  } > "$script"
  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  staged=$(git -C "$PROJECT" diff --cached --name-only)
  [ "$staged" = ".claude/commands/ship.md" ]
}
