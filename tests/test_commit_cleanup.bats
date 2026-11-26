#!/usr/bin/env bats
# commit-cleanup: no keeps tool footers without disabling commit guards (#698).

FOOTER='Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  RIG_DIR="$BATS_TEST_TMPDIR/rig"
  mkdir -p "$TEST_PROJECT" "$RIG_DIR/memory"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.name 'Rig Test'
  git -C "$TEST_PROJECT" config user.email 'rig@example.test'
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit --allow-empty -qm initial
  git -C "$TEST_PROJECT" branch -m main
  git -C "$TEST_PROJECT" switch -qc fix/cleanup
  printf '%s\n' "$RIG_DIR" > "$TEST_PROJECT/.rigpath"
  printf '# Progress\n\n---\n' > "$RIG_DIR/memory/PROGRESS.md"
  local hook_dir="$TEST_PROJECT/.git/hooks"
  cp "$REPO_ROOT/templates/project/.husky/commit-msg" "$hook_dir/commit-msg"
  cp "$REPO_ROOT/templates/project/.husky/post-commit" "$hook_dir/post-commit"
  cp "$REPO_ROOT/templates/project/.husky/filter-commit-message-inplace.sh" "$hook_dir/filter-commit-message-inplace.sh"
  chmod +x "$hook_dir/commit-msg" "$hook_dir/post-commit"
  mkdir -p "$TEST_PROJECT/bin"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$TEST_PROJECT/bin/rig-path.py"
  cp "$REPO_ROOT/templates/project/bin/rig-tracker-config.py" "$TEST_PROJECT/bin/rig-tracker-config.py"
  cp "$REPO_ROOT/templates/project/bin/rig-config" "$TEST_PROJECT/bin/rig-config"
}

write_settings() {
  printf 'issue-tracking: none\n%s\n' "$1" > "$TEST_PROJECT/CLAUDE.md"
}

commit_with_footer() {
  printf 'feat: keep the footer\n\n%s\n' "$FOOTER" > "$BATS_TEST_TMPDIR/msg"
  git -C "$TEST_PROJECT" commit --allow-empty -F "$BATS_TEST_TMPDIR/msg" "$@"
}

commit_with_late_footer() {
  printf 'feat: keep the late footer\n\n%s\n' "$FOOTER" > "$BATS_TEST_TMPDIR/msg"
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit --allow-empty -F "$BATS_TEST_TMPDIR/msg"
  (cd "$TEST_PROJECT" && .git/hooks/post-commit)
}

@test "commit-cleanup no: commit-msg keeps a tool footer" {
  write_settings 'commit-cleanup: no'
  run commit_with_footer
  [ "$status" -eq 0 ]
  git -C "$TEST_PROJECT" log -1 --format=%B | grep -qxF "$FOOTER"
}

@test "commit-cleanup yes: commit-msg strips a tool footer" {
  write_settings 'commit-cleanup: yes'
  run commit_with_footer
  [ "$status" -eq 0 ]
  if git -C "$TEST_PROJECT" log -1 --format=%B | grep -qF "$FOOTER"; then return 1; fi
}

@test "commit-cleanup missing: the default still strips a tool footer" {
  write_settings ''
  run commit_with_footer
  [ "$status" -eq 0 ]
  if git -C "$TEST_PROJECT" log -1 --format=%B | grep -qF "$FOOTER"; then return 1; fi
}

@test "commit-cleanup no: post-commit does not warn about a late footer" {
  write_settings 'commit-cleanup: no'
  run commit_with_late_footer
  [ "$status" -eq 0 ]
  [[ "$output" != *"late AI footer"* ]] || return 1
  git -C "$TEST_PROJECT" log -1 --format=%B | grep -qxF "$FOOTER"
}

@test "commit-cleanup yes: post-commit still warns about a late footer" {
  write_settings 'commit-cleanup: yes'
  run commit_with_late_footer
  [ "$status" -eq 0 ]
  [[ "$output" == *"late AI footer"* ]] || return 1
}

@test "commit-cleanup no: message format validation still runs" {
  write_settings 'commit-cleanup: no'
  run git -C "$TEST_PROJECT" commit --allow-empty -m 'not a conventional subject'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Conventional Commits"* ]] || return 1
}

@test "commit-cleanup no: guarded commits still require approval" {
  write_settings 'commit-cleanup: no'
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'feat: needs approval'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Approval is missing"* ]] || return 1
}

@test "commit-cleanup no: guarded commits to main are still blocked" {
  write_settings 'commit-cleanup: no'
  git -C "$TEST_PROJECT" switch -q main
  touch "$RIG_DIR/memory/.rig-commit-ok"
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'feat: direct to main'
  [ "$status" -ne 0 ]
  [[ "$output" == *"create a feature branch"* ]] || return 1
}

@test "commit-cleanup invalid: the commit is blocked with a fix hint" {
  write_settings 'commit-cleanup: maybe'
  run commit_with_footer
  [ "$status" -ne 0 ]
  [[ "$output" == *"commit-cleanup"* ]] || return 1
  [[ "$output" == *"yes or no"* ]] || return 1
}

@test "commit-cleanup: a missing reader keeps the default cleanup" {
  write_settings 'commit-cleanup: no'
  rm "$TEST_PROJECT/bin/rig-config"
  run commit_with_footer
  [ "$status" -eq 0 ]
  if git -C "$TEST_PROJECT" log -1 --format=%B | grep -qF "$FOOTER"; then return 1; fi
}

@test "commit-cleanup no row no longer tells users to delete the hooks" {
  if grep -q 'Comment out or remove `.husky/commit-msg`' "$REPO_ROOT/templates/project/CLAUDE.md"; then return 1; fi
  grep -q 'Do not delete the hooks' "$REPO_ROOT/templates/project/CLAUDE.md"
}
