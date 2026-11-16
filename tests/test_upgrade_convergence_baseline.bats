#!/usr/bin/env bats
# A converged customization remains different from Rig's template baseline.
# Re-baselining to the merged file makes the next upgrade erase the user's edit.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="${RIG_TEST_INSTALLER:-$REPO_ROOT/install.sh}"

setup() {
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  EXTERNAL_RIG="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q -b main
  git -C "$TEST_PROJECT" config user.email test@example.com
  git -C "$TEST_PROJECT" config user.name Test
  git -C "$TEST_PROJECT" commit -q --allow-empty -m init
}

install_rig() {
  local tracking="$1" strategy="$2"
  local -a args=(--project-only --target "$TEST_PROJECT" --project-name Fixture
                 --tracking "$tracking" --strategy "$strategy")
  [ "$tracking" = stealth ] && args+=(--rig-dir "$EXTERNAL_RIG")
  run bash "$INSTALLER" "${args[@]}" </dev/null
}

file_hash() { shasum -a 256 "$1" | awk '{print $1}'; }

flat_hash() {
  awk -v rel="$2" '$2 == rel { print $1 }' "$1/.rig-manifest"
}

json_hash() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entries"].get(sys.argv[2],{}).get("sha256",""))' \
    "$1/.rig-manifest.json" "$2"
}

assert_baseline() {
  local memory="$1" rel="$2" expected="$3" actual
  actual="$(flat_hash "$memory" "$rel")"
  [ "$actual" = "$expected" ] || { echo "flat manifest baseline changed for $rel: $actual" >&3; return 1; }
  actual="$(json_hash "$memory" "$rel")"
  [ "$actual" = "$expected" ] || { echo "JSON manifest baseline changed for $rel: $actual" >&3; return 1; }
}

assert_preserved() {
  local memory="$1" rel="$2" expected="$3"
  grep -Fq "# user customization of $rel" "$TEST_PROJECT/$rel" || \
    { echo "upgrade erased customization of $rel" >&3; return 1; }
  assert_baseline "$memory" "$rel" "$expected" || return 1
  if [ "$rel" = .claude/hooks/pre-tool.sh ]; then
    python3 -c '
import json, os, sys
mode = format(os.stat(sys.argv[1]).st_mode & 0o777, "o")
recorded = str(json.load(open(sys.argv[2]))["entries"][sys.argv[3]]["mode"])
assert mode == recorded == "755", (mode, recorded)
' "$TEST_PROJECT/$rel" "$memory/.rig-manifest.json" "$rel" || return 1
  fi
}

assert_converged() {
  local rel="$1"
  printf '%s\n' "$output" | python3 -c '
import json, sys
rel = sys.argv[1]
data = json.load(sys.stdin)
assert data["status"] == "success", data["status"]
assert any(a["path"] == rel and a["classification"] == "converged" for a in data["artifacts"]), rel
' "$rel" || { echo "agent-upgrade did not converge $rel" >&3; return 1; }
}

exercise_converged_baseline() {
  local tracking="$1" memory rel
  local -a paths=(.claude/hooks/pre-tool.sh bin/rig .claude/commands/ship.md)
  local -a baselines=()
  [ "$tracking" = stealth ] && memory="$EXTERNAL_RIG/memory" || memory="$TEST_PROJECT/.rig/memory"

  install_rig "$tracking" merge
  [ "$status" -eq 0 ] || { echo "$output" >&3; return 1; }

  for rel in "${paths[@]}"; do
    baselines+=("$(file_hash "$TEST_PROJECT/$rel")")
    assert_baseline "$memory" "$rel" "${baselines[${#baselines[@]}-1]}" || return 1
    if [ "$rel" = .claude/hooks/pre-tool.sh ]; then
      chmod 644 "$TEST_PROJECT/$rel"
    fi
    printf '\n# user customization of %s\n' "$rel" >> "$TEST_PROJECT/$rel"
  done

  install_rig "$tracking" agent-upgrade
  [ "$status" -eq 0 ] || { echo "$output" >&3; return 1; }
  local i
  for ((i=0; i<${#paths[@]}; i++)); do
    assert_converged "${paths[$i]}" || return 1
    assert_preserved "$memory" "${paths[$i]}" "${baselines[$i]}" || return 1
  done

  install_rig "$tracking" agent-upgrade
  [ "$status" -eq 0 ] || { echo "$output" >&3; return 1; }
  for ((i=0; i<${#paths[@]}; i++)); do
    assert_converged "${paths[$i]}" || return 1
    assert_preserved "$memory" "${paths[$i]}" "${baselines[$i]}" || return 1
  done

  install_rig "$tracking" upgrade
  [ "$status" -eq 0 ] || { echo "$output" >&3; return 1; }
  for ((i=0; i<${#paths[@]}; i++)); do
    assert_preserved "$memory" "${paths[$i]}" "${baselines[$i]}" || return 1
  done
}

@test "repo tracking keeps converged hook, dispatcher and placeholder command across repeat upgrades" {
  exercise_converged_baseline repo
}

@test "stealth tracking keeps converged hook, dispatcher and placeholder command across repeat upgrades" {
  exercise_converged_baseline stealth
}
