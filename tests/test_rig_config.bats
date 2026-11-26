#!/usr/bin/env bats
# Shared single-value CLAUDE.md setting reader (bin/rig-config, issue #698).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  READER="$REPO_ROOT/templates/project/bin/rig-config"
  CONFIG="$BATS_TEST_TMPDIR/CLAUDE.md"
}

@test "rig-config: prints a declared value from a fenced settings line" {
  printf '# Project\n\n```\ncommit-cleanup: no\n```\n' > "$CONFIG"
  run python3 "$READER" get "$CONFIG" commit-cleanup --default yes --choices yes,no
  [ "$status" -eq 0 ]
  [ "$output" = no ]
}

@test "rig-config: a missing key returns the caller's default" {
  printf 'issue-tracking: github\n' > "$CONFIG"
  run python3 "$READER" get "$CONFIG" commit-cleanup --default yes --choices yes,no
  [ "$status" -eq 0 ]
  [ "$output" = yes ]
}

@test "rig-config: a missing CLAUDE.md returns the caller's default" {
  run python3 "$READER" get "$BATS_TEST_TMPDIR/absent.md" commit-cleanup --default yes
  [ "$status" -eq 0 ]
  [ "$output" = yes ]
}

@test "rig-config: a missing key without a default exits 3 and prints nothing" {
  printf 'issue-tracking: github\n' > "$CONFIG"
  run python3 "$READER" get "$CONFIG" commit-cleanup
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "rig-config: key matching is case-insensitive and choices are normalised" {
  printf 'Commit-Cleanup: NO   # keep footers\n' > "$CONFIG"
  run python3 "$READER" get "$CONFIG" commit-cleanup --default yes --choices yes,no
  [ "$status" -eq 0 ]
  [ "$output" = no ]
}

@test "rig-config: a duplicate declaration is refused even when one value is blank" {
  printf 'commit-cleanup: no\ncommit-cleanup:\n' > "$CONFIG"
  run python3 "$READER" get "$CONFIG" commit-cleanup --default yes --choices yes,no
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate commit-cleanup setting at lines 1, 2"* ]] || return 1
}

@test "rig-config: a value outside --choices is refused" {
  printf 'commit-cleanup: maybe\n' > "$CONFIG"
  run python3 "$READER" get "$CONFIG" commit-cleanup --default yes --choices yes,no
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected one of: yes, no"* ]] || return 1
}

@test "rig-config: several values on one line are refused" {
  printf 'commit-cleanup: yes no\n' > "$CONFIG"
  run python3 "$READER" get "$CONFIG" commit-cleanup --default yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"must contain one value"* ]] || return 1
}

@test "rig-config: commented-out example lines are not declarations" {
  printf '# commit-cleanup: no\n' > "$CONFIG"
  run python3 "$READER" get "$CONFIG" commit-cleanup --default yes --choices yes,no
  [ "$status" -eq 0 ]
  [ "$output" = yes ]
}

@test "rig-config: a nonregular CLAUDE.md is refused without blocking" {
  mkfifo "$BATS_TEST_TMPDIR/config-pipe"
  run python3 - "$READER" "$BATS_TEST_TMPDIR/config-pipe" <<'PY'
import subprocess, sys
result = subprocess.run([sys.executable, sys.argv[1], "get", sys.argv[2], "commit-cleanup"],
                        capture_output=True, text=True, timeout=5)
print(result.stderr)
raise SystemExit(result.returncode)
PY
  [ "$status" -eq 2 ]
  [[ "$output" == *"regular file"* ]] || return 1
}

@test "rig-config: installer classifies the reader as Rig-owned and snapshots it" {
  grep -q 'bin/rig-tracker-config.py|bin/rig-config|' "$REPO_ROOT/install.sh"
  grep -q '"bin/rig-config" ".git/hooks"' "$REPO_ROOT/install.sh"
}
