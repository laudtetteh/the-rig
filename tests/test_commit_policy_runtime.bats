#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_PROJECT/.rig/memory"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.name 'Rig Test'
  git -C "$TEST_PROJECT" config user.email 'rig@example.test'
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit --allow-empty -qm initial
  git -C "$TEST_PROJECT" branch -m main
  git -C "$TEST_PROJECT" switch -qc fix/runtime
  printf 'issue-tracking: none\n' > "$TEST_PROJECT/CLAUDE.md"
  printf '# Progress\n\n---\n' > "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  install_hooks native
}

install_hooks() {
  local layout="$1" hook_dir
  if [ "$layout" = husky ]; then
    hook_dir="$TEST_PROJECT/.husky"
    mkdir -p "$hook_dir"
    git -C "$TEST_PROJECT" config core.hooksPath .husky
  else
    hook_dir="$TEST_PROJECT/.git/hooks"
    git -C "$TEST_PROJECT" config --unset core.hooksPath 2>/dev/null || true
  fi
  cp "$REPO_ROOT/templates/project/.husky/commit-msg" "$hook_dir/commit-msg"
  cp "$REPO_ROOT/templates/project/.husky/post-commit" "$hook_dir/post-commit"
  cp "$REPO_ROOT/templates/project/.husky/filter-commit-message-inplace.sh" "$hook_dir/filter-commit-message-inplace.sh"
  chmod +x "$hook_dir/commit-msg" "$hook_dir/post-commit"
}

approval() { touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"; }
commit_count() { git -C "$TEST_PROJECT" rev-list --count HEAD; }

@test "generated script and escaped git cannot commit without approval" {
  printf '#!/bin/sh\ngit -C "%s" commit --allow-empty -m "fix: generated [#593]"\n' "$TEST_PROJECT" > "$BATS_TEST_TMPDIR/generated.sh"
  chmod +x "$BATS_TEST_TMPDIR/generated.sh"
  run env RIG_COMMIT_POLICY=guarded "$BATS_TEST_TMPDIR/generated.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]]
  run env RIG_COMMIT_POLICY=guarded bash -c 'g\it -C "$1" commit --allow-empty -m "fix: escaped [#593]"' _ "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]]
  [ "$(commit_count)" -eq 1 ]
}

@test "SKIP_COMMIT_VALIDATION cannot bypass approval, but human commits remain possible" {
  run env RIG_COMMIT_POLICY=guarded SKIP_COMMIT_VALIDATION=1 git -C "$TEST_PROJECT" commit --allow-empty -m 'anything'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]]
  approval
  run env SKIP_COMMIT_VALIDATION=1 git -C "$TEST_PROJECT" commit --allow-empty -m 'human commit'
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  ! grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  run env RIG_COMMIT_POLICY=guarded SKIP_COMMIT_VALIDATION=1 git -C "$TEST_PROJECT" commit --allow-empty -m 'agent commit'
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  grep -q 'Auto-logged by post-commit' "$TEST_PROJECT/.rig/memory/PROGRESS.md"
}

@test "approval is consumed once across repeated attempts and on a rejected branch" {
  approval
  run env RIG_COMMIT_POLICY=guarded bash -c 'git -C "$1" commit --allow-empty -m "fix: first [#593]" && git -C "$1" commit --allow-empty -m "fix: second [#593]"' _ "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ "$(commit_count)" -eq 2 ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  git -C "$TEST_PROJECT" switch -q main
  printf 'issue-tracking: none\nhousekeeping: direct-push\n' > "$TEST_PROJECT/CLAUDE.md"
  approval
  run env RIG_COMMIT_POLICY=guarded SKIP_COMMIT_VALIDATION=1 git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: blocked [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Direct-to-main commit blocked'* ]]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "prepared -F subject created in same shell call determines direct-push policy" {
  git -C "$TEST_PROJECT" switch -q main
  printf 'issue-tracking: none\nhousekeeping: direct-push\n' > "$TEST_PROJECT/CLAUDE.md"
  approval
  run env RIG_COMMIT_POLICY=guarded bash -c 'printf "docs: approved [#593]\n" > "$1"; git -C "$2" commit --allow-empty -F "$1"' _ "$BATS_TEST_TMPDIR/message" "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TEST_PROJECT" log -1 --format=%s)" = 'docs: approved [#593]' ]
  approval
  run env RIG_COMMIT_POLICY=guarded bash -c 'printf "fix: blocked [#593]\n" > "$1"; git -C "$2" commit --allow-empty -F "$1"' _ "$BATS_TEST_TMPDIR/message" "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Direct-to-main commit blocked'* ]]
}

