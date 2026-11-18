#!/usr/bin/env bats
#
# tests/test_upgrade_base_branch.bats — issue #659
#
# An upgrade must render workflow files with the base branch the project
# already configured in CLAUDE.md (`base-branch:`), not whatever origin/HEAD
# happens to point at. Before #659 the installer derived the value only from
# --base-branch, then origin/HEAD, then `main`, so a project configured for
# `develop` whose origin/HEAD pointed at `main` had post-merge.md, ship.md,
# POST_MERGE_WORKFLOW.md, SHIP_WORKFLOW.md and the generated Codex skills
# rewritten to `main` by both agent-upgrade and the classic upgrade. Branch
# names were also sanitized with `tr -dc`, silently turning `release/v2`
# into `releasev2`.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  export HOME="$TEMP_DIR/home"
  mkdir -p "$HOME"
  TEST_PROJECT="$TEMP_DIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q -b develop
  git -C "$TEST_PROJECT" config user.email test@example.test
  git -C "$TEST_PROJECT" config user.name Test
  git -C "$TEST_PROJECT" commit -q --allow-empty -m initial
  # origin/HEAD deliberately disagrees with the configured base branch.
  git -C "$TEST_PROJECT" update-ref refs/remotes/origin/main HEAD
  git -C "$TEST_PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

teardown() { rm -rf "$TEMP_DIR"; }

install_project() {
  local tracking="$1" base="$2" agent="${3:-both}"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --project-agent "$agent" --base-branch "$base" \
    --tracking "$tracking" --strategy merge </dev/null
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20; return 1; }
}

upgrade_project() {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --strategy "$1" </dev/null
}

rig_dir() {
  if [[ -f "$TEST_PROJECT/.rigpath" ]]; then
    cat "$TEST_PROJECT/.rigpath"
  else
    printf '%s\n' "$TEST_PROJECT/.rig"
  fi
}

# Fails unless every base-branch-substituted workflow file and Codex mirror
# carries "$1" and none fell back to `main` for the PR/merge base.
assert_base_branch_kept() {
  local base="$1" rig f
  rig="$(rig_dir)"
  for f in "$TEST_PROJECT/.claude/commands/post-merge.md" \
           "$TEST_PROJECT/.claude/commands/ship.md" \
           "$rig/processes/POST_MERGE_WORKFLOW.md" \
           "$rig/processes/SHIP_WORKFLOW.md" \
           "$TEST_PROJECT/.agents/skills/ship/references/command.md" \
           "$TEST_PROJECT/.agents/skills/post-merge/references/command.md"; do
    [ -f "$f" ] || { echo "missing: $f"; return 1; }
    grep -Fq -- "$base" "$f" || { echo "lost base '$base': $f"; return 1; }
    if grep -Fq -- '[BASE_BRANCH]' "$f"; then echo "unsubstituted: $f"; return 1; fi
  done
  grep -Fq -- "--base $base" "$TEST_PROJECT/.claude/commands/ship.md"
  grep -Fq -- "--base $base" "$rig/processes/SHIP_WORKFLOW.md"
  if grep -Fq -- '--base main' "$TEST_PROJECT/.claude/commands/ship.md"; then
    echo "ship.md was rewritten to --base main"; return 1
  fi
}

@test "agent-upgrade keeps the CLAUDE.md base branch when origin/HEAD points elsewhere" {
  install_project stealth develop
  assert_base_branch_kept develop
  grep -q '^base-branch: develop$' "$TEST_PROJECT/CLAUDE.md"

  upgrade_project agent-upgrade
  [ "$status" -eq 0 ]
  assert_base_branch_kept develop

  # Second upgrade: the refreshed manifest must not report the substituted
  # files as customized.
  run bash -c '"$1" --project-only --target "$2" --strategy agent-upgrade </dev/null 2>/dev/null' \
    _ "$INSTALLER" "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  run python3 -c '
import json, sys
doc = json.loads(sys.argv[1])
assert doc["status"] == "success", doc["status"]
assert not doc.get("conflicts"), doc.get("conflicts")
' "$output"
  [ "$status" -eq 0 ]
  assert_base_branch_kept develop
}

@test "classic upgrade keeps a quoted CLAUDE.md base branch and reports no customized files next time" {
  install_project repo develop
  # A quoted value upgraded fine before #659 (the old sanitizer dropped the
  # quotes); it must still resolve to the bare branch name.
  sed 's/^base-branch: develop$/base-branch: "develop"/' "$TEST_PROJECT/CLAUDE.md" > "$TEMP_DIR/claude.md"
  cat "$TEMP_DIR/claude.md" > "$TEST_PROJECT/CLAUDE.md"
  grep -q '^base-branch: "develop"$' "$TEST_PROJECT/CLAUDE.md"

  upgrade_project upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Base branch: develop (from CLAUDE.md base-branch:)"* ]] || return 1
  assert_base_branch_kept develop

  upgrade_project upgrade
  [ "$status" -eq 0 ]
  [[ "$output" != *"Customized file detected"* ]] || return 1
  assert_base_branch_kept develop
}

