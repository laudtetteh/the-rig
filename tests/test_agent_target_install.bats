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

@test "legacy no-selector project install remains Claude" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/settings.json" ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"
}

@test "codex-only project omits Claude integration and keeps shared Rig core" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent codex --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.claude/settings.json" ]
  [ -f "$TEST_PROJECT/CLAUDE.md" ]
  [ -f "$TEST_PROJECT/.codex/config.toml" ]
  python3 -c 'import ast,pathlib,re,sys; t=pathlib.Path(sys.argv[1]).read_text(); assert ast.literal_eval(re.search(r"project_doc_fallback_filenames\s*=\s*(\[[^]]*\])", t).group(1)) == ["CLAUDE.md"]' "$TEST_PROJECT/.codex/config.toml"
  [ -x "$TEST_PROJECT/bin/rig" ]
  /usr/bin/grep -q '"agents":\["codex"\]' "$TEST_PROJECT/.rig/install-targets.json"
}

@test "project-only none is an exact no-write success" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent none --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$TEST_PROJECT" status --porcelain)" ]
  [ ! -e "$TEST_PROJECT/.rig" ]
}

@test "global-only and both-layer none make no destination or metadata writes" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --global-only --global-agent none --strategy merge
  [ "$status" -eq 0 ]; [ ! -e "$TEST_HOME/.claude" ]; [ ! -e "$TEST_HOME/.rig" ]
  run env HOME="$TEST_HOME" bash "$INSTALLER" --global-agent none --project-agent none --target "$TEST_PROJECT" --strategy merge
  [ "$status" -eq 0 ]; [ ! -e "$TEST_HOME/.claude" ]; [ ! -e "$TEST_HOME/.rig" ]; [ ! -e "$TEST_PROJECT/.rig" ]
}

@test "normal install runs required preflight before writes" {
  run env HOME="$TEST_HOME" _RIG_TEST_MISSING_COMMANDS=claude bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --strategy merge
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_PROJECT/.rig" ]; [ ! -e "$TEST_PROJECT/.claude" ]
  [[ "$output" == *"Required preflight checks failed before writes"* ]] || return 1
}

@test "preflight json without strategy is exactly one JSON document with public operation" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent none --target "$TEST_PROJECT" --preflight --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -s 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.operation')" = install ]
}

@test "preflight json reports the same project destination when stdout is redirected" {
  fake_bin="$TEST_ROOT/bin"; mkdir -p "$fake_bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/claude"
  chmod +x "$fake_bin/claude"
  redirected="$TEST_ROOT/preflight.json"

  run env HOME="$TEST_HOME" PATH="$fake_bin:$PATH" bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --tracking stealth --strategy agent-upgrade --preflight --json
  [ "$status" -eq 0 ]
  direct_status="$(printf '%s' "$output" | jq -r '.dependencies[] | select(.id == "project-destination") | .status')"

  run bash -c 'env HOME="$1" PATH="$2" bash "$3" --project-only --project-agent claude --target "$4" --tracking stealth --strategy agent-upgrade --preflight --json > "$5"' _ "$TEST_HOME" "$fake_bin:$PATH" "$INSTALLER" "$TEST_PROJECT" "$redirected"
  [ "$status" -eq 0 ]
  redirected_status="$(jq -r '.dependencies[] | select(.id == "project-destination") | .status' "$redirected")"

  [ "$direct_status" = ok ]
  [ "$redirected_status" = "$direct_status" ]
}

@test "preflight json annotates unwritable existing project destination without changing v1 status" {
  fake_bin="$TEST_ROOT/bin"; mkdir -p "$fake_bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/claude"
  chmod +x "$fake_bin/claude"
  chmod a-w "$TEST_PROJECT"

  run env HOME="$TEST_HOME" PATH="$fake_bin:$PATH" bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --tracking stealth --strategy agent-upgrade --preflight --json
  chmod u+w "$TEST_PROJECT"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e 'any(.dependencies[]; .id == "project-destination" and .status == "missing" and .detail == "unwritable")' >/dev/null
  printf '%s' "$output" | jq -e 'any(.errors[]; .code == "missing-project-destination")' >/dev/null
  printf '%s' "$output" | jq -e 'any(.warnings[]; .code == "unwritable-project-destination")' >/dev/null
}

@test "public operation maps upgrade and overwrite to upgrade and repair" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent none --target "$TEST_PROJECT" --strategy upgrade --preflight --json
  [ "$(printf '%s' "$output" | jq -r '.operation')" = upgrade ]
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent none --target "$TEST_PROJECT" --strategy overwrite --preflight --json
  [ "$(printf '%s' "$output" | jq -r '.operation')" = repair ]
}

@test "missing selector values exit 2 without writes" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent
  [ "$status" -eq 2 ]; [ ! -e "$TEST_PROJECT/.rig" ]
  run env HOME="$TEST_HOME" bash "$INSTALLER" --global-agent --project-agent none
  [ "$status" -eq 2 ]; [ ! -e "$TEST_HOME/.rig" ]
}

