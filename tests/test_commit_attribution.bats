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
  [[ "$message" == *"Co-authored-by: Jane Doe <jane@example.com>"* ]]
  [[ "$message" == *"Signed-off-by: Jane Doe <jane@example.com>"* ]]
  [[ "$message" == *"Co-authored-by: Claude <claude@example.com>"* ]]
  [[ "$message" != *"noreply@anthropic.com"* ]]
  [[ "$message" != *"noreply@openai.com"* ]]
  [[ "$message" != *"Generated with"* ]]
  [[ "$message" != *"Made-with-Claude"* ]]
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

@test "native hooks preserve human attribution and remove Claude and Codex footers" {
  install_hook_layout native
  commit_with_mixed_trailers
}

@test "Husky hooks preserve human attribution and remove Claude and Codex footers" {
  install_hook_layout husky
  commit_with_mixed_trailers
}

@test "commit-msg refuses a missing filter without stripping human trailers" {
  install_hook_layout native
  rm "$TEST_PROJECT/.git/hooks/filter-commit-message-inplace.sh"
  message_file="$BATS_TEST_TMPDIR/message"
  printf 'fix: example [#589]\n\nCo-authored-by: Jane <jane@example.com>\n' > "$message_file"
  run sh "$TEST_PROJECT/.git/hooks/commit-msg" "$message_file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"filter is missing"* ]]
  grep -q 'Co-authored-by: Jane' "$message_file"
}

@test "post-commit reports late footer without silently changing commit SHA" {
  install_hook_layout native
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit --allow-empty \
    -m 'fix: late footer [#589]' -m 'Generated with Codex.' >/dev/null
  before="$(git -C "$TEST_PROJECT" rev-parse HEAD)"
  run bash -c 'cd "$1" && .git/hooks/post-commit' _ "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"late AI footer"* ]]
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
  [[ "$message" != *"Generated with Codex"* ]]
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
  [[ "$output" == *"signed commit"* ]]
  [ "$(git -C "$TEST_PROJECT" rev-parse HEAD)" = "$signed" ]
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