@test "Git environment overrides use the committed linked worktree approval and progress" {
  linked="$BATS_TEST_TMPDIR/linked"
  git -C "$TEST_PROJECT" worktree add -qb fix/linked "$linked"
  mkdir -p "$linked/.rig/memory"
  printf '# Linked progress\n\n---\n' > "$linked/.rig/memory/PROGRESS.md"
  approval
  linked_git_dir="$(git -C "$linked" rev-parse --absolute-git-dir)"
  run env RIG_COMMIT_POLICY=guarded GIT_DIR="$linked_git_dir" GIT_WORK_TREE="$linked" git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: linked [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"$linked/.rig/memory/.rig-commit-ok"* ]]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  touch "$linked/.rig/memory/.rig-commit-ok"
  run env RIG_COMMIT_POLICY=guarded GIT_DIR="$linked_git_dir" GIT_WORK_TREE="$linked" git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: linked [#593]'
  [ "$status" -eq 0 ]
  hash="$(git -C "$linked" rev-parse HEAD)"
  grep -Fq "$hash" "$linked/.rig/memory/PROGRESS.md"
  ! grep -Fq "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md"
}

@test "stealth .rigpath and Husky layout use the target approval" {
  install_hooks husky
  external="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$external/memory"
  printf '# External progress\n\n---\n' > "$external/memory/PROGRESS.md"
  printf '%s\n' "$external" > "$TEST_PROJECT/.rigpath"
  approval
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: external [#593]'
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  touch "$external/memory/.rig-commit-ok"
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: external [#593]'
  [ "$status" -eq 0 ]
  [ ! -f "$external/memory/.rig-commit-ok" ]
  grep -Fq "$(git -C "$TEST_PROJECT" rev-parse HEAD)" "$external/memory/PROGRESS.md"
}

@test "hookless fallback logs the linked worktree and leaves main progress untouched" {
  linked="$BATS_TEST_TMPDIR/linked-hookless"
  git -C "$TEST_PROJECT" worktree add -qb fix/linked-hookless "$linked"
  mkdir -p "$linked/.rig/memory" "$TEST_PROJECT/.claude/hooks"
  printf '# Linked progress\n\n---\n' > "$linked/.rig/memory/PROGRESS.md"
  cp "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  cp "$REPO_ROOT/templates/project/.claude/hooks/post-tool.sh" "$TEST_PROJECT/.claude/hooks/post-tool.sh"
  mv "$TEST_PROJECT/.git/hooks/commit-msg" "$TEST_PROJECT/.git/hooks/commit-msg.saved"
  mv "$TEST_PROJECT/.git/hooks/post-commit" "$TEST_PROJECT/.git/hooks/post-commit.saved"
  touch "$linked/.rig/memory/.rig-commit-ok"
  command="RIG_COMMIT_POLICY=guarded git -C '$linked' commit --allow-empty -m 'fix: linked fallback [#593]'"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"linked-fallback","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$TEST_PROJECT" "$command")"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/pre-tool.sh' _ "$TEST_PROJECT" "$payload"
  [ "$status" -eq 0 ]
  [ ! -f "$linked/.rig/memory/.rig-commit-ok" ]

  run env RIG_COMMIT_POLICY=guarded git -C "$linked" commit --allow-empty -m 'fix: linked fallback [#593]'
  [ "$status" -eq 0 ]
  commit_output="$output"
  post_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"linked-fallback","tool_response":{"stdout":sys.argv[1]}}))' "$commit_output")"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/post-tool.sh' _ "$TEST_PROJECT" "$post_payload"
  [ "$status" -eq 0 ]
  hash="$(git -C "$linked" rev-parse HEAD)"
  grep -Fq "$hash" "$linked/.rig/memory/PROGRESS.md"
  ! grep -Fq "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md"
}

