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
  cp "$REPO_ROOT/templates/project/.husky/post-merge" "$hook_dir/post-merge"
  cp "$REPO_ROOT/templates/project/.husky/filter-commit-message-inplace.sh" "$hook_dir/filter-commit-message-inplace.sh"
  chmod +x "$hook_dir/commit-msg" "$hook_dir/post-commit" "$hook_dir/post-merge"
}

approval() { touch "$TEST_PROJECT/.rig/memory/.rig-commit-ok"; }
commit_count() { git -C "$TEST_PROJECT" rev-list --count HEAD; }

@test "commit-msg capability argument is side-effect-free and not an approval bypass" {
  run env RIG_COMMIT_POLICY=guarded bash -c 'cd "$1" && .git/hooks/commit-msg --rig-policy-probe' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$output" = 'rig-commit-policy-v1' ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: probe [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]] || return 1
}

@test "generated script and escaped git cannot commit without approval" {
  printf '#!/bin/sh\ngit -C "%s" commit --allow-empty -m "fix: generated [#593]"\n' "$TEST_PROJECT" > "$BATS_TEST_TMPDIR/generated.sh"
  chmod +x "$BATS_TEST_TMPDIR/generated.sh"
  run env RIG_COMMIT_POLICY=guarded "$BATS_TEST_TMPDIR/generated.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]] || return 1
  run env RIG_COMMIT_POLICY=guarded bash -c 'g\it -C "$1" commit --allow-empty -m "fix: escaped [#593]"' _ "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]] || return 1
  [ "$(commit_count)" -eq 1 ]
}

@test "SKIP_COMMIT_VALIDATION cannot bypass approval, but human commits remain possible" {
  run env RIG_COMMIT_POLICY=guarded SKIP_COMMIT_VALIDATION=1 git -C "$TEST_PROJECT" commit --allow-empty -m 'anything'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]] || return 1
  approval
  run env SKIP_COMMIT_VALIDATION=1 git -C "$TEST_PROJECT" commit --allow-empty -m 'human commit'
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  if grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi
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
  [[ "$output" == *'Direct-to-main commit blocked'* ]] || return 1
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
  [[ "$output" == *'Direct-to-main commit blocked'* ]] || return 1
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
  [[ "$output" == *"$linked/.rig/memory/.rig-commit-ok"* ]] || return 1
  [ -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  touch "$linked/.rig/memory/.rig-commit-ok"
  run env RIG_COMMIT_POLICY=guarded GIT_DIR="$linked_git_dir" GIT_WORK_TREE="$linked" git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: linked [#593]'
  [ "$status" -eq 0 ]
  hash="$(git -C "$linked" rev-parse HEAD)"
  grep -Fq "$hash" "$linked/.rig/memory/PROGRESS.md"
  if grep -Fq "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi
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
  if grep -Fq "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi
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

@test "hookless PostToolUse from outside Git logs target and preserves branch warning" {
  local outside command payload commit_output post_payload warning_payload hash
  outside="$BATS_TEST_TMPDIR/outside-git"
  mkdir -p "$outside" "$TEST_PROJECT/.claude/hooks"
  cp "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  cp "$REPO_ROOT/templates/project/.claude/hooks/post-tool.sh" "$TEST_PROJECT/.claude/hooks/post-tool.sh"
  mv "$TEST_PROJECT/.git/hooks/commit-msg" "$TEST_PROJECT/.git/hooks/commit-msg.saved"
  mv "$TEST_PROJECT/.git/hooks/post-commit" "$TEST_PROJECT/.git/hooks/post-commit.saved"
  approval
  command="RIG_COMMIT_POLICY=guarded git -C '$TEST_PROJECT' commit --allow-empty -m 'fix: outside [#593]'"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"outside-git","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$outside" "$command")"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' _ "$outside" "$payload" "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: outside [#593]'
  [ "$status" -eq 0 ]
  commit_output="$output"
  post_payload="$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"outside-git","tool_response":{"stdout":sys.argv[1]}}))' "$commit_output")"
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' _ "$outside" "$post_payload" "$TEST_PROJECT/.claude/hooks/post-tool.sh"
  [ "$status" -eq 0 ]
  hash="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  grep -Fq "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md"

  warning_payload='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"Switched to a new branch '\''weird'\''"}}'
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' _ "$outside" "$warning_payload" "$TEST_PROJECT/.claude/hooks/post-tool.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"doesn't follow naming conventions"* ]] || return 1
}

@test "stale approval expires before an actual commit" {
  approval
  touch -t 200001010000 "$TEST_PROJECT/.rig/memory/.rig-commit-ok"
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: stale [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *'stale'* ]] || return 1
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
  if grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi
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
  if grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi
}

@test "guarded generated merge commit requires one approval and logs final SHA" {
  git -C "$TEST_PROJECT" switch -qc fix/merge-source
  printf 'topic\n' > "$TEST_PROJECT/topic.txt"
  git -C "$TEST_PROJECT" add topic.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'fix: topic [#593]'
  git -C "$TEST_PROJECT" switch -q fix/runtime
  printf 'base\n' > "$TEST_PROJECT/base.txt"
  git -C "$TEST_PROJECT" add base.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'chore: base [#593]'

  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" merge --no-ff -m 'chore: merge topic [#593]' fix/merge-source
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]] || return 1
  if grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi
  [ ! -e "$(git -C "$TEST_PROJECT" rev-parse --absolute-git-dir)/rig-merge-progress-pending" ]
  git -C "$TEST_PROJECT" merge --abort

  approval
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" merge --no-ff -m 'chore: merge topic [#593]' fix/merge-source
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  [ ! -e "$(git -C "$TEST_PROJECT" rev-parse --absolute-git-dir)/rig-merge-progress-pending" ]
  hash="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  grep -Fq "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  grep -Fq "merge_sha=$hash" "$TEST_PROJECT/.rig/memory/.post-merge-pending"
  [ "$(grep -Fc "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit --allow-empty -m 'fix: second [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]] || return 1
  [ ! -e "$(git -C "$TEST_PROJECT" rev-parse --absolute-git-dir)/rig-merge-progress-pending" ]
}

