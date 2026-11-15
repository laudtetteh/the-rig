#!/usr/bin/env bats
# A customized executable that an upgrade skips must stay customized on every
# later upgrade. The post-copy chmod pass used to refresh its manifest hash to
# the customized content, so the next upgrade treated it as unmodified Rig
# content and silently replaced it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  EXTERNAL_RIG="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@example.com
  git -C "$TEST_PROJECT" config user.name Test
  git -C "$TEST_PROJECT" commit -q --allow-empty -m init
}

# install_rig TRACKING STRATEGY [extra args...]
install_rig() {
  local tracking="$1" strategy="$2"
  shift 2
  local -a args=(--project-only --target "$TEST_PROJECT" --project-name Fixture
                 --tracking "$tracking" --strategy "$strategy")
  [ "$tracking" = stealth ] && args+=(--rig-dir "$EXTERNAL_RIG")
  run bash "$REPO_ROOT/install.sh" "${args[@]}" "$@" </dev/null
}

# manifest_hash_of MEMORY_DIR REL — the flat manifest hash for REL.
manifest_hash_of() {
  awk -v rel="$2" '$2 == rel { print $1 }' "$1/.rig-manifest"
}

# Customize each path, upgrade twice, and require every customization to
# survive with its manifest still pointing at the Rig-installed content.
assert_customizations_survive_repeat_upgrades() {
  local tracking="$1" memory="$2" rel
  shift 2
  for rel in "$@"; do
    printf '\n# user customization of %s\n' "$rel" >> "$TEST_PROJECT/$rel"
  done

  install_rig "$tracking" upgrade
  [ "$status" -eq 0 ]
  for rel in "$@"; do
    [[ "$output" == *"skipping customized file: $rel"* ]] || { echo "first upgrade did not skip $rel" >&3; return 1; }
    [ "$(manifest_hash_of "$memory" "$rel")" != "$(shasum -a 256 "$TEST_PROJECT/$rel" | awk '{print $1}')" ] || \
      { echo "first upgrade adopted the customized hash of $rel" >&3; return 1; }
  done

  install_rig "$tracking" upgrade
  [ "$status" -eq 0 ]
  for rel in "$@"; do
    grep -Fq "# user customization of $rel" "$TEST_PROJECT/$rel" || { echo "second upgrade replaced $rel" >&3; return 1; }
    [[ "$output" == *"skipping customized file: $rel"* ]] || { echo "second upgrade did not report $rel" >&3; return 1; }
    [ -x "$TEST_PROJECT/$rel" ] || { echo "$rel lost its executable bit" >&3; return 1; }
  done
}

@test "in-repo upgrade never adopts a skipped customized hook, Husky hook or dispatcher" {
  install_rig repo merge
  [ "$status" -eq 0 ]
  git -C "$TEST_PROJECT" add -A
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -q -m "install rig"
  assert_customizations_survive_repeat_upgrades repo "$TEST_PROJECT/.rig/memory" \
    .claude/hooks/pre-tool.sh .husky/commit-msg bin/rig
}

@test "stealth upgrade never adopts a skipped customized hook or dispatcher" {
  install_rig stealth merge
  [ "$status" -eq 0 ]
  assert_customizations_survive_repeat_upgrades stealth "$EXTERNAL_RIG/memory" \
    .claude/hooks/pre-tool.sh bin/rig
}

@test "an uncustomized executable stays current and keeps an accurate manifest hash" {
  install_rig repo merge
  [ "$status" -eq 0 ]
  install_rig repo upgrade
  [ "$status" -eq 0 ]
  [ "$(manifest_hash_of "$TEST_PROJECT/.rig/memory" .claude/hooks/pre-tool.sh)" = \
    "$(shasum -a 256 "$TEST_PROJECT/.claude/hooks/pre-tool.sh" | awk '{print $1}')" ]
  [ -x "$TEST_PROJECT/.claude/hooks/pre-tool.sh" ]
}