@test "hookless pending events in an external Rig dir log two worktrees out of order" {
  local linked_a linked_b external command payload_a payload_b output_a output_b post_a post_b id_a id_b
  linked_a="$BATS_TEST_TMPDIR/hookless-a"
  linked_b="$BATS_TEST_TMPDIR/hookless-b"
  external="$BATS_TEST_TMPDIR/invoking-rig"
  git -C "$TEST_PROJECT" worktree add -qb fix/hookless-a "$linked_a"
  git -C "$TEST_PROJECT" worktree add -qb fix/hookless-b "$linked_b"
  mkdir -p "$linked_a/.rig/memory" "$linked_b/.rig/memory" "$external/memory" "$TEST_PROJECT/.claude/hooks"
  printf '# A progress\n\n---\n' > "$linked_a/.rig/memory/PROGRESS.md"
  printf '# B progress\n\n---\n' > "$linked_b/.rig/memory/PROGRESS.md"
  printf '%s\n' "$external" > "$TEST_PROJECT/.rigpath"
  cp "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  cp "$REPO_ROOT/templates/project/.claude/hooks/post-tool.sh" "$TEST_PROJECT/.claude/hooks/post-tool.sh"
  mv "$TEST_PROJECT/.git/hooks/commit-msg" "$TEST_PROJECT/.git/hooks/commit-msg.saved"
  mv "$TEST_PROJECT/.git/hooks/post-commit" "$TEST_PROJECT/.git/hooks/post-commit.saved"

  touch "$linked_a/.rig/memory/.rig-commit-ok"
  command="RIG_COMMIT_POLICY=guarded git -C '$linked_a' commit --allow-empty -m 'fix: first [#593]'"
  payload_a="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"fallback-a","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$TEST_PROJECT" "$command")"
  command="RIG_COMMIT_POLICY=guarded git -C '$linked_b' commit --allow-empty -m 'fix: second [#593]'"
  payload_b="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"fallback-b","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$TEST_PROJECT" "$command")"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/pre-tool.sh' _ "$TEST_PROJECT" "$payload_a"
  [ "$status" -eq 0 ]
  touch "$linked_b/.rig/memory/.rig-commit-ok"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/pre-tool.sh' _ "$TEST_PROJECT" "$payload_b"
  [ "$status" -eq 0 ]
  id_a="$(python3 -c 'import hashlib; print(hashlib.sha256(b"fallback-a").hexdigest()[:16])')"
  id_b="$(python3 -c 'import hashlib; print(hashlib.sha256(b"fallback-b").hexdigest()[:16])')"
  [ -f "$external/memory/.rig-commit-fallback-pending-$id_a" ]
  [ -f "$external/memory/.rig-commit-fallback-pending-$id_b" ]

  run env RIG_COMMIT_POLICY=guarded git -C "$linked_a" commit --allow-empty -m 'fix: first [#593]'
  [ "$status" -eq 0 ]
  output_a="$output"
  run env RIG_COMMIT_POLICY=guarded git -C "$linked_b" commit --allow-empty -m 'fix: second [#593]'
  [ "$status" -eq 0 ]
  output_b="$output"
  post_a="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"fallback-a","tool_response":{"stdout":sys.argv[1]}}))' "$output_a")"
  post_b="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"fallback-b","tool_response":{"stdout":sys.argv[1]}}))' "$output_b")"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/post-tool.sh' _ "$TEST_PROJECT" "$post_b"
  [ "$status" -eq 0 ]
  run bash -c 'cd "$1" && printf "%s" "$2" | bash .claude/hooks/post-tool.sh' _ "$TEST_PROJECT" "$post_a"
  [ "$status" -eq 0 ]
  grep -Fq "$(git -C "$linked_a" rev-parse HEAD)" "$linked_a/.rig/memory/PROGRESS.md"
  grep -Fq "$(git -C "$linked_b" rev-parse HEAD)" "$linked_b/.rig/memory/PROGRESS.md"
  [ ! -e "$external/memory/.rig-commit-fallback-pending-$id_a" ]
  [ ! -e "$external/memory/.rig-commit-fallback-pending-$id_b" ]
}

