#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.name "Test User"
  git -C "$TEST_PROJECT" config user.email "test@example.com"
}

install_hook_layout() {
  local layout="$1" hook_dir
  if [ "$layout" = native ]; then
    hook_dir="$TEST_PROJECT/.git/hooks"
  else
    hook_dir="$TEST_PROJECT/.husky"
    mkdir -p "$hook_dir"
    git -C "$TEST_PROJECT" config core.hooksPath .husky
  fi
  cp "$REPO_ROOT/templates/project/.husky/commit-msg" "$hook_dir/commit-msg"
  cp "$REPO_ROOT/templates/project/.husky/post-commit" "$hook_dir/post-commit"
  cp "$REPO_ROOT/templates/project/.husky/filter-commit-message-inplace.sh" "$hook_dir/filter-commit-message-inplace.sh"
  chmod +x "$hook_dir/commit-msg" "$hook_dir/post-commit"
}

assert_precise_commit_message() {
  local message
  message="$(git -C "$TEST_PROJECT" log -1 --format=%B)"
  [[ "$message" == *"Co-authored-by: Jane Doe <jane@example.com>"* ]] || return 1
  [[ "$message" == *"Signed-off-by: Jane Doe <jane@example.com>"* ]] || return 1
  [[ "$message" == *"Co-authored-by: Claude <claude@example.com>"* ]] || return 1
  [[ "$message" != *"noreply@anthropic.com"* ]] || return 1
  [[ "$message" != *"noreply@openai.com"* ]] || return 1
  [[ "$message" != *"Generated with"* ]] || return 1
  [[ "$message" != *"Made-with-Claude"* ]] || return 1
}

