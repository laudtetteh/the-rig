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

# json_manifest_field MEMORY_DIR REL FIELD — one field of REL's JSON entry.
json_manifest_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entries"].get(sys.argv[2],{}).get(sys.argv[3],""))' \
    "$1/.rig-manifest.json" "$2" "$3"
}

file_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
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
    [ "$(manifest_hash_of "$memory" "$rel")" != "$(file_hash "$TEST_PROJECT/$rel")" ] || \
      { echo "first upgrade adopted the customized flat hash of $rel" >&3; return 1; }
    [ "$(json_manifest_field "$memory" "$rel" sha256)" != "$(file_hash "$TEST_PROJECT/$rel")" ] || \
      { echo "first upgrade adopted the customized JSON hash of $rel" >&3; return 1; }
  done

  install_rig "$tracking" upgrade
  [ "$status" -eq 0 ]
  for rel in "$@"; do
    grep -Fq "# user customization of $rel" "$TEST_PROJECT/$rel" || { echo "second upgrade replaced $rel" >&3; return 1; }
    [[ "$output" == *"skipping customized file: $rel"* ]] || { echo "second upgrade did not report $rel" >&3; return 1; }
    if [[ "$rel" != *.md ]]; then
      [ -x "$TEST_PROJECT/$rel" ] || { echo "$rel lost its executable bit" >&3; return 1; }
    fi
  done
}

@test "in-repo upgrade never adopts a skipped customized hook, Husky hook or dispatcher" {
  install_rig repo merge
  [ "$status" -eq 0 ]
  git -C "$TEST_PROJECT" add -A
  git -C "$TEST_PROJECT" -c core.hooksPath=/dev/null commit -q -m "install rig"
  assert_customizations_survive_repeat_upgrades repo "$TEST_PROJECT/.rig/memory" \
    .claude/hooks/pre-tool.sh .husky/commit-msg bin/rig .claude/commands/rig-ship.md
}

@test "stealth upgrade never adopts a skipped customized hook or dispatcher" {
  install_rig stealth merge
  [ "$status" -eq 0 ]
  assert_customizations_survive_repeat_upgrades stealth "$EXTERNAL_RIG/memory" \
    .claude/hooks/pre-tool.sh bin/rig .claude/commands/rig-ship.md
}

@test "a skipped customized hook keeps the mode its user left" {
  install_rig repo merge
  [ "$status" -eq 0 ]
  printf '\n# disabled locally\n' >> "$TEST_PROJECT/.claude/hooks/stop.sh"
  chmod -x "$TEST_PROJECT/.claude/hooks/stop.sh"
  install_rig repo upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping customized file: .claude/hooks/stop.sh"* ]] || return 1
  [ ! -x "$TEST_PROJECT/.claude/hooks/stop.sh" ]
}

@test "an outdated uncustomized hook is replaced with an accurate flat and JSON baseline" {
  local hook=.claude/hooks/pre-tool.sh memory="$TEST_PROJECT/.rig/memory" old_hash
  install_rig repo merge
  [ "$status" -eq 0 ]
  # Simulate content an older Rig installed: change the hook and record that
  # content as the Rig baseline, so the upgrade must update it.
  printf '\n# content from an older Rig release\n' >> "$TEST_PROJECT/$hook"
  old_hash="$(file_hash "$TEST_PROJECT/$hook")"
  python3 - "$memory" "$hook" "$old_hash" <<'PY'
import json, pathlib, sys
memory, rel, digest = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
flat = memory / ".rig-manifest"
flat.write_text("".join((digest + "  " + rel + "\n") if line.split()[-1:] == [rel] else line + "\n"
                        for line in flat.read_text().splitlines()))
data = json.loads((memory / ".rig-manifest.json").read_text())
data["entries"][rel]["sha256"] = digest
(memory / ".rig-manifest.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
  install_rig repo upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated: $hook"* ]] || return 1
  [ "$(file_hash "$TEST_PROJECT/$hook")" != "$old_hash" ]
  [ "$(manifest_hash_of "$memory" "$hook")" = "$(file_hash "$TEST_PROJECT/$hook")" ]
  [ "$(json_manifest_field "$memory" "$hook" sha256)" = "$(file_hash "$TEST_PROJECT/$hook")" ]
  [ "$(json_manifest_field "$memory" "$hook" mode)" = 755 ]
  [ -x "$TEST_PROJECT/$hook" ]
}

@test "a file rewritten during a manifest conflict still gets its base branch substituted" {
  install_rig repo merge
  [ "$status" -eq 0 ]
  rm "$TEST_PROJECT/.claude/commands/rig-ship.md"
  mv "$TEST_PROJECT/.rig/memory/.rig-manifest.json" "$TEST_PROJECT/.rig/memory/real.json"
  ln -s real.json "$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  install_rig repo upgrade
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/commands/rig-ship.md" ]
  run grep -c '\[BASE_BRANCH\]' "$TEST_PROJECT/.claude/commands/rig-ship.md"
  [ "$output" = 0 ]
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
