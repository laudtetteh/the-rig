#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"
TEMPLATE="$REPO_ROOT/templates/project/.rig/memory/PROJECT_CONVENTIONS.md"
POLICY="$REPO_ROOT/templates/project/.rig/rules/protected-paths.txt"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/test-project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email "test@test.com"
  git -C "$TEST_PROJECT" config user.name "Test"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

run_installer() {
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}

@test "project conventions scaffold is present and committed by default" {
  [ -f "$TEMPLATE" ]
  git -C "$REPO_ROOT" ls-files --error-unmatch \
    templates/project/.rig/memory/PROJECT_CONVENTIONS.md

  run_installer --strategy skip
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.rig/memory/PROJECT_CONVENTIONS.md" ]
  cmp -s "$TEMPLATE" "$TEST_PROJECT/.rig/memory/PROJECT_CONVENTIONS.md"
}

@test "project conventions require explicit approval for material changes" {
  grep -Fq "explicitly approves that exact" "$TEMPLATE"
  grep -Fq "do not add, remove, or" "$TEMPLATE"
  grep -Fq "materially change a convention" "$TEMPLATE"
  grep -Fq "without explicit user" "$REPO_ROOT/templates/project/CLAUDE.md"
  grep -Fq "approval, and do not infer" "$REPO_ROOT/templates/project/CLAUDE.md"
  grep -Fq "one-off request" "$REPO_ROOT/templates/project/.claude/commands/rig-propose.md"
}

@test "project conventions define adversarial content boundaries" {
  local rejected
  for rejected in \
    "secrets, credentials, tokens" \
    "transient state" \
    "copied or paraphrased governance policy" \
    "historical rationale" \
    "inferred, observed, or suggested preferences"; do
    grep -Fq "$rejected" "$TEMPLATE"
  done

  grep -Fq "Consequential rationale, alternatives" \
    "$REPO_ROOT/templates/project/.claude/commands/rig-propose.md"
  grep -Fq "DECISIONS.md" "$TEMPLATE"
}

@test "upgrade preserves a customized project conventions file" {
  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  local conventions="$TEST_PROJECT/.rig/memory/PROJECT_CONVENTIONS.md"
  printf '\n## Approved local rule\n\n**Convention**: Keep this customization.\n**Approved**: 2026-07-31 — explicit user approval\n' >> "$conventions"
  local before
  before="$(cksum "$conventions")"

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]
  [ "$before" = "$(cksum "$conventions")" ]
  grep -Fq "Keep this customization" "$conventions"
}

@test "project conventions remain writable while governance stays protected" {
  ! grep -Fq "[RIG_DIR]/memory/PROJECT_CONVENTIONS.md" "$POLICY"
  grep -Fxq "[RIG_DIR]/processes/" "$POLICY"
  grep -Fxq "[RIG_DIR]/rules/" "$POLICY"
  grep -Fxq "[REPO]/.husky/" "$POLICY"
  grep -Fxq "[REPO]/CLAUDE.md" "$POLICY"
  grep -Fxq "[REPO]/.claude/hooks/" "$POLICY"
}