commit_with_mixed_trailers() {
  run env SKIP_COMMIT_VALIDATION=1 git -C "$TEST_PROJECT" commit --allow-empty \
    -m 'fix(hooks): attribution test [#589]' \
    -m 'Co-authored-by: Jane Doe <jane@example.com>
Signed-off-by: Jane Doe <jane@example.com>
Co-authored-by: Claude <claude@example.com>
Co-authored-by: Claude <noreply@anthropic.com>
Co-authored-by: Codex <noreply@openai.com>
🤖 Generated with [Claude Code](https://claude.com).
Generated with [Codex](https://openai.com/codex/).
Generated with Codex.
Made-with-Claude: yes'
  [ "$status" -eq 0 ]
  assert_precise_commit_message
}

commit_with_model_and_copilot_trailers() {
  local layout="$1" hook_dir sha_at_post_commit message
  if [ "$layout" = native ]; then
    hook_dir="$TEST_PROJECT/.git/hooks"
  else
    hook_dir="$TEST_PROJECT/.husky"
  fi

  # Observe HEAD before the real post-commit hook can amend it.
  mv "$hook_dir/post-commit" "$hook_dir/post-commit-real"
  cat > "$hook_dir/post-commit" <<'EOF'
#!/bin/sh
git rev-parse HEAD > "$ATTRIBUTION_TEST_SHA_FILE"
"$(dirname "$0")/post-commit-real"
EOF
  chmod +x "$hook_dir/post-commit"
  sha_at_post_commit="$BATS_TEST_TMPDIR/sha-at-post-commit"

  run env SKIP_COMMIT_VALIDATION=1 RIG_POST_COMMIT_AUTO_AMEND=1 \
    ATTRIBUTION_TEST_SHA_FILE="$sha_at_post_commit" \
    git -C "$TEST_PROJECT" commit --allow-empty \
    -m 'fix(hooks): model attribution test [#589]' \
    -m 'Co-authored-by: Jane Doe <jane@example.com>
Signed-off-by: Jane Doe <jane@example.com>
Co-authored-by: Claude <claude@example.com>
Co-authored-by: Claude Sonnet 4.6 <claude@example.com>
Co-authored-by: Claude Opus 4.6 <claude@example.com>
Co-authored-by: Copilot <human@example.com>
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
Co-authored-by: Claude Opus 4.6 <noreply@anthropic.com>
Co-authored-by: Copilot copilot@github.com
Co-authored-by: GitHub Copilot <copilot@github.com>'
  [ "$status" -eq 0 ]
  [ -s "$sha_at_post_commit" ]
  [ "$(cat "$sha_at_post_commit")" = "$(git -C "$TEST_PROJECT" rev-parse HEAD)" ]

  message="$(git -C "$TEST_PROJECT" log -1 --format=%B)"
  [[ "$message" == *"Co-authored-by: Jane Doe <jane@example.com>"* ]] || return 1
  [[ "$message" == *"Signed-off-by: Jane Doe <jane@example.com>"* ]] || return 1
  [[ "$message" == *"Co-authored-by: Claude <claude@example.com>"* ]] || return 1
  [[ "$message" == *"Co-authored-by: Claude Sonnet 4.6 <claude@example.com>"* ]] || return 1
  [[ "$message" == *"Co-authored-by: Claude Opus 4.6 <claude@example.com>"* ]] || return 1
  [[ "$message" == *"Co-authored-by: Copilot <human@example.com>"* ]] || return 1
  [[ "$message" != *"noreply@anthropic.com"* ]] || return 1
  [[ "$message" != *"copilot@github.com"* ]] || return 1
}

@test "native hooks preserve human attribution and remove Claude and Codex footers" {
  install_hook_layout native
  commit_with_mixed_trailers
}

@test "Husky hooks preserve human attribution and remove Claude and Codex footers" {
  install_hook_layout husky
  commit_with_mixed_trailers
}

@test "native hooks remove Claude Sonnet and Copilot identities without amending" {
  install_hook_layout native
  commit_with_model_and_copilot_trailers native
}

@test "Husky hooks remove Claude Sonnet and Copilot identities without amending" {
  install_hook_layout husky
  commit_with_model_and_copilot_trailers husky
}

@test "commit-msg refuses a missing filter without stripping human trailers" {
  install_hook_layout native
  rm "$TEST_PROJECT/.git/hooks/filter-commit-message-inplace.sh"
  message_file="$BATS_TEST_TMPDIR/message"
  printf 'fix: example [#589]\n\nCo-authored-by: Jane <jane@example.com>\n' > "$message_file"
  run sh "$TEST_PROJECT/.git/hooks/commit-msg" "$message_file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"filter is missing"* ]] || return 1
  grep -q 'Co-authored-by: Jane' "$message_file"
}

@test "post-commit reports late footer without silently changing commit SHA" {
  install_hook_layout native
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit --allow-empty \
    -m 'fix: late footer [#589]' -m 'Generated with Codex.' >/dev/null
  before="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  run bash -c 'cd "$1" && .git/hooks/post-commit' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"late AI footer"* ]] || return 1
  [ "$(git -C "$TEST_PROJECT" rev-parse HEAD)" = "$before" ]

  before_tree="$(git -C "$TEST_PROJECT" rev-parse HEAD^{tree})"
  printf 'other session work\n' > "$TEST_PROJECT/unrelated.txt"
  git -C "$TEST_PROJECT" add unrelated.txt
  run env RIG_POST_COMMIT_AUTO_AMEND=1 bash -c 'cd "$1" && .git/hooks/post-commit' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TEST_PROJECT" rev-parse HEAD)" != "$before" ]
  [ "$(git -C "$TEST_PROJECT" rev-parse HEAD^{tree})" = "$before_tree" ]
  [ "$(git -C "$TEST_PROJECT" diff --cached --name-only)" = unrelated.txt ]
  message="$(git -C "$TEST_PROJECT" log -1 --format=%B)"
  [[ "$message" != *"Generated with Codex"* ]] || return 1
}

@test "post-commit leaves a signed commit untouched even with amend opt-in" {
  install_hook_layout native
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit --allow-empty \
    -m 'fix: signed footer [#589]' -m 'Generated with Codex.' >/dev/null
  before="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  signed="$(git -C "$TEST_PROJECT" cat-file -p HEAD | \
    python3 -c 'import sys; raw=sys.stdin.buffer.read(); pos=raw.index(b"\n\n"); sys.stdout.buffer.write(raw[:pos]+b"\ngpgsig test-signature"+raw[pos:])' | \
    git -C "$TEST_PROJECT" hash-object -t commit -w --stdin)"
  git -C "$TEST_PROJECT" update-ref HEAD "$signed" "$before"

  run env RIG_POST_COMMIT_AUTO_AMEND=1 bash -c 'cd "$1" && .git/hooks/post-commit' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"signed commit"* ]] || return 1
  [ "$(git -C "$TEST_PROJECT" rev-parse HEAD)" = "$signed" ]
}