@test "preflight never invokes drift fetch" {
  fake_bin="$TEST_ROOT/bin"; mkdir -p "$fake_bin"
  printf '#!/usr/bin/env bash\nif [[ "$1" == "-C" && "$3" == "fetch" ]]; then echo fetch >> "$FETCH_LOG"; fi\nexec /usr/bin/git "$@"\n' > "$fake_bin/git"
  chmod +x "$fake_bin/git"
  run env HOME="$TEST_HOME" FETCH_LOG="$TEST_ROOT/fetch.log" PATH="$fake_bin:$PATH" bash "$INSTALLER" --project-only --project-agent none --target "$TEST_PROJECT" --preflight --json
  [ "$status" -eq 0 ]; [ ! -e "$TEST_ROOT/fetch.log" ]
}

@test "preflight reports applicable npx and sha256 dependencies" {
  printf '{}\n' > "$TEST_PROJECT/package.json"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --preflight --json
  printf '%s' "$output" | jq -e 'any(.dependencies[]; .id=="sha256" and .classification=="optional")' >/dev/null
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --preflight --json
  printf '%s' "$output" | jq -e 'any(.dependencies[]; .id=="npx" and .classification=="project")' >/dev/null
}

@test "upgrade preserves persisted project target when selector is omitted" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent codex --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy upgrade --tracking repo
  [ "$status" -eq 0 ]
  /usr/bin/grep -q '"agents":\["codex"\]' "$TEST_PROJECT/.rig/install-targets.json"
  [ ! -e "$TEST_PROJECT/.claude/settings.json" ]
}

@test "Codex runtime retrofits an existing Claude-only project when selector is omitted" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.codex" ]

  run env HOME="$TEST_HOME" CODEX_THREAD_ID=codex-runtime bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.codex/hooks.json" ]
  [ -x "$TEST_PROJECT/.codex/hooks/rig-adapter.sh" ]
  [ -f "$TEST_PROJECT/.codex/config.toml" ]
  [ -f "$TEST_PROJECT/.agents/skills/wrap/SKILL.md" ]
  /usr/bin/grep -q '"agents":\["claude","codex"\]' "$TEST_PROJECT/.rig/install-targets.json"
}

@test "explicit Claude selector is not overridden by a Codex runtime" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  run env HOME="$TEST_HOME" CODEX_THREAD_ID=codex-runtime bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.codex" ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"
}

@test "unrelated bin/rig does not make a fresh project auto-select Codex under a Codex runtime" {
  mkdir -p "$TEST_PROJECT/bin"
  printf '#!/usr/bin/env bash\nprintf project-tool\n' > "$TEST_PROJECT/bin/rig"

  run env HOME="$TEST_HOME" CODEX_THREAD_ID=codex-runtime bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"
  [ ! -e "$TEST_PROJECT/.codex" ]
}

@test "invalid selector exits 2 without writes" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent other --target "$TEST_PROJECT" --strategy merge
  [ "$status" -eq 2 ]
  [ ! -e "$TEST_PROJECT/.rig" ]
}

@test "selector for disabled layer is rejected" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --global-agent claude --target "$TEST_PROJECT" --strategy merge
  [ "$status" -eq 2 ]
}

@test "JSON preflight is read-only and schema-versioned" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent none --target "$TEST_PROJECT" --strategy merge --preflight --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"schema_version":1'* ]] || return 1
  [[ "$output" == *'"ok":true'* ]] || return 1
  [ ! -e "$TEST_PROJECT/.rig" ]
}

@test "json without preflight is usage error" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --json
  [ "$status" -eq 2 ]
}

@test "upgrade preflight resolves persisted target and reports destinations and dependencies" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent codex --target "$TEST_PROJECT" --strategy merge --tracking repo
  [ "$status" -eq 0 ]
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy upgrade --preflight --json
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e --arg dest "$TEST_PROJECT" '.layers.project.agents == ["codex"] and .layers.project.destination == $dest and any(.dependencies[]; .id == "codex" and .classification == "required")' >/dev/null
}

@test "upgrade preflight discovers default stealth metadata without a pointer" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent codex --target "$TEST_PROJECT" --strategy merge
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.rig/projects/project/install-targets.json" ]
  rm -f "$TEST_PROJECT/.rigpath"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy upgrade --preflight --json
  printf '%s' "$output" | jq -e '.layers.project.agents == ["codex"]' >/dev/null
}

@test "upgrade preflight discovers explicit external rig-dir metadata" {
  external="$TEST_ROOT/external-rig"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent codex --target "$TEST_PROJECT" --tracking external --rig-dir "$external" --strategy merge
  [ "$status" -eq 0 ]; [ -f "$external/install-targets.json" ]
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --tracking external --rig-dir "$external" --strategy upgrade --preflight --json
  printf '%s' "$output" | jq -e '.layers.project.agents == ["codex"]' >/dev/null
}

