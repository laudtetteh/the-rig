#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/connectors" "$CASE_DIR/.rig/memory"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-connector-preflight" "$CASE_DIR/bin/rig-connector-preflight"
  chmod +x "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-connector-preflight"
  git -C "$CASE_DIR" init -q
  bind_session
  write_declaration
}

bind_session() {
  run "$CASE_DIR/bin/rig" session bind --agent codex --native-session-id connector-native --source startup
  [ "$status" -eq 0 ]
  export SESSION_FILE="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')"
  export RIG_SESSION_FILE="$SESSION_FILE"
}

write_declaration() {
  cat > "$CASE_DIR/.rig/connectors/skill-dependencies.v1.json" <<'JSON'
{"schema":"https://the-rig.dev/schemas/skill-connector-dependencies/v1","schema_version":1,"skills":[{"id":"sprint","requirements":[{"id":"tracker-read","required":true,"selection":"any","minimum_stage":"callable","providers":["github-mcp"],"capabilities":["tracker.issue.read"]}]}],"providers":{"github-mcp":{"runtime":["claude","codex"],"configuration_probes":["public_runtime_registration"],"authentication":"runtime_or_public_cli","tools":[{"capability":"tracker.issue.read","names":["mcp__github__get_issue"]}],"smoke_checks":["github.identity-metadata.v1"]}},"smoke_checks":{"github.identity-metadata.v1":{"safety":"read_only_metadata","timeout_ms":5000,"max_attempts":1,"arguments":{},"success":"schema_valid_response"}}}
JSON
}

write_evidence() {
  local outcome="${1:-success}" revision_offset="${2:-0}"
  DECLARATION="$CASE_DIR/.rig/connectors/skill-dependencies.v1.json" SESSION_FILE="$SESSION_FILE" OUT="$CASE_DIR/evidence.json" OUTCOME="$outcome" OFFSET="$revision_offset" python3 <<'PY'
import datetime,hashlib,json,os
with open(os.environ["DECLARATION"]) as f: declaration=json.load(f)
with open(os.environ["SESSION_FILE"]) as f: session=json.load(f)
digest="sha256:"+hashlib.sha256(json.dumps(declaration,sort_keys=True,separators=(",",":")).encode()).hexdigest()
tools=[{"canonical_name":"mcp__github__get_issue","schema_hash":"sha256:"+"2"*64}]
inventory="sha256:"+hashlib.sha256(json.dumps(tools,sort_keys=True,separators=(",",":")).encode()).hexdigest()
evidence={"schema":"https://the-rig.dev/schemas/connector-preflight-evidence/v1","schema_version":1,"runtime":"codex","session":{"anchor":session["anchor"],"revision":session["revision"]+int(os.environ["OFFSET"]),"root_attribution":True},"collector_agent_kind":"root","inventory_fingerprint":inventory,"tools":tools,"observations":[{"provider":"github-mcp","configured":"pass","authentication":"pass","smoke":{"id":"github.identity-metadata.v1","outcome":os.environ["OUTCOME"],"duration_bucket":"lt_1s"}}],"declaration_digest":digest,"collector_version":1,"collected_at":datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(os.environ["OUT"],"w") as f: json.dump(evidence,f,separators=(",",":"))
os.chmod(os.environ["OUT"],0o600)
PY
}

@test "session-native evidence reaches callable and is cached per exact session" {
  write_evidence success
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/evidence.json" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.ok and .state=="callable" and .providers[0].confirmed_stage=="callable" and .session.confidence=="exact"' >/dev/null
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/evidence.json" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.cache.status=="hit"' >/dev/null
}

@test "visible tool permission denial is blocked at callable" {
  write_evidence permission_denied
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/evidence.json" --refresh --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.state=="blocked" and .providers[0].confirmed_stage=="schema_visible" and .providers[0].blocked_at=="callable" and .providers[0].reason=="permission_denied"' >/dev/null
}

@test "exact session revision mismatch fails unavailable without cache write" {
  write_evidence success 1
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/evidence.json" --json
  [ "$status" -eq 69 ]
  printf '%s' "$output" | jq -e '.errors[0].reason=="session_mismatch"' >/dev/null
}

@test "private evidence contract rejects symlinks and broad permissions" {
  write_evidence success
  ln -s "$CASE_DIR/evidence.json" "$CASE_DIR/link.json"
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/link.json" --json
  [ "$status" -eq 65 ]
  chmod 644 "$CASE_DIR/evidence.json"
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/evidence.json" --json
  [ "$status" -eq 65 ]
}

@test "unknown declaration fields and duplicate JSON keys fail closed" {
  printf '{"schema_version":1,"schema_version":1}\n' > "$CASE_DIR/bad.json"
  chmod 600 "$CASE_DIR/bad.json"
  run env _RIG_CONNECTOR_DECLARATION="$CASE_DIR/bad.json" RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/bad.json" --json
  [ "$status" -eq 65 ]
  printf '%s' "$output" | jq -e '.errors[0].reason=="declaration_invalid"' >/dev/null
}

@test "concurrent evaluators leave a private valid cache entry" {
  write_evidence success
  run bash -c 'for i in 1 2 3 4; do RIG_SESSION_FILE="$1" "$2/bin/rig" connector preflight --skill sprint --evidence "$2/evidence.json" --refresh --json >/dev/null & done; wait' _ "$SESSION_FILE" "$CASE_DIR"
  [ "$status" -eq 0 ]
  cache="$(find "$CASE_DIR/.rig/memory/cache/connector-preflight-v1" -name '*.json' -type f | head -1)"
  [ -n "$cache" ]
  [ "$(stat -f '%Lp' "$cache")" = 600 ]
  jq -e '.result.state=="callable"' "$cache" >/dev/null
}

@test "invalid cache symlink fails closed and is not overwritten" {
  write_evidence success
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/evidence.json" --json
  [ "$status" -eq 0 ]
  cache="$(find "$CASE_DIR/.rig/memory/cache/connector-preflight-v1" -name '*.json' -type f | head -1)"
  target="$CASE_DIR/user-file"; printf 'preserve\n' > "$target"
  rm "$cache"; ln -s "$target" "$cache"
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/evidence.json" --json
  [ "$status" -eq 65 ]
  printf '%s' "$output" | jq -e '.errors[0].reason=="cache_invalid"' >/dev/null
  [ "$(cat "$target")" = preserve ]
  run env RIG_SESSION_FILE="$SESSION_FILE" "$CASE_DIR/bin/rig" connector preflight --skill sprint --evidence "$CASE_DIR/evidence.json" --refresh --json
  [ "$status" -eq 65 ]
  [ "$(cat "$target")" = preserve ]
}
