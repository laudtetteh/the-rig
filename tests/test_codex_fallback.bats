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

run_codex_install() {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent codex \
    --target "$TEST_PROJECT" --tracking repo --strategy "${1:-merge}"
}

@test "Codex install generates a valid CLAUDE.md fallback config" {
  run_codex_install
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/CLAUDE.md" ]
  [ -f "$TEST_PROJECT/.codex/config.toml" ]
  python3 - "$TEST_PROJECT/.codex/config.toml" <<'PY'
import ast, pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert ast.literal_eval(re.search(r"project_doc_fallback_filenames\s*=\s*(\[[^]]*\])", text).group(1)) == ["CLAUDE.md"]
PY
}

@test "Codex config merge preserves fallback names settings and AGENTS files" {
  mkdir -p "$TEST_PROJECT/.codex"
  cat > "$TEST_PROJECT/.codex/config.toml" <<'EOF'
model = "gpt-test"
project_doc_fallback_filenames = [
  "TEAM.md",
  "LOCAL.md",
  'DOCS\TEAM.md',
]

[projects."/tmp/example"]
trust_level = "trusted"
EOF
  printf 'native instructions\n' > "$TEST_PROJECT/AGENTS.md"
  agents_before="$(cksum "$TEST_PROJECT/AGENTS.md")"

  run_codex_install

  [ "$status" -eq 0 ]
  [ "$agents_before" = "$(cksum "$TEST_PROJECT/AGENTS.md")" ]
  python3 - "$TEST_PROJECT/.codex/config.toml" <<'PY'
import ast, pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
values = ast.literal_eval(re.search(r"project_doc_fallback_filenames\s*=\s*(\[[^]]*\])", text).group(1))
assert values == ["TEAM.md", "LOCAL.md", "DOCS\\TEAM.md", "CLAUDE.md"]
assert 'model = "gpt-test"' in text
assert '[projects."/tmp/example"]' in text and 'trust_level = "trusted"' in text
PY
}

@test "repeated Codex installs are idempotent" {
  run_codex_install
  [ "$status" -eq 0 ]
  first="$(cksum "$TEST_PROJECT/.codex/config.toml")"
  run_codex_install upgrade
  [ "$status" -eq 0 ]
  [ "$first" = "$(cksum "$TEST_PROJECT/.codex/config.toml")" ]
  [ "$(/usr/bin/grep -o 'CLAUDE.md' "$TEST_PROJECT/.codex/config.toml" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "missing fallback key is inserted at top level before existing tables" {
  mkdir -p "$TEST_PROJECT/.codex"
  cat > "$TEST_PROJECT/.codex/config.toml" <<'EOF'
[projects."/tmp/example"]
trust_level = "trusted"
EOF

  run_codex_install

  [ "$status" -eq 0 ]
  first_setting="$(sed -n '/^[^#[:space:]]/p' "$TEST_PROJECT/.codex/config.toml" | head -n 1)"
  [[ "$first_setting" == project_doc_fallback_filenames* ]]
  [ "$(/usr/bin/grep -c '^project_doc_fallback_filenames' "$TEST_PROJECT/.codex/config.toml")" -eq 1 ]
  /usr/bin/grep -q '^\[projects\."/tmp/example"\]$' "$TEST_PROJECT/.codex/config.toml"
}

@test "invalid existing Codex config is preserved and fails closed" {
  mkdir -p "$TEST_PROJECT/.codex"
  printf 'project_doc_fallback_filenames = [broken\n' > "$TEST_PROJECT/.codex/config.toml"
  before="$(cksum "$TEST_PROJECT/.codex/config.toml")"

  run_codex_install

  [ "$status" -eq 1 ]
  [[ "$output" == *"Codex project config was not changed"* ]]
  [ "$before" = "$(cksum "$TEST_PROJECT/.codex/config.toml")" ]
}

@test "Claude-only install does not create Codex config" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent claude \
    --target "$TEST_PROJECT" --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.codex" ]
}