@test "guarded manual merge completion enforces base-branch policy and logs final SHA" {
  git -C "$TEST_PROJECT" switch -q main
  git -C "$TEST_PROJECT" switch -qc fix/conflict
  printf 'topic\n' > "$TEST_PROJECT/conflict.txt"
  git -C "$TEST_PROJECT" add conflict.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'fix: topic [#593]'
  git -C "$TEST_PROJECT" switch -q main
  printf 'main\n' > "$TEST_PROJECT/conflict.txt"
  git -C "$TEST_PROJECT" add conflict.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'chore: main [#593]'
  run git -C "$TEST_PROJECT" merge --no-ff fix/conflict
  [ "$status" -ne 0 ]
  [ -f "$(git -C "$TEST_PROJECT" rev-parse --absolute-git-dir)/MERGE_HEAD" ]
  printf 'resolved\n' > "$TEST_PROJECT/conflict.txt"
  git -C "$TEST_PROJECT" add conflict.txt

  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit -m 'chore: resolved merge [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Approval is missing'* ]] || return 1
  approval
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit -m 'chore: resolved merge [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Commit to 'main' blocked"* ]] || return 1
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]

  printf 'issue-tracking: none\nhousekeeping: direct-push\n' > "$TEST_PROJECT/CLAUDE.md"
  approval
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit -m 'fix: resolved merge [#593]'
  [ "$status" -ne 0 ]
  [[ "$output" == *'Direct-to-main commit blocked'* ]] || return 1
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]

  approval
  run env RIG_COMMIT_POLICY=guarded git -C "$TEST_PROJECT" commit -m 'chore: resolved merge [#593]'
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.rig/memory/.rig-commit-ok" ]
  [ ! -e "$(git -C "$TEST_PROJECT" rev-parse --absolute-git-dir)/rig-merge-progress-pending" ]
  hash="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  grep -Fq "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  [ "$(grep -Fc "$hash" "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
}