@test "stale approval expires before an actual commit" {
  approval
  touch -t 200001010000 "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: stale [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *'stale'* ]]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
}

@test "guarded cherry-pick replay does not consume approval or log a stub" {
  printf 'source\n' > "$TEST_PROJECT/source.txt"
  git -C "$TEST_PROJECT" add source.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'fix: source [#593]'
  source_sha="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  git -C "$TEST_PROJECT" switch -q main
  approval
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" cherry-pick "$source_sha"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  ! grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"
}

@test "guarded rebase replay does not consume approval or log a stub" {
  printf 'topic\n' > "$TEST_PROJECT/topic.txt"
  git -C "$TEST_PROJECT" add topic.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'fix: topic [#593]'
  git -C "$TEST_PROJECT" switch -q main
  printf 'base\n' > "$TEST_PROJECT/base.txt"
  git -C "$TEST_PROJECT" add base.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'chore: base [#593]'
  git -C "$TEST_PROJECT" switch -q fix/runtime
  approval
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" rebase main
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  ! grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"
}

@test "guarded merge replay does not consume approval or log a stub" {
  printf 'topic\n' > "$TEST_PROJECT/topic.txt"
  git -C "$TEST_PROJECT" add topic.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'fix: topic [#593]'
  git -C "$TEST_PROJECT" switch -q main
  printf 'base\n' > "$TEST_PROJECT/base.txt"
  git -C "$TEST_PROJECT" add base.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'chore: base [#593]'
  approval
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" merge --no-ff -m 'Merge branch fix/runtime' fix/runtime
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  ! grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"
}

@test "post-commit logs final SHA once after opted-in late-footer amend" {
  hook_dir="$TEST_PROJECT/.git/hooks"
  mv "$hook_dir/commit-msg" "$hook_dir/commit-msg-real"
  cat > "$hook_dir/commit-msg" <<'WRAPPER'
#!/bin/sh
"$(dirname "$0")/commit-msg-real" "$1" || exit $?
printf '\nGenerated with Codex.\n' >> "$1"
WRAPPER
  chmod +x "$hook_dir/commit-msg"
  mv "$hook_dir/post-commit" "$hook_dir/post-commit-real"
  cat > "$hook_dir/post-commit" <<'WRAPPER'
#!/bin/sh
git rev-parse HEAD > "$RIG_TEST_PRE_AMEND"
"$(dirname "$0")/post-commit-real"
WRAPPER
  chmod +x "$hook_dir/post-commit"
  approval
  run env RIG_COMMIT_POLICY=guarded RIG_POST_COMMIT_AUTO_AMEND=1 RIG_TEST_PRE_AMEND="$BATS_TEST_TMPDIR/pre-amend" git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: footer [#593]'
  [ "$status" -eq 0 ]
  pre="$(cat "$BATS_TEST_TMPDIR/pre-amend")"
  final="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  [ "$pre" != "$final" ]
  grep -Fq "$final" "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  ! grep -Fq "$pre" "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  [ "$(grep -c 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
  run env RIG_COMMIT_POLICY=guarded bash -c 'cd "$1" && .git/hooks/post-commit-real' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
  payload='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"[fix/runtime abc1234] fix: footer"}}'
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3/templates/project/.claude/hooks/post-tool.sh"' _ "$TEST_PROJECT" "$payload" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
}
