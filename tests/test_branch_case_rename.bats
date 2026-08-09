#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COMMAND_DIR="$REPO_ROOT/templates/project/.claude/commands"

setup() {
  TEST_REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$TEST_REPO"
  git -C "$TEST_REPO" config user.email test@example.com
  git -C "$TEST_REPO" config user.name "Branch Rename Test"
  git -C "$TEST_REPO" commit --allow-empty -qm initial
}

load_rename_helper() {
  local command_file="$1"
  eval "$(sed -n '/^# branch-case-rename:start$/,/^# branch-case-rename:end$/p' "$command_file")"
}

@test "task and ship document the identical branch rename helper" {
  run diff \
    <(sed -n '/^# branch-case-rename:start$/,/^# branch-case-rename:end$/p' "$COMMAND_DIR/task.md") \
    <(sed -n '/^# branch-case-rename:start$/,/^# branch-case-rename:end$/p' "$COMMAND_DIR/ship.md")
  [ "$status" -eq 0 ]
}

@test "documented helper performs a case-only rename" {
  cd "$TEST_REPO"
  git branch -M bweb-241
  load_rename_helper "$COMMAND_DIR/task.md"
  rename_branch_case_safe BWEB-241
  [ "$(git branch --show-current)" = "BWEB-241" ]

  load_rename_helper "$COMMAND_DIR/ship.md"
  rename_branch_case_safe bweb-241
  [ "$(git branch --show-current)" = "bweb-241" ]
  [ -z "$(git for-each-ref --format='%(refname:short)' 'refs/heads/tmp/*')" ]
}

@test "ordinary existing-target conflict remains an error" {
  cd "$TEST_REPO"
  original_branch=$(git branch --show-current)
  git branch occupied
  load_rename_helper "$COMMAND_DIR/task.md"

  run rename_branch_case_safe occupied
  [ "$status" -ne 0 ]
  [ "$(git branch --show-current)" = "$original_branch" ]
  git show-ref --verify --quiet refs/heads/occupied
}

@test "case-only rename skips colliding temporary refs" {
  cd "$TEST_REPO"
  git branch -M Example
  git branch tmp/Example-rename
  git branch tmp/Example-rename-1
  load_rename_helper "$COMMAND_DIR/ship.md"

  rename_branch_case_safe example
  [ "$(git branch --show-current)" = "example" ]
  git show-ref --verify --quiet refs/heads/tmp/Example-rename
  git show-ref --verify --quiet refs/heads/tmp/Example-rename-1
  if git show-ref --verify --quiet refs/heads/tmp/Example-rename-2; then return 1; fi
}

@test "failed second step restores the original branch" {
  cd "$TEST_REPO"
  git branch -M RestoreMe
  load_rename_helper "$COMMAND_DIR/task.md"
  git() {
    if [[ "$1" = "branch" && "$2" = "-m" && "$3" = "restoreme" ]]; then
      echo "fatal: simulated target collision" >&2
      return 128
    fi
    command git "$@"
  }

  run rename_branch_case_safe restoreme
  [ "$status" -ne 0 ]
  [ "$(git branch --show-current)" = "RestoreMe" ]
  [[ "$output" == *"restored 'RestoreMe'"* ]] || return 1
  [ -z "$(git for-each-ref --format='%(refname:short)' 'refs/heads/tmp/*')" ]
}