@test "--base-branch still wins over the CLAUDE.md value" {
  install_project repo develop
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --strategy upgrade --base-branch trunk </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Base branch: trunk"* ]] || return 1
  [[ "$output" != *"from CLAUDE.md"* ]] || return 1
  [[ "$output" == *"CLAUDE.md still says base-branch: develop, but workflow files were rendered with --base-branch trunk"* ]] || return 1
  [[ "$output" == *"Update base-branch: in $TEST_PROJECT/CLAUDE.md to trunk"* ]] || return 1
  # CLAUDE.md is user-owned: warned about, never rewritten.
  grep -q '^base-branch: develop$' "$TEST_PROJECT/CLAUDE.md"
  grep -Fq -- '--base trunk' "$TEST_PROJECT/.claude/commands/ship.md"
}

@test "agent plan and upgrade report a configured base branch split as JSON" {
  install_project repo develop claude
  local strategy expected_mode
  for strategy in agent-plan agent-upgrade; do
    expected_mode=plan
    [ "$strategy" = agent-plan ] || expected_mode=apply
    run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
      --strategy "$strategy" --base-branch trunk </dev/null
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20; return 1; }
    run python3 -c '
import json, sys
doc = json.loads(sys.argv[1])
assert doc["mode"] == sys.argv[2], doc["mode"]
assert doc["status"] == "success", doc["status"]
assert doc["warnings"] == [{
    "code": "base_branch_config_split",
    "configured_base_branch": "develop",
    "rendered_base_branch": "trunk",
    "message": "CLAUDE.md still names a different base branch; update its base-branch value or rerun without --base-branch.",
}], doc["warnings"]
' "$output" "$expected_mode"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  done
  grep -q '^base-branch: develop$' "$TEST_PROJECT/CLAUDE.md"
  grep -Fq -- '--base trunk' "$TEST_PROJECT/.claude/commands/ship.md"
}

@test "upgrade refuses a CLAUDE.md that sets base-branch more than once" {
  install_project repo develop
  printf '\nbase-branch: main\n' >> "$TEST_PROJECT/CLAUDE.md"
  cp "$TEST_PROJECT/.claude/commands/ship.md" "$TEMP_DIR/ship.before"

  upgrade_project upgrade
  [ "$status" -ne 0 ]
  [[ "$output" == *"sets base-branch: more than once"* ]] || return 1
  cmp -s "$TEMP_DIR/ship.before" "$TEST_PROJECT/.claude/commands/ship.md"
}

@test "branch names containing a slash are preserved through install and upgrade" {
  install_project repo release/v2
  grep -q '^base-branch: release/v2$' "$TEST_PROJECT/CLAUDE.md"
  assert_base_branch_kept release/v2
  if grep -rFq 'releasev2' "$TEST_PROJECT/.claude" "$TEST_PROJECT/.rig" "$TEST_PROJECT/.agents"; then
    return 1
  fi

  upgrade_project upgrade
  [ "$status" -eq 0 ]
  assert_base_branch_kept release/v2
}

@test "invalid or shell-unsafe base branch names are rejected instead of mangled" {
  local bad
  for bad in 'bad name' 'x$(id)' 'feature..x' '-leading' 'a&b'; do
    run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
      --project-name Test --base-branch "$bad" --tracking repo --strategy merge </dev/null
    [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    [[ "$output" == *"Unsupported base branch name"* ]] || { echo "no error for: $bad"; return 1; }
    [ ! -f "$TEST_PROJECT/.claude/commands/ship.md" ] || { echo "installed for: $bad"; return 1; }
  done
}

@test "an unusable base branch stops a combined install before the global layer writes" {
  run bash "$INSTALLER" --target "$TEST_PROJECT" --project-name Test \
    --base-branch 'x$(id)' --tracking repo --strategy merge </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported base branch name"* ]] || return 1
  [ ! -e "$HOME/.claude" ]
  [ ! -e "$HOME/.codex" ]

  printf 'base-branch: develop\nbase-branch: main\n' > "$TEST_PROJECT/CLAUDE.md"
  run bash "$INSTALLER" --target "$TEST_PROJECT" --project-name Test \
    --tracking repo --strategy merge </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"sets base-branch: more than once"* ]] || return 1
  [ ! -e "$HOME/.claude" ]
}
