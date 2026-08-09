#!/usr/bin/env bats
#
# tests/test_doctor_upgrade_patterns.bats — issue #473
#
# Post-upgrade validation against known historical bug patterns: diffs the
# most recent #472 pre-flight snapshot against current state for two
# genuinely diffable patterns from docs/lessons-learned.md -- #14 (a
# personalized file reverted to raw template content) and #15 (a symlink
# silently replaced by a regular file). These tests construct each pattern's
# exact before/after signature directly (rather than relying on a bug that's
# already fixed to reproduce it), since the point is to prove doctor's own
# detection logic, independent of whichever historical bug originally
# produced that signature.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test
}

teardown() { rm -rf "$TEMP_DIR"; }

doctor_json() {
  run "$TEST_PROJECT/bin/rig" doctor --json
  DOCTOR_OUTPUT="$output"
}

doctor_check_detail() {
  # doctor_check_detail <check-name>
  printf '%s\n' "$DOCTOR_OUTPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for c in d['checks']:
    if c['name'] == sys.argv[1]:
        print(c['detail'])
        break
else:
    sys.exit('check not found: ' + sys.argv[1])
" "$1"
}

doctor_check_ok() {
  printf '%s\n' "$DOCTOR_OUTPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for c in d['checks']:
    if c['name'] == sys.argv[1]:
        print('true' if c['ok'] else 'false')
        break
else:
    sys.exit('check not found: ' + sys.argv[1])
" "$1"
}

@test "doctor reports both upgrade-pattern checks as passing when no pre-flight snapshot exists yet" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]

  doctor_json
  [ "$(doctor_check_ok upgrade_pattern_blanked_file)" = "true" ]
  [ "$(doctor_check_ok upgrade_pattern_symlink_replaced)" = "true" ]
  [[ "$(doctor_check_detail upgrade_pattern_blanked_file)" == *"no pre-flight snapshot found"* ]] || return 1
}

@test "doctor reports both upgrade-pattern checks as passing on an unmodified project with a real snapshot" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  doctor_json
  [ "$(doctor_check_ok upgrade_pattern_blanked_file)" = "true" ]
  [ "$(doctor_check_ok upgrade_pattern_symlink_replaced)" = "true" ]
  [ "$(doctor_check_detail upgrade_pattern_blanked_file)" = "none detected" ]
  [ "$(doctor_check_detail upgrade_pattern_symlink_replaced)" = "none detected" ]
}

@test "doctor flags a personalized CLAUDE.md that reverted to raw template content (lesson #14)" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  if /usr/bin/grep -q '\[Project Name\]' "$TEST_PROJECT/CLAUDE.md"; then return 1; fi

  cp "$REPO_ROOT/templates/project/CLAUDE.md" "$TEST_PROJECT/CLAUDE.md"
  /usr/bin/grep -q '\[Project Name\]' "$TEST_PROJECT/CLAUDE.md"

  doctor_json
  [ "$(doctor_check_ok upgrade_pattern_blanked_file)" = "false" ]
  [[ "$(doctor_check_detail upgrade_pattern_blanked_file)" == *"lesson #14"* ]] || return 1
  [[ "$(doctor_check_detail upgrade_pattern_blanked_file)" == *"CLAUDE.md"* ]] || return 1
}

@test "doctor flags a symlink that was silently replaced by a regular file (lesson #15), in repo tracking mode" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  local snap_dir
  snap_dir="$(find "$TEST_PROJECT/.rig-backup/preflight-snapshots" -mindepth 1 -maxdepth 1 -type d)"
  rm -f "$snap_dir/.claude/hooks/pre-tool.sh"
  ln -s /etc/hosts "$snap_dir/.claude/hooks/pre-tool.sh"

  doctor_json
  [ "$(doctor_check_ok upgrade_pattern_symlink_replaced)" = "false" ]
  [[ "$(doctor_check_detail upgrade_pattern_symlink_replaced)" == *"lesson #15"* ]] || return 1
  [[ "$(doctor_check_detail upgrade_pattern_symlink_replaced)" == *".claude/hooks/pre-tool.sh"* ]] || return 1
}

@test "doctor flags a symlink-replaced pattern inside the external .rig/ dir under stealth tracking, mapped back to the real external path" {
  local rig_ext="$TEMP_DIR/external-rig"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy merge
  [ "$status" -eq 0 ]
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$rig_ext" --strategy upgrade
  [ "$status" -eq 0 ]

  local snap_dir
  snap_dir="$(find "$rig_ext/preflight-snapshots" -mindepth 1 -maxdepth 1 -type d)"
  [ -f "$rig_ext/contextual-tips.sh" ]
  rm -f "$snap_dir/.rig/contextual-tips.sh"
  ln -s /etc/hosts "$snap_dir/.rig/contextual-tips.sh"

  doctor_json
  [ "$(doctor_check_ok upgrade_pattern_symlink_replaced)" = "false" ]
  [[ "$(doctor_check_detail upgrade_pattern_symlink_replaced)" == *".rig/contextual-tips.sh"* ]] || return 1
}
