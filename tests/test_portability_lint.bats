#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CASE_DIR="$BATS_TEST_TMPDIR/case"
  mkdir -p "$CASE_DIR/docs"
  git -C "$CASE_DIR" init -q
  export LINT="$BATS_TEST_DIRNAME/lint-portability.py"
}

@test "shipped portability guidance uses PATH tools and portable migration examples" {
  local kickoff="$REPO_ROOT/templates/project/.claude/commands/kickoff.md"
  local adapter="$REPO_ROOT/templates/project/.codex/hooks/rig-adapter.sh"
  local upgrade="$REPO_ROOT/templates/project/.claude/commands/rig-upgrade.md"
  local workflow="$REPO_ROOT/templates/project/.rig/processes/UPGRADE_WORKFLOW.md"
  ! grep -Fq '/usr/bin/grep' "$kickoff"
  ! grep -Fq '/usr/bin/grep' "$adapter"
  grep -Fq 'command -v grep' "$kickoff"
  grep -Fq 'command -v grep' "$adapter"
  ! grep -Fq '/Users/*/' "$upgrade"
  grep -Fq 'sha256sum' "$upgrade"
  grep -Fq 'shasum -a 256' "$upgrade"
  grep -Fq 'sha256sum' "$workflow"
  grep -Fq 'shasum -a 256' "$workflow"
  grep -Fq 'Bash 3.2+' "$REPO_ROOT/README.md"
  grep -Fq 'Python 3.9+' "$REPO_ROOT/README.md"
  grep -Fq 'Git 2.23+' "$REPO_ROOT/README.md"
  grep -Fq 'jq` is not required' "$REPO_ROOT/README.md"
}

@test "portability lint permits the approved README pilot credit" {
  printf 'It was subsequently piloted on [%s%s.org](https://%sculture.org), a shared-repo platform.\n' '4' 'Culture' '4' > "$CASE_DIR/README.md"
  git -C "$CASE_DIR" add README.md
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 0 ]
}

@test "portability lint rejects a second README pilot mention" {
  printf 'The private pilot was %s%s.\n' '4' 'Culture' > "$CASE_DIR/README.md"
  git -C "$CASE_DIR" add README.md
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *pilot_name* ]] || return 1
}

@test "portability lint rejects private names and home paths in tracked docs" {
  printf 'Name: %s%s\nPath: /Users/%s/code\n' beacon avenue actual-person > "$CASE_DIR/docs/example.md"
  git -C "$CASE_DIR" add docs/example.md
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *private_identifier* && "$output" == *personal_home* ]] || return 1
}

@test "portability lint ignores untracked local notes" {
  printf 'Name: %s%s\n' beacon avenue > "$CASE_DIR/docs/local.md"
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 0 ]
}

@test "portability lint distinguishes suffixed mktemp templates from portable forms" {
  mkdir -p "$CASE_DIR/scripts"
  printf 'a="$(mktemp /tmp/rig-example-%s.json)"\nb="$(mktemp /tmp/rig-example-%s/child)"\nc="$(mktemp /tmp/rig-example-%s:suffix)"\nd="$(mktemp /tmp/rig-example-%s+suffix)"\ne="$(mktemp /tmp/rig-example-%s,suffix)"\n' \
    XXXXXX XXXXXX XXXXXX XXXXXX XXXXXX > "$CASE_DIR/scripts/template.sh"
  git -C "$CASE_DIR" add scripts/template.sh
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'mktemp_suffix')" -eq 5 ] || return 1

  printf 'a="$(mktemp "${TMPDIR:-/tmp}/rig-example.%s")"\nb="$(mktemp -d /tmp/rig-dir-%s)"\nc="$(mktemp "${f}.tmp.%s")"\n' \
    XXXXXX XXXXXX XXXXXX > "$CASE_DIR/scripts/template.sh"
  git -C "$CASE_DIR" add scripts/template.sh
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 0 ]
}
