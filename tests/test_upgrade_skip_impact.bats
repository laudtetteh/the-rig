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
  # Preflight may add environment-dependent items (for example a missing
  # gitleaks), so tests inspect only this one line for skip-derived items.
  DEGRADED="$(printf '%s\n' "$output" | grep '^Degraded/skipped capabilities:' || true)"
}

@test "a skipped customized enforcement hook is reported as degraded enforcement" {
  # Relative paths and quotes in names must remain copyable in the printed
  # route, and an explicit non-main base branch must be carried forward.
  cd "$BATS_TEST_TMPDIR"
  mv "$TEST_PROJECT" 'project"odd'
  TEST_PROJECT='project"odd'
  install_rig repo merge --base-branch develop
  [ "$status" -eq 0 ]
  printf '\n# team note\n' >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"
  install_rig repo upgrade --base-branch develop
  [ "$status" -eq 0 ]
  [[ "$output" == *"- .claude/hooks/pre-tool.sh — protected-path and commit policy still run your customized older copy"* ]] || return 1
  [[ "$DEGRADED" == *"protected-path/commit enforcement (1 customized hook file(s) not updated)"* ]] || return 1
  [[ "$output" == *"not fully converged"* ]] || return 1
  [[ "$output" == *"--strategy agent-plan"* ]] || return 1
  local expected_target
  expected_target="$(printf '%q' "$BATS_TEST_TMPDIR/project\"odd")"
  [[ "$output" == *"$REPO_ROOT/install.sh --project-only --target $expected_target --base-branch develop"* ]] || return 1
  [[ "$output" != *"The Rig upgrade is complete"* ]] || return 1
  [[ "$output" == *"RIG_UPGRADE_REVIEW_REQUIRED=1"* ]] || return 1
}

# Add Codex to a customized Claude-only install through a classic upgrade.
assert_codex_retrofit_reports_divergence() {
  local tracking="$1"
  shift
  local -a extra=("$@")
  install_rig "$tracking" merge --project-agent claude "${extra[@]}"
  [ "$status" -eq 0 ]
  printf '\n<!-- local ship tweak -->\n' >> "$TEST_PROJECT/.claude/commands/ship.md"
  install_rig "$tracking" upgrade --project-agent both "${extra[@]}"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.agents/skills/ship/SKILL.md" ]
  grep -Fq 'local ship tweak' "$TEST_PROJECT/.claude/commands/ship.md"
  [[ "$output" == *'- .claude/commands/ship.md — Claude /ship keeps your customized copy, but the Codex $ship skill was generated from current Rig source'* ]] || return 1
  [[ "$DEGRADED" == *"Claude/Codex workflow parity (1 customized command(s))"* ]] || return 1
  [[ "$output" == *"not fully converged"* && "$output" == *"--strategy agent-plan"* ]] || return 1
}

@test "classic Codex retrofit of a customized in-repo install reports provider divergence" {
  assert_codex_retrofit_reports_divergence repo
}

@test "printed convergence route preserves the selected project agent after metadata conflict" {
  install_rig repo merge --project-agent claude
  [ "$status" -eq 0 ]
  printf '\n<!-- local ship tweak -->\n' >> "$TEST_PROJECT/.claude/commands/ship.md"
  mv "$TEST_PROJECT/.rig/install-targets.json" "$TEST_PROJECT/.rig/install-targets.real.json"
  ln -s install-targets.real.json "$TEST_PROJECT/.rig/install-targets.json"
  install_rig repo upgrade --project-agent both
  [ "$status" -eq 0 ]
  [[ "$output" == *"Postflight targets: project=both"* ]] || return 1
  [[ "$output" == *"Preserved conflicting upgrade destination: .rig/install-targets.json (symlink)"* ]] || return 1
  [[ "$output" == *"--project-agent both --tracking repo --strategy agent-plan"* ]] || return 1
}

@test "classic Codex retrofit of a customized stealth install reports provider divergence" {
  assert_codex_retrofit_reports_divergence stealth --skip-git-hooks
  # The printed route must reproduce this run's tracking, or agent-plan would
  # re-detect the install and plan the wrong files.
  [[ "$output" == *"--tracking stealth --rig-dir $EXTERNAL_RIG --skip-git-hooks --strategy agent-plan"* ]] || return 1
  [ ! -e "$TEST_PROJECT/.git/hooks/pre-commit" ]
}

@test "a global-only customization in a combined upgrade does not suggest a project-only convergence route" {
  local fixture_home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$fixture_home"
  run env HOME="$fixture_home" bash "$REPO_ROOT/install.sh" \
    --target "$TEST_PROJECT" --project-name Fixture --tracking repo \
    --global-agent claude --project-agent claude --strategy merge </dev/null
  [ "$status" -eq 0 ]
  printf '\n<!-- custom global skill -->\n' >> "$fixture_home/.claude/skills/explain/SKILL.md"
  run env HOME="$fixture_home" bash "$REPO_ROOT/install.sh" \
    --target "$TEST_PROJECT" --project-name Fixture --tracking repo \
    --global-agent claude --project-agent claude --strategy upgrade </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping customized file: skills/explain/SKILL.md"* ]] || return 1
  [[ "$output" != *"To converge customized project files"* ]] || return 1
  [[ "$output" == *"Review each listed file"* ]] || return 1
}

@test "a Claude-only customized command is listed without a provider divergence claim" {
  install_rig repo merge --project-agent claude
  [ "$status" -eq 0 ]
  printf '\n<!-- local ship tweak -->\n' >> "$TEST_PROJECT/.claude/commands/ship.md"
  install_rig repo upgrade --project-agent claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"- .claude/commands/ship.md — Claude /ship keeps your customized older copy"* ]] || return 1
  [[ "$output" != *'Codex $ship'* ]] || return 1
  [ -n "$DEGRADED" ]
  [[ "$DEGRADED" != *"parity"* && "$DEGRADED" != *"enforcement"* ]] || return 1
}

@test "review required only by a manifest conflict does not recommend agent-upgrade" {
  install_rig repo merge
  [ "$status" -eq 0 ]
  mv "$TEST_PROJECT/.rig/memory/.rig-manifest.json" "$TEST_PROJECT/.rig/memory/real.json"
  ln -s real.json "$TEST_PROJECT/.rig/memory/.rig-manifest.json"
  install_rig repo upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped customized: 0"* ]] || return 1
  [[ "$output" == *"not fully converged"* ]] || return 1
  [[ "$output" != *"--strategy agent-plan"* ]] || return 1
  [[ "$output" == *"Review each listed file"* ]] || return 1
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
