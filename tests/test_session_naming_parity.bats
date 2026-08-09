#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALLER="$REPO_ROOT/install.sh"
  TEST_ROOT="$(mktemp -d)"
  TEST_HOME="$TEST_ROOT/home"
  TEST_PROJECT="$TEST_ROOT/project"
  mkdir -p "$TEST_HOME" "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
}

teardown() { rm -rf "$TEST_ROOT"; }

run_install() {
  local strategy="${1:-merge}"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only \
    --project-agent both --target "$TEST_PROJECT" --tracking repo \
    --strategy "$strategy"
}

@test "fresh install gives Claude and generated Codex one session-local contract" {
  run_install merge
  [ "$status" -eq 0 ]

  contract="$TEST_PROJECT/.rig/rules/session-naming.md"
  claude="$TEST_PROJECT/.claude/commands/session-name.md"
  codex="$TEST_PROJECT/.agents/skills/session-name/references/command.md"
  [ -f "$contract" ]
  [ -f "$claude" ]
  [ -f "$codex" ]
  run python3 - "$REPO_ROOT" "$claude" "$codex" <<'PY'
import importlib.util
import pathlib
import sys

root, claude, codex = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location(
    "generate_codex_skills", root / "installer/generate-codex-skills.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
commands = {path.stem for path in claude.parent.glob("*.md")}
assert module.rewrite_invocations(claude.read_text(), commands) == codex.read_text()
PY
  [ "$status" -eq 0 ]

  for surface in "$claude" "$codex" \
    "$TEST_PROJECT/.claude/commands/wrap.md" \
    "$TEST_PROJECT/.claude/commands/post-merge.md"; do
    grep -Fq '$RIG_DIR/rules/session-naming.md' "$surface"
    grep -Fq 'Never use `CONTEXT_SNAPSHOT.md`, legacy markers, unrelated session files' "$surface"
  done
}

@test "adversarial cross-session evidence admits only current conversation and UUID" {
  run_install merge
  [ "$status" -eq 0 ]

  rig_dir="$TEST_PROJECT/.rig"
  mkdir -p "$rig_dir/memory/sessions/done"
  cat > "$rig_dir/memory/CONTEXT_SNAPSHOT.md" <<'EOF'
# Stale snapshot
**Session name:** feat unrelated snapshot #111
EOF
  cat > "$rig_dir/memory/PROGRESS.md" <<'EOF'
# Progress
## 2026-07-31 — test current naming parity #392 <!-- sid:current-uuid -->
## 2026-07-30 — feat unrelated UUID work #222 <!-- sid:other-uuid -->
<!-- session-end 2026-07-30 10:00 -->
## 2026-07-29 — fix legacy marker work #333
EOF
  printf '%s\n' '{"anchor":"other-uuid","final_name":"feat unrelated session #444"}' \
    > "$rig_dir/memory/sessions/done/session-other.json"

  run bash -c 'grep "^## .*<!-- sid:${1} -->" "$2/memory/PROGRESS.md"' \
    _ current-uuid "$rig_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *'test current naming parity #392'* ]] || return 1
  [[ "$output" != *'unrelated'* ]] || return 1
  [[ "$output" != *'#222'* ]] || return 1
  [[ "$output" != *'#333'* ]] || return 1
  [[ "$output" != *'#444'* ]] || return 1

  contract="$rig_dir/rules/session-naming.md"
  grep -Fq 'Every unit in a proposed name must be attributable' "$contract"
  grep -Fq 'PROGRESS entries tagged with another session UUID' "$contract"
  grep -Fq 'unscoped or legacy `<!-- session-end -->` marker ranges' "$contract"
  grep -Fq 'never inherit a prior-session name' "$contract"
}

@test "raw launch instructions reject unrelated prior-session fallback" {
  run_install merge
  [ "$status" -eq 0 ]

  for surface in \
    "$TEST_PROJECT/.claude/commands/session-name.md" \
    "$TEST_PROJECT/.agents/skills/session-name/references/command.md" \
    "$TEST_PROJECT/.claude/commands/wrap.md" \
    "$TEST_PROJECT/.claude/commands/post-merge.md"; do
    grep -Fq 'unresolved raw launch' "$surface"
    if grep -Fq 'Fallback — session-end marker boundary' "$surface"; then return 1; fi
    if grep -Fq 'legacy CONTEXT_SNAPSHOT' "$surface"; then return 1; fi
  done
  grep -Fq 'use conversation context only' \
    "$TEST_PROJECT/.claude/commands/session-name.md"
  grep -Fq 'fails closed before any name is proposed or written' \
    "$TEST_PROJECT/.claude/commands/wrap.md"
  grep -Fq 'fails closed before any name is proposed or written' \
    "$TEST_PROJECT/.claude/commands/post-merge.md"
}

@test "upgrade warns when customized generated session-name artifact is preserved" {
  run_install merge
  [ "$status" -eq 0 ]
  codex="$TEST_PROJECT/.agents/skills/session-name/references/command.md"
  printf '\nlegacy customized session naming\n' >> "$codex"

  run_install upgrade
  [ "$status" -eq 0 ]
  grep -Fq 'legacy customized session naming' "$codex"
  [[ "$output" == *'Non-interactive mode — skipping customized file: .agents/skills/session-name/references/command.md'* ]] || return 1
  [[ "$output" == *'Run the installer interactively to review and update this file.'* ]] || return 1
}
