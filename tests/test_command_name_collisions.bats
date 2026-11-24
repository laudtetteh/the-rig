#!/usr/bin/env bats
#
# tests/test_command_name_collisions.bats — issue #714.
#
# Claude Code lets a project or personal command/skill replace a same-named
# built-in, and refuses custom skills named ship/ship-local/steward. The Rig
# once shipped /status, /code-review, /debug, /run and /ship (and #121 fixed the
# same mistake for /rename without a guard). These tests keep shipped names off
# the reserved list, and prove that upgrading a prior release retires the old
# files safely: unchanged Rig copies are backed up and removed, everything else
# is preserved with a warning.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RESERVED="$REPO_ROOT/installer/reserved-command-names.txt"
PRIOR_RELEASE="v1.29.2"
PRE_498_RELEASE="v1.26.1"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@example.com
  git -C "$TEST_PROJECT" config user.name Test
  git -C "$TEST_PROJECT" commit -q --allow-empty -m init
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Print every reserved name (all providers), one per line.
reserved_names() {
  awk 'NF == 2 && $1 !~ /^#/ { print $2 }' "$RESERVED" | sort -u
}

# Print "kind name" for every name a source tree would install: project
# commands, global skills, global commands, and the Codex skills generated
# from them. Arguments: project commands dir, global skills dir, global
# commands dir.
shipped_names() {
  local commands="$1" global_skills="$2" global_commands="$3" stage f
  for f in "$commands"/*.md; do [ -e "$f" ] && echo "project $(basename "$f" .md)"; done
  for f in "$global_skills"/*.md; do [ -e "$f" ] && echo "global $(basename "$f" .md)"; done
  for f in "$global_commands"/*.md; do [ -e "$f" ] && echo "global $(basename "$f" .md)"; done
  stage="$(mktemp -d "$BATS_TEST_TMPDIR/codex-XXXXXX")"
  python3 "$REPO_ROOT/installer/generate-codex-skills.py" --output "$stage/project" \
    --base-branch main "$commands"/*.md >/dev/null
  python3 "$REPO_ROOT/installer/generate-codex-skills.py" --output "$stage/global" \
    --base-branch main --global-skills-source "$global_skills" >/dev/null
  for f in "$stage"/project/*/; do [ -d "$f" ] && echo "codex-project $(basename "$f")"; done
  for f in "$stage"/global/*/; do [ -d "$f" ] && echo "codex-global $(basename "$f")"; done
  return 0
}

# Print shipped names that are reserved built-ins.
reserved_collisions() {
  local reserved
  reserved="$(reserved_names)"
  shipped_names "$@" | while read -r kind name; do
    if printf '%s\n' "$reserved" | grep -Fxq "$name"; then
      echo "$kind $name"
    fi
  done
}

# Install with a released installer extracted from this repository's tags.
install_release() {
  local version="$1"
  shift
  local old="$BATS_TEST_TMPDIR/installer-$version"
  if [ ! -d "$old" ]; then
    mkdir -p "$old"
    git -C "$REPO_ROOT" archive "$version" | tar -xf - -C "$old"
  fi
  run bash "$old/install.sh" "$@" </dev/null
}

# Run the current installer and strip colour codes from its output.
install_current() {
  run bash "$REPO_ROOT/install.sh" "$@" </dev/null
  output="$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')"
}

# Print the manifest hash recorded for one path, or nothing.
manifest_hash() {
  local manifest="$1" rel="$2"
  grep "  ${rel}\$" "$manifest" 2>/dev/null | awk '{print $1}' | head -1 || true
}

OLD_COMMANDS="status code-review debug run ship"

# ── Reserved-name guard ───────────────────────────────────────────────────────

@test "guard: the reserved list covers both providers and the known collisions" {
  [ -f "$RESERVED" ]
  local claude codex
  claude="$(awk '$1 == "claude" { print $2 }' "$RESERVED")"
  codex="$(awk '$1 == "codex" { print $2 }' "$RESERVED")"
  for name in status code-review debug run ship ship-local steward review rename; do
    printf '%s\n' "$claude" | grep -Fxq "$name" || { echo "claude list missing $name"; return 1; }
  done
  for name in status review init diff; do
    printf '%s\n' "$codex" | grep -Fxq "$name" || { echo "codex list missing $name"; return 1; }
  done
}

@test "guard: no shipped command, skill or generated Codex skill uses a reserved name" {
  local collisions
  collisions="$(reserved_collisions "$REPO_ROOT/templates/project/.claude/commands" \
    "$REPO_ROOT/templates/global/skills" "$REPO_ROOT/templates/global/commands")"
  [ -z "$collisions" ] || { printf 'Reserved names shipped:\n%s\n' "$collisions"; return 1; }
}

@test "guard: a seeded collision is detected" {
  local fake="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$fake/commands" "$fake/skills" "$fake/global-commands"
  cp "$REPO_ROOT/templates/project/.claude/commands/rig-status.md" "$fake/commands/status.md"
  cp "$REPO_ROOT/templates/global/skills/rig-debug-basics.md" "$fake/skills/debug.md"
  run reserved_collisions "$fake/commands" "$fake/skills" "$fake/global-commands"
  [[ "$output" == *"project status"* ]] || return 1
  [[ "$output" == *"global debug"* ]] || return 1
  [[ "$output" == *"codex-project status"* ]] || return 1
}

@test "guard: global and project names never overlap" {
  # A personal skill outranks a project one in Claude Code, and Codex lists
  # same-named skills twice, so the layers must not share a name.
  local project global overlap
  project="$(ls "$REPO_ROOT/templates/project/.claude/commands" | sed 's/\.md$//' | sort)"
  global="$( (ls "$REPO_ROOT/templates/global/skills"; ls "$REPO_ROOT/templates/global/commands") | sed 's/\.md$//' | sort)"
  # rig-upgrade is the one deliberate overlap: the global command is a
  # bootstrap that runs the latest installer's workflow instead of a possibly
  # stale project copy, so it is meant to take precedence.
  overlap="$(comm -12 <(printf '%s\n' "$project") <(printf '%s\n' "$global") | grep -vx 'rig-upgrade' || true)"
  [ -z "$overlap" ] || { printf 'Names in both layers:\n%s\n' "$overlap"; return 1; }
}

@test "guard: the retired names are no longer shipped and rig-status absorbed the dashboard" {
  local commands="$REPO_ROOT/templates/project/.claude/commands" name
  for name in $OLD_COMMANDS; do
    [ ! -e "$commands/$name.md" ] || { echo "$name.md still shipped"; return 1; }
  done
  [ ! -e "$REPO_ROOT/templates/global/skills/code-review.md" ]
  [ ! -e "$REPO_ROOT/templates/global/skills/debug.md" ]
  grep -Fq '/rig-status --health' "$commands/rig-status.md"
  grep -Fq '## Default mode — project dashboard' "$commands/rig-status.md"
  grep -Fq '## Health mode (`--health`)' "$commands/rig-status.md"
}

@test "guard: shipped guidance no longer invokes the retired command names" {
  # Mentions of Claude Code's own built-ins are allowed when they say so.
  local hits
  hits="$(cd "$REPO_ROOT" && git grep -n -E '(^|[^A-Za-z0-9_./$:-])/(status|code-review|debug|run|ship)([^A-Za-z0-9_/:-]|$)' \
    -- templates README.md PROJECT_BRIEF.md docs/how-it-works.md docs/customizing.md \
       docs/troubleshooting.md docs/agent-install.md docs/glossary.md | grep -v -E 'built-in|built in' || true)"
  [ -z "$hits" ] || { printf 'Retired invocations:\n%s\n' "$hits"; return 1; }
}

# ── Upgrade retirement ────────────────────────────────────────────────────────

@test "upgrade: unchanged renamed commands and Codex skills from the prior release are retired" {
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent both
  [ "$status" -eq 0 ]
  local name
  for name in $OLD_COMMANDS; do
    [ -f "$TEST_PROJECT/.claude/commands/$name.md" ] || { echo "fixture lacks $name.md"; return 1; }
    [ -f "$TEST_PROJECT/.agents/skills/$name/SKILL.md" ] || { echo "fixture lacks Codex $name"; return 1; }
  done

  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent both
  [ "$status" -eq 0 ]
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  for name in $OLD_COMMANDS; do
    [ ! -e "$TEST_PROJECT/.claude/commands/$name.md" ] || { echo "$name.md not retired"; return 1; }
    [ ! -e "$TEST_PROJECT/.agents/skills/$name" ] || { echo "Codex $name not retired"; return 1; }
    [ -z "$(manifest_hash "$manifest" ".claude/commands/$name.md")" ] || { echo "stale manifest $name"; return 1; }
    [[ "$output" == *"Retired renamed Rig artifact: .claude/commands/$name.md"* ]] || return 1
  done
  for name in rig-status rig-review rig-debug rig-run rig-ship; do
    [ -f "$TEST_PROJECT/.claude/commands/$name.md" ] || return 1
    [ -f "$TEST_PROJECT/.agents/skills/$name/SKILL.md" ] || return 1
  done
  # The retirement is recorded for rollback: the backup holds the old bytes.
  local backup
  backup="$(find "$TEST_PROJECT/.rig-backup" -name ship.md -type f | head -1)"
  [ -n "$backup" ]
}

@test "upgrade: rollback restores retired commands" {
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent claude
  [ "$status" -eq 0 ]
  local before
  before="$(cat "$TEST_PROJECT/.claude/commands/ship.md")"
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.claude/commands/ship.md" ]
  local id
  id="$("$TEST_PROJECT/bin/rig" upgrade rollback --last --dry-run --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["rollback_id"])')"
  [ -n "$id" ]
  run "$TEST_PROJECT/bin/rig" upgrade rollback --last --confirm "$id"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_PROJECT/.claude/commands/ship.md")" = "$before" ]
  [ -n "$(manifest_hash "$TEST_PROJECT/.rig/memory/.rig-manifest" .claude/commands/ship.md)" ]
}

@test "upgrade: stealth installs retire renamed commands too" {
  local rig_dir="$HOME/.rig/projects/fixture"
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking stealth --rig-dir "$rig_dir" --strategy merge --project-agent claude
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/commands/run.md" ]
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking stealth --rig-dir "$rig_dir" --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.claude/commands/run.md" ]
  [ -f "$TEST_PROJECT/.claude/commands/rig-run.md" ]
  [ -z "$(manifest_hash "$rig_dir/memory/.rig-manifest" .claude/commands/run.md)" ]
}

@test "upgrade: a customized old command is preserved with a warning and flagged by doctor" {
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent claude
  [ "$status" -eq 0 ]
  printf '\n<!-- team ship tweak -->\n' >> "$TEST_PROJECT/.claude/commands/ship.md"
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  grep -Fq 'team ship tweak' "$TEST_PROJECT/.claude/commands/ship.md"
  [[ "$output" == *"Preserved customized renamed Rig artifact: .claude/commands/ship.md (Claude Code never loads a custom command named ship)"* ]] || return 1
  [ ! -e "$TEST_PROJECT/.claude/commands/status.md" ]
  run "$TEST_PROJECT/bin/rig" doctor --json
  printf '%s' "$output" | python3 -c '
import json, sys
check = next(c for c in json.load(sys.stdin)["checks"] if c["name"] == "retired_command_names")
assert check["state"] == "fail", check
assert ".claude/commands/ship.md (use /rig-ship)" in check["detail"], check
'
}

@test "upgrade: a user file at the new name is backed up before the old command is retired" {
  # Rig owns the rig- command namespace: classic upgrade replaces an untracked
  # file at a Rig path after backing it up. Retirement then sees an intact
  # replacement, so the user's content survives only in the backup.
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent claude
  [ "$status" -eq 0 ]
  printf '# my own rig-run\n' > "$TEST_PROJECT/.claude/commands/rig-run.md"
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  local backup
  backup="$(find "$TEST_PROJECT/.rig-backup" -name rig-run.md -type f | head -1)"
  [ -n "$backup" ]
  grep -Fxq '# my own rig-run' "$backup"
  grep -Fq '# Command: /rig-run' "$TEST_PROJECT/.claude/commands/rig-run.md"
  [ ! -e "$TEST_PROJECT/.claude/commands/run.md" ]
}

@test "upgrade: a replacement the upgrade could not install keeps the old command" {
  # A wrong-type path at the new name blocks the copy; the old command must
  # stay so the workflow remains available.
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent claude
  [ "$status" -eq 0 ]
  mkdir "$TEST_PROJECT/.claude/commands/rig-run.md"
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent claude
  [ -f "$TEST_PROJECT/.claude/commands/run.md" ]
  [ -d "$TEST_PROJECT/.claude/commands/rig-run.md" ]
  [[ "$output" == *"Preserved renamed Rig artifact until its replacement is installed: .claude/commands/run.md"* ]] || return 1
}

@test "upgrade: agent-plan reports retirements without changing anything" {
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent claude
  [ "$status" -eq 0 ]
  local before
  before="$(cd "$TEST_PROJECT" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum)"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy agent-plan --project-agent claude </dev/null
  [ "$(cd "$TEST_PROJECT" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum)" = "$before" ]
  printf '%s\n' "$output" | grep -E '^\{' | tail -1 | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["summary"]["removed_obsolete"] >= 5, doc["summary"]
'
}

@test "upgrade: an untouched ship.md from before #498 is proven by release history and retired" {
  install_release "$PRE_498_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent claude
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/commands/ship.md" ]
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.claude/commands/ship.md" ]
  [ -f "$TEST_PROJECT/.claude/commands/rig-ship.md" ]
}

@test "upgrade: user-owned CLAUDE.md naming retired commands gets a warning, a clean one does not" {
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent claude
  [ "$status" -eq 0 ]
  # A known, clean user-owned file first: no retired names, plus shell
  # variables that must not trip the check.
  printf '# Fixture\n\nUse /rig-ship. Exit code is in $status; $run is a variable.\n' > "$TEST_PROJECT/CLAUDE.md"
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  [[ "$output" != *"mentions renamed Rig commands"* ]] || return 1
  printf 'Always run /ship before a PR.\n' >> "$TEST_PROJECT/CLAUDE.md"
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE.md mentions renamed Rig commands"* ]] || return 1
  grep -Fq 'Always run /ship before a PR.' "$TEST_PROJECT/CLAUDE.md"
}

@test "upgrade: a Codex skill with one customized half is preserved whole" {
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent both
  [ "$status" -eq 0 ]
  printf '\nlocal reference note\n' >> "$TEST_PROJECT/.agents/skills/run/references/command.md"
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy upgrade --project-agent both
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.agents/skills/run/SKILL.md" ]
  grep -Fq 'local reference note' "$TEST_PROJECT/.agents/skills/run/references/command.md"
  [[ "$output" == *"Preserved renamed Rig artifact with its skill: .agents/skills/run/SKILL.md"* ]] || return 1
  # The untouched skills are still retired.
  [ ! -e "$TEST_PROJECT/.agents/skills/ship" ]
}

@test "upgrade: switching from both providers to Claude leaves Codex leftovers alone and agrees with agent-plan" {
  install_release "$PRIOR_RELEASE" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy merge --project-agent both
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/install.sh" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy agent-plan --project-agent claude </dev/null
  printf '%s\n' "$output" | grep -E '^\{' | tail -1 > "$BATS_TEST_TMPDIR/plan.json"
  install_current --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --strategy agent-upgrade --project-agent claude
  printf '%s\n' "$output" | grep -E '^\{' | tail -1 > "$BATS_TEST_TMPDIR/apply.json"
  python3 - "$BATS_TEST_TMPDIR/plan.json" "$BATS_TEST_TMPDIR/apply.json" <<'PY'
import json, sys
plan, apply = (json.load(open(p)) for p in sys.argv[1:3])
retired = lambda doc: sorted(a["path"] for a in doc.get("artifacts", []) if a.get("action") == "remove" or a.get("result") == "removed")
codex = lambda paths: [p for p in paths if p.startswith(".agents/")]
assert codex(retired(plan)) == [] and codex(retired(apply)) == [], (retired(plan), retired(apply))
assert plan["summary"]["removed_obsolete"] == apply["summary"]["removed_obsolete"], (plan["summary"], apply["summary"])
assert not any(c.get("path", "").startswith(".agents/skills/") for c in apply.get("conflicts", [])), apply.get("conflicts")
PY
  [ -f "$TEST_PROJECT/.agents/skills/ship/SKILL.md" ]
  [ ! -e "$TEST_PROJECT/.claude/commands/ship.md" ]
}

@test "upgrade: global code-review and debug skills are retired with a backup" {
  install_release "$PRIOR_RELEASE" --global-only --global-agent both --strategy merge
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/skills/code-review/SKILL.md" ] || [ -f "$HOME/.claude/skills/code-review.md" ]
  [ -f "$HOME/.agents/skills/debug/SKILL.md" ]
  install_current --global-only --global-agent both --strategy upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/skills/code-review" ]
  [ ! -e "$HOME/.claude/skills/code-review.md" ]
  [ ! -e "$HOME/.claude/skills/debug" ]
  [ ! -e "$HOME/.agents/skills/code-review" ]
  [ ! -e "$HOME/.agents/skills/debug" ]
  [ -f "$HOME/.claude/skills/rig-review-basics/SKILL.md" ]
  [ -f "$HOME/.agents/skills/rig-debug-basics/SKILL.md" ]
  [[ "$output" == *"global changes are not covered by rig upgrade rollback; see #721"* ]] || return 1
  [ -z "$(manifest_hash "$HOME/.claude/.rig-global-manifest" skills/code-review/SKILL.md)" ]
}

@test "upgrade: a customized global skill is preserved" {
  install_release "$PRIOR_RELEASE" --global-only --global-agent claude --strategy merge
  [ "$status" -eq 0 ]
  local old="$HOME/.claude/skills/debug/SKILL.md"
  [ -f "$old" ] || old="$HOME/.claude/skills/debug.md"
  printf '\nmy note\n' >> "$old"
  install_current --global-only --global-agent claude --strategy upgrade
  [ "$status" -eq 0 ]
  grep -Fq 'my note' "$old"
  [[ "$output" == *"Preserved customized renamed Rig artifact"* ]] || return 1
}