@test "post-merge honors post-commit executability and native shebang" {
  local hook_dir merge_marker first second
  git -C "$TEST_PROJECT" switch -qc fix/merge-probe-source
  printf 'topic\n' > "$TEST_PROJECT/topic.txt"
  git -C "$TEST_PROJECT" add topic.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'fix: topic [#593]'
  git -C "$TEST_PROJECT" switch -q fix/runtime
  printf 'base\n' > "$TEST_PROJECT/base.txt"
  git -C "$TEST_PROJECT" add base.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'chore: base [#593]'
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null merge --no-ff -qm 'chore: merge topic [#593]' fix/merge-probe-source
  hook_dir="$TEST_PROJECT/.git/hooks"
  merge_marker="$(git -C "$TEST_PROJECT" rev-parse --absolute-git-dir)/rig-merge-progress-pending"
  first="$(git -C "$TEST_PROJECT" rev-parse 'HEAD^1')"
  second="$(git -C "$TEST_PROJECT" rev-parse 'HEAD^2')"
  printf '%s\n%s\n' "$first" "$second" > "$merge_marker"
  chmod -x "$hook_dir/post-commit"
  run env RIG_COMMIT_POLICY=guarded bash -c 'cd "$1" && .git/hooks/post-merge 0' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'post-commit hook is unavailable'* ]] || return 1
  [ ! -e "$merge_marker" ]
  if grep -q 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi

  cat > "$hook_dir/post-commit" <<'PYHOOK'
#!/usr/bin/env python3
import os
with open(os.environ["RIG_TEST_PY_MARKER"], "w") as marker:
    marker.write("executed")
PYHOOK
  chmod +x "$hook_dir/post-commit"
  printf '%s\n%s\n' "$first" "$second" > "$merge_marker"
  run env RIG_COMMIT_POLICY=guarded RIG_TEST_PY_MARKER="$BATS_TEST_TMPDIR/python-post-commit" \
    bash -c 'cd "$1" && .git/hooks/post-merge 0' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/python-post-commit")" = executed ]
  [ ! -e "$merge_marker" ]
}

@test "generated guarded merge logs final SHA and reports a blocked late-footer amend" {
  local hook_dir pre final
  git -C "$TEST_PROJECT" switch -qc fix/footer-source
  printf 'topic\n' > "$TEST_PROJECT/topic.txt"
  git -C "$TEST_PROJECT" add topic.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'fix: topic [#593]'
  git -C "$TEST_PROJECT" switch -q fix/runtime
  printf 'base\n' > "$TEST_PROJECT/base.txt"
  git -C "$TEST_PROJECT" add base.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -qm 'chore: base [#593]'
  hook_dir="$TEST_PROJECT/.git/hooks"
  mv "$hook_dir/commit-msg" "$hook_dir/commit-msg-real"
  cat > "$hook_dir/commit-msg" <<'WRAPPER'
#!/bin/sh
"$(dirname "$0")/commit-msg-real" "$1" || exit $?
printf '\nGenerated with Codex.\n' >> "$1"
WRAPPER
  chmod +x "$hook_dir/commit-msg"
  mv "$hook_dir/post-merge" "$hook_dir/post-merge-real"
  cat > "$hook_dir/post-merge" <<'WRAPPER'
#!/bin/sh
git rev-parse HEAD > "$RIG_TEST_MERGE_PRE_AMEND"
"$(dirname "$0")/post-merge-real" "$@"
WRAPPER
  chmod +x "$hook_dir/post-merge"
  approval
  run env RIG_COMMIT_POLICY=guarded RIG_POST_COMMIT_AUTO_AMEND=1 RIG_TEST_MERGE_PRE_AMEND="$BATS_TEST_TMPDIR/merge-pre" \
    git -C "$TEST_PROJECT" merge --no-ff -m 'chore: merge topic [#593]' fix/footer-source
  [ "$status" -eq 0 ]
  pre="$(cat "$BATS_TEST_TMPDIR/merge-pre")"
  final="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  if [ "$pre" = "$final" ]; then
    [[ "$output" == *'could not amend a late AI footer'* ]] || return 1
  fi
  grep -Fq "$final" "$TEST_PROJECT/.rig/memory/PROGRESS.md"
  [ "$(grep -Fc "$final" "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
  grep -Fq "merge_sha=$final" "$TEST_PROJECT/.rig/memory/.post-merge-pending"
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
  if grep -Fq "$pre" "$TEST_PROJECT/.rig/memory/PROGRESS.md"; then return 1; fi
  [ "$(grep -c 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
  run env RIG_COMMIT_POLICY=guarded bash -c 'cd "$1" && .git/hooks/post-commit-real' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
  payload='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"[fix/runtime abc1234] fix: footer"}}'
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3/templates/project/.claude/hooks/post-tool.sh"' _ "$TEST_PROJECT" "$payload" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Auto-logged' "$TEST_PROJECT/.rig/memory/PROGRESS.md")" -eq 1 ]
}