@test "upgrade preflight fails closed on conflicting discovered metadata" {
  mkdir -p "$TEST_PROJECT/.rig" "$TEST_HOME/.rig/projects/project"
  printf '{"schema_version":1,"agents":["claude"]}\n' > "$TEST_PROJECT/.rig/install-targets.json"
  printf '{"schema_version":1,"agents":["codex"]}\n' > "$TEST_HOME/.rig/projects/project/install-targets.json"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy upgrade --preflight --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e 'any(.errors[]; .code=="target-metadata-invalid" and (.message | contains("conflicting")))' >/dev/null
}

@test "conclusive repo tracking ignores stale conflicting stealth metadata" {
  mkdir -p "$TEST_PROJECT/.rig" "$TEST_HOME/.rig/projects/project"
  printf '{"schema_version":1,"agents":["codex"]}\n' > "$TEST_PROJECT/.rig/install-targets.json"
  printf '{"schema_version":1,"agents":["claude"]}\n' > "$TEST_HOME/.rig/projects/project/install-targets.json"
  git -C "$TEST_PROJECT" add .rig/install-targets.json
  git -C "$TEST_PROJECT" commit -qm 'test: track rig state'
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy upgrade --preflight --json
  printf '%s' "$output" | jq -e '.layers.project.agents == ["codex"] and .ok == true' >/dev/null
}

@test "conclusive local tracking ignores stale conflicting stealth metadata" {
  mkdir -p "$TEST_PROJECT/.rig" "$TEST_HOME/.rig/projects/project"
  printf '{"schema_version":1,"agents":["codex"]}\n' > "$TEST_PROJECT/.rig/install-targets.json"
  printf '{"schema_version":1,"agents":["claude"]}\n' > "$TEST_HOME/.rig/projects/project/install-targets.json"
  printf '.rig/\n' >> "$TEST_PROJECT/.git/info/exclude"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy upgrade --preflight --json
  printf '%s' "$output" | jq -e '.layers.project.agents == ["codex"] and .ok == true' >/dev/null
}

@test "malformed persisted metadata is a structured preflight error" {
  mkdir -p "$TEST_PROJECT/.rig"
  printf '{bad json\n' > "$TEST_PROJECT/.rig/install-targets.json"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy upgrade --preflight --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e 'any(.errors[]; .code == "target-metadata-invalid")' >/dev/null
}

@test "future metadata requires explicit selector and is not rewritten" {
  mkdir -p "$TEST_PROJECT/.rig"
  printf '{"schema_version":2,"agents":["codex"]}\n' > "$TEST_PROJECT/.rig/install-targets.json"
  before="$(shasum "$TEST_PROJECT/.rig/install-targets.json")"
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --target "$TEST_PROJECT" --strategy upgrade --preflight --json
  [ "$status" -eq 1 ]
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent codex --target "$TEST_PROJECT" --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  [ "$before" = "$(shasum "$TEST_PROJECT/.rig/install-targets.json")" ]
}

@test "unknown manifest smoke type is a hard preflight error" {
  fixture="$TEST_ROOT/bad-capabilities.json"
  printf '{"schema_version":1,"capabilities":[{"id":"bad","layer":"project","agents":["claude"],"smoke":[{"id":"bad","type":"shell","target":"x","required":true}]}]}\n' > "$fixture"
  run env HOME="$TEST_HOME" _RIG_CAPABILITY_MANIFEST="$fixture" bash "$INSTALLER" --project-only --project-agent claude --target "$TEST_PROJECT" --strategy merge --preflight --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e 'any(.errors[]; .code == "capability-manifest-invalid")' >/dev/null
}

@test "required manifest smoke failure does not advance metadata" {
  fixture="$TEST_ROOT/failing-capabilities.json"
  printf '{"schema_version":1,"capabilities":[{"id":"missing","layer":"project","agents":["codex"],"smoke":[{"id":"must-exist","type":"exists","target":"never-created","required":true}]}]}\n' > "$fixture"
  run env HOME="$TEST_HOME" _RIG_CAPABILITY_MANIFEST="$fixture" bash "$INSTALLER" --project-only --project-agent codex --target "$TEST_PROJECT" --tracking repo --strategy merge
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_PROJECT/.rig/install-targets.json" ]
  [[ "$output" == *"Postflight smoke failed"* ]] || return 1
}

@test "final summary reports matrix degradation smoke and Codex next step" {
  run env HOME="$TEST_HOME" bash "$INSTALLER" --project-only --project-agent codex --target "$TEST_PROJECT" --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"Target matrix:"* ]] || return 1
  [[ "$output" == *"Degraded features:"* ]] || return 1
  [[ "$output" == *"Postflight smoke results:"* ]] || return 1
  [[ "$output" == *"Codex: launch 'codex'"* ]] || return 1
}