@test "post-commit warns during a real rebase and preserves replayed history" {
  base_branch="$(git -C "$TEST_PROJECT" branch --show-current)"
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit --allow-empty \
    -m 'chore: base [#594]' >/dev/null
  git -C "$TEST_PROJECT" switch -q -c topic
  printf 'first\n' > "$TEST_PROJECT/first.txt"
  git -C "$TEST_PROJECT" add first.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit \
    -m 'fix: first topic commit [#594]' -m 'Generated with Codex.' >/dev/null
  printf 'second\n' > "$TEST_PROJECT/second.txt"
  git -C "$TEST_PROJECT" add second.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit \
    -m 'fix: second topic commit [#594]' >/dev/null
  git -C "$TEST_PROJECT" switch -q "$base_branch"
  printf 'main\n' > "$TEST_PROJECT/main.txt"
  git -C "$TEST_PROJECT" add main.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit \
    -m 'chore: advance base [#594]' >/dev/null
  base_tip="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  git -C "$TEST_PROJECT" switch -q topic
  install_hook_layout native

  run env RIG_POST_COMMIT_AUTO_AMEND=1 git -C "$TEST_PROJECT" rebase "$base_branch"
  [ "$status" -eq 0 ]
  [[ "$output" == *"during a rebase, cherry-pick, or revert"* ]] || return 1
  [[ "$output" == *"footer remains"* ]] || return 1
  [ "$(git -C "$TEST_PROJECT" rev-parse HEAD~2)" = "$base_tip" ]
  [ "$(git -C "$TEST_PROJECT" rev-list --count "$base_branch"..HEAD)" -eq 2 ]
  [ "$(git -C "$TEST_PROJECT" show HEAD:first.txt)" = first ]
  [ "$(git -C "$TEST_PROJECT" show HEAD:second.txt)" = second ]
  [[ "$(git -C "$TEST_PROJECT" log -1 --format=%B HEAD^)" == *"Generated with Codex."* ]] || return 1
}

@test "post-commit warns during a real cherry-pick and preserves its parent" {
  base_branch="$(git -C "$TEST_PROJECT" branch --show-current)"
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit --allow-empty \
    -m 'chore: base [#594]' >/dev/null
  git -C "$TEST_PROJECT" switch -q -c topic
  printf 'topic\n' > "$TEST_PROJECT/topic.txt"
  git -C "$TEST_PROJECT" add topic.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit \
    -m 'fix: picked commit [#594]' -m 'Generated with Codex.' >/dev/null
  source_commit="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  git -C "$TEST_PROJECT" switch -q "$base_branch"
  printf 'main\n' > "$TEST_PROJECT/main.txt"
  git -C "$TEST_PROJECT" add main.txt
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit \
    -m 'chore: advance base [#594]' >/dev/null
  base_tip="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  install_hook_layout native

  run env RIG_POST_COMMIT_AUTO_AMEND=1 git -C "$TEST_PROJECT" cherry-pick "$source_commit"
  [ "$status" -eq 0 ]
  [[ "$output" == *"during a rebase, cherry-pick, or revert"* ]] || return 1
  [[ "$output" == *"footer remains"* ]] || return 1
  [ "$(git -C "$TEST_PROJECT" rev-parse HEAD^)" = "$base_tip" ]
  [ "$(git -C "$TEST_PROJECT" show HEAD:topic.txt)" = topic ]
  [[ "$(git -C "$TEST_PROJECT" log -1 --format=%B)" == *"Generated with Codex."* ]] || return 1
}

@test "stealth installer and upgrade place the precise filter beside native hooks" {
  external_rig="$BATS_TEST_TMPDIR/rig-external"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$external_rig" --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.git/hooks/filter-commit-message-inplace.sh" ]
  commit_with_mixed_trailers
  run bash "$REPO_ROOT/install.sh" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking stealth --rig-dir "$external_rig" --strategy upgrade
  [ "$status" -eq 0 ]
  commit_with_mixed_trailers
}
