#!/usr/bin/env bats

# Release-facing checks for security boundaries owned by runtime and installer
# lanes. These tests intentionally exercise public interfaces only.

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions/done"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-connector-preflight" "$CASE_DIR/bin/rig-connector-preflight"
  chmod 755 "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-connector-preflight"
  git -C "$CASE_DIR" init -q
  unset RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID
}

@test "public session diagnostics redact native identifiers" {
  result=$("$CASE_DIR/bin/rig" session bind --agent codex --native-session-id release-secret-id)
  session_file=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')

  run env RIG_SESSION_FILE="$session_file" "$CASE_DIR/bin/rig" session current --json
  [ "$status" -eq 0 ]
  [[ "$output" != *release-secret-id* ]]
  [[ "$output" == *'"confidence": "exact"'* ]]
}

@test "private connector evidence rejects symlink and broad permissions" {
  mkdir -p "$CASE_DIR/.rig/connectors"
  printf '{"schema_version":1}\n' > "$CASE_DIR/.rig/connectors/evidence.json"
  chmod 600 "$CASE_DIR/.rig/connectors/evidence.json"
  ln -s "$CASE_DIR/.rig/connectors/evidence.json" "$CASE_DIR/.rig/connectors/evidence-link.json"

  # The preflight command must reject a link before it can follow it.
  run "$CASE_DIR/bin/rig" connector preflight --evidence "$CASE_DIR/.rig/connectors/evidence-link.json" --json
  [ "$status" -ne 0 ]

  chmod 644 "$CASE_DIR/.rig/connectors/evidence.json"
  run "$CASE_DIR/bin/rig" connector preflight --evidence "$CASE_DIR/.rig/connectors/evidence.json" --json
  [ "$status" -ne 0 ]
}

@test "runtime source does not use provider-private state as normal evidence" {
  ! grep -REn \
    '(\.claude|\.codex).*(sqlite|rollout|index)|sqlite.*(\.claude|\.codex)' \
    templates/project/bin templates/project/.claude/hooks templates/project/.codex/hooks
}

@test "release verification requires atomic-write and recovery evidence" {
  run grep -En \
    'atomic|interrupted|rollback|recovery|symlink|redact|gitleaks|shellcheck' \
    docs/release-verification.md
  [ "$status" -eq 0 ]
  for requirement in atomic interrupted rollback symlink redact gitleaks; do
    [[ "$output" == *"$requirement"* ]]
  done
  grep -Fq 'ShellCheck' docs/release-verification.md
}
