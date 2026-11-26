#!/usr/bin/env bats
# Issue #724: BSD mktemp replaces only a trailing run of X's, so the old
# /tmp/rig-settings-*-XXXXXX.json templates created literal paths on macOS and
# concurrent installs collided. The installer now keeps every temp file in a
# private per-run directory under $TMPDIR and removes it on exit.

INSTALLER="$BATS_TEST_DIRNAME/../install.sh"

setup() {
  CASE_DIR="$(mktemp -d)"
  export TMPDIR="$CASE_DIR/tmp"
  mkdir -p "$TMPDIR" "$CASE_DIR/bin"
  LITERAL_CREATED=""
  export MKTEMP_CALLS="$CASE_DIR/mktemp-calls.log"
  export REAL_MKTEMP="$(command -v mktemp)"
  cat > "$CASE_DIR/bin/mktemp" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
created_path=$("$REAL_MKTEMP" "$@")
case "$created_path" in
  "$TMPDIR"/rig-install.*|/tmp/rig-settings-*)
    printf '%s\n' "$created_path" >> "$MKTEMP_CALLS" ;;
esac
printf '%s\n' "$created_path"
WRAPPER
  chmod +x "$CASE_DIR/bin/mktemp"
  export PATH="$CASE_DIR/bin:$PATH"
}

teardown() {
  if [[ -n "$LITERAL_CREATED" ]]; then
    rm -f "$LITERAL_CREATED"
  fi
  rm -rf "$CASE_DIR"
}

# Create a fresh git project and an isolated HOME for one install.
make_project() {
  local name="$1"
  mkdir -p "$CASE_DIR/$name/project" "$CASE_DIR/$name/home"
  git -C "$CASE_DIR/$name/project" init -q
}

install_project() {
  local name="$1"
  HOME="$CASE_DIR/$name/home" bash "$INSTALLER" --project-only \
    --target "$CASE_DIR/$name/project" --project-name "Concurrency${name}" \
    --tracking repo --strategy merge --project-agent claude \
    </dev/null >"$CASE_DIR/$name.log" 2>&1
}

@test "two concurrent project installs both succeed" {
  make_project one
  make_project two
  install_project one &
  local pid_one=$!
  install_project two &
  local pid_two=$!
  local rc_one=0 rc_two=0
  wait "$pid_one" || rc_one=$?
  wait "$pid_two" || rc_two=$?
  [ "$rc_one" -eq 0 ] || { cat "$CASE_DIR/one.log"; return 1; }
  [ "$rc_two" -eq 0 ] || { cat "$CASE_DIR/two.log"; return 1; }
  [ -f "$CASE_DIR/one/project/.claude/settings.json" ]
  [ -f "$CASE_DIR/two/project/.claude/settings.json" ]
}

@test "a leftover literal BSD template path in /tmp does not break the installer" {
  # The pre-#724 installer created exactly this literal path on macOS, so a
  # stale copy made every later install fail with "mkstemp failed".
  local literal="/tmp/rig-settings-rendered-XXXXXX.json"
  if [[ ! -e "$literal" ]]; then
    : >"$literal"
    LITERAL_CREATED="$literal"
  fi
  make_project solo
  run install_project solo
  [ "$status" -eq 0 ] || { cat "$CASE_DIR/solo.log"; return 1; }
}

@test "a successful install removes every temp path created under TMPDIR" {
  make_project clean
  run install_project clean
  [ "$status" -eq 0 ] || { cat "$CASE_DIR/clean.log"; return 1; }
  [ -s "$MKTEMP_CALLS" ] || { echo "installer did not create a tracked temp path"; return 1; }
  while IFS= read -r temp_path; do
    [[ "$temp_path" == "$TMPDIR"/rig-install.* || "$temp_path" == "$TMPDIR"/rig-install.*/* ]] \
      || { echo "temp path escaped the per-run TMPDIR: $temp_path"; return 1; }
    [ ! -e "$temp_path" ] || { echo "temp path remains after install: $temp_path"; return 1; }
  done < "$MKTEMP_CALLS"
  run find "$TMPDIR" -mindepth 1 -print
  [ -z "$output" ]
}

@test "a failed install removes its tracked per-run temp directory" {
  run env HOME="$CASE_DIR/home" bash "$INSTALLER" --project-only \
    --target "$CASE_DIR/does-not-exist" --tracking repo --strategy merge </dev/null
  [ "$status" -ne 0 ]
  [ -s "$MKTEMP_CALLS" ] || { echo "installer did not create its per-run temp directory"; return 1; }
  while IFS= read -r temp_path; do
    [[ "$temp_path" == "$TMPDIR"/rig-install.* || "$temp_path" == "$TMPDIR"/rig-install.*/* ]] \
      || { echo "temp path escaped the per-run TMPDIR: $temp_path"; return 1; }
    [ ! -e "$temp_path" ] || { echo "temp path remains after failed install: $temp_path"; return 1; }
  done < "$MKTEMP_CALLS"
  run find "$TMPDIR" -mindepth 1 -print
  [ -z "$output" ]
}
