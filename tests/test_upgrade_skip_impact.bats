#!/usr/bin/env bats
# A classic upgrade that skips customized Rig files states what each skip
# leaves outdated, reports degraded capabilities, and does not call itself
# complete (#588, #620). The selected strategy is never switched silently.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  EXTERNAL_RIG="$BATS_TEST_TMPDIR/external-rig"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
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
  # Strip colour codes so assertions read plain text.
  output="$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')"
}

@test "a skipped customized enforcement hook is reported as degraded enforcement" {
  install_rig repo merge
  [ "$status" -eq 0 ]
  printf '\n# team note\n' >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  install_rig repo upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"- .claude/hooks/pre-tool.sh — protected-path and commit policy still run your customized older copy"* ]] || return 1
  [[ "$output" == *"Degraded/skipped capabilities: protected-path/commit enforcement (1 customized hook file(s) not updated)"* ]] || return 1
  [[ "$output" == *"not fully converged"* ]] || return 1
  [[ "$output" == *"--strategy agent-plan"* ]] || return 1
  [[ "$output" != *"The Rig upgrade is complete"* ]] || return 1
  [[ "$output" == *"RIG_UPGRADE_REVIEW_REQUIRED=1"* ]] || return 1
}

# Add Codex to a customized Claude-only install through a classic upgrade.
assert_codex_retrofit_reports_divergence() {
  local tracking="$1"
  install_rig "$tracking" merge --project-agent claude
  [ "$status" -eq 0 ]
  printf '\n<!-- local ship tweak -->\n' >> "$TEST_PROJECT/.claude/commands/ship.md"
  install_rig "$tracking" upgrade --project-agent both
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.agents/skills/ship/SKILL.md" ]
  grep -Fq 'local ship tweak' "$TEST_PROJECT/.claude/commands/ship.md"
  [[ "$output" == *'- .claude/commands/ship.md — Claude /ship keeps your customized copy, but the Codex $ship skill was generated from current Rig source'* ]] || return 1
  [[ "$output" == *"Degraded/skipped capabilities: Claude/Codex workflow parity (1 customized command(s))"* ]] || return 1
  [[ "$output" == *"not fully converged"* && "$output" == *"--strategy agent-plan"* ]] || return 1
}

@test "classic Codex retrofit of a customized in-repo install reports provider divergence" {
  assert_codex_retrofit_reports_divergence repo
}

@test "classic Codex retrofit of a customized stealth install reports provider divergence" {
  assert_codex_retrofit_reports_divergence stealth
}

@test "a Claude-only customized command is listed without a provider divergence claim" {
  install_rig repo merge --project-agent claude
  [ "$status" -eq 0 ]
  printf '\n<!-- local ship tweak -->\n' >> "$TEST_PROJECT/.claude/commands/ship.md"
  install_rig repo upgrade --project-agent claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"- .claude/commands/ship.md — Claude /ship keeps your customized older copy"* ]] || return 1
  [[ "$output" != *'Codex $ship'* ]] || return 1
  [[ "$output" == *"Degraded/skipped capabilities: none"* ]] || return 1
}

@test "an upgrade with nothing to review still reports completion" {
  install_rig repo merge
  [ "$status" -eq 0 ]
  install_rig repo upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"The Rig upgrade is complete"* ]] || return 1
  [[ "$output" != *"not fully converged"* ]] || return 1
  [[ "$output" == *"RIG_UPGRADE_REVIEW_REQUIRED=0"* ]] || return 1
}
