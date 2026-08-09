#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MERGER="$REPO_ROOT/installer/merge-codex-config.py"
  TEST_ROOT="$(mktemp -d)"
}

teardown() { rm -rf "$TEST_ROOT"; }

run_no_tomllib_merge() {
  run env _RIG_TEST_NO_TOMLLIB=1 python3 "$MERGER" "$1"
}

assert_fallback_is_top_level() {
  python3 - "$1" <<'PY'
import pathlib, re, sys
section = "top-level"
locations = []
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    stripped = line.strip()
    if stripped.startswith("["):
        section = stripped
    elif re.match(r"^project_doc_fallback_filenames\s*=", stripped):
        locations.append(section)
assert locations == ["top-level"], locations
PY
}

@test "Python 3.9 path inserts fallback before quoted absolute-path table" {
  config="$TEST_ROOT/config with spaces.toml"
  cat > "$config" <<'EOF'
# project trust follows
[projects."/tmp/example"]
trust_level = "trusted"
EOF

  run_no_tomllib_merge "$config"

  [ "$status" -eq 0 ]
  [ "$output" = updated ]
  assert_fallback_is_top_level "$config"
  [ "$(sed -n '/^project_doc_fallback_filenames/p' "$config" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "Python 3.9 path recognizes spaces dots and array-of-table headers" {
  headers=(
    '[projects."/tmp/project with spaces"]'
    '["quoted.key"."child.with.dots"]'
    '[[plugins."vendor/name".tools]]'
  )
  index=0
  for header in "${headers[@]}"; do
    config="$TEST_ROOT/header-$index.toml"
    printf '# before table %s\n%s\nvalue = "kept"\n' "$index" "$header" > "$config"

    run_no_tomllib_merge "$config"

    [ "$status" -eq 0 ]
    assert_fallback_is_top_level "$config"
    /usr/bin/grep -qF "$header" "$config"
    index=$((index + 1))
  done
}

@test "Python 3.9 path preserves an existing top-level fallback exactly" {
  config="$TEST_ROOT/existing.toml"
  cat > "$config" <<'EOF'
# retained comment
project_doc_fallback_filenames = ["TEAM.md", "CLAUDE.md"]
[projects."/tmp/example"]
trust_level = "trusted"
EOF
  before="$(cksum "$config")"

  run_no_tomllib_merge "$config"

  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  [ "$before" = "$(cksum "$config")" ]
  assert_fallback_is_top_level "$config"
}

@test "Python 3.9 path rejects fallback nested under a table without writing" {
  config="$TEST_ROOT/nested.toml"
  cat > "$config" <<'EOF'
[projects."/tmp/example"]
trust_level = "trusted"
project_doc_fallback_filenames = ["CLAUDE.md"]
EOF
  before="$(cksum "$config")"

  run_no_tomllib_merge "$config"

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a top-level setting"* ]] || return 1
  [ "$before" = "$(cksum "$config")" ]
}

@test "Python 3.9 path rejects malformed and ambiguous input without writing" {
  fixtures=(
    $'[projects."/tmp/example"\ntrust_level = "trusted"\n'
    $'project_doc_fallback_filenames = ["ONE.md"]\nproject_doc_fallback_filenames = ["TWO.md"]\n'
    $'project_doc_fallback_filenames = ["CLAUDE.md"\n'
  )
  index=0
  for fixture in "${fixtures[@]}"; do
    config="$TEST_ROOT/malformed-$index.toml"
    printf '%s' "$fixture" > "$config"
    before="$(cksum "$config")"

    run_no_tomllib_merge "$config"

    [ "$status" -eq 1 ]
    [ "$before" = "$(cksum "$config")" ]
    index=$((index + 1))
  done
}
