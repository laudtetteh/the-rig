#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/project"
  export TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory/sessions" "$TEST_HOME/.rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-index.py" "$CASE_DIR/bin/rig-session-index.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-session-resolve.py" "$CASE_DIR/bin/rig-session-resolve.py"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig_project_roots.py" "$CASE_DIR/bin/rig_project_roots.py"
  git -C "$CASE_DIR" init -q
  unset RIG_PROJECTS_ROOTS
}

@test "configured catalogs discover neighbors and explicit root remains additive" {
  catalog="$BATS_TEST_TMPDIR/catalog"
  neighbor="$catalog/neighbor"
  mkdir -p "$neighbor/bin" "$neighbor/.rig/memory/sessions"
  catalog=$(cd "$catalog" && pwd -P)
  neighbor=$(cd "$neighbor" && pwd -P)
  cp "$CASE_DIR/bin/rig" "$CASE_DIR/bin/rig-session-resolve.py" "$neighbor/bin/"
  git -C "$neighbor" init -q
  "$neighbor/bin/rig" session bind --agent codex --native-session-id configured-neighbor --source startup >/dev/null
  printf '{"schema_version":1,"projects_roots":["%s"]}\n' "$catalog" > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==1 and len(d["coverage"]["scopes"])==2'
  printf '{"schema_version":1,"projects_roots":[]}\n' > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" session index --root "$neighbor" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["sessions"])==1 and "explicit_root" in d["sessions"][0]["provenance"]["sources"]'
}

@test "config roots replace legacy discovery and env overrides config" {
  mkdir -p "$TEST_HOME/code" "$BATS_TEST_TMPDIR/configured" "$BATS_TEST_TMPDIR/override" "$BATS_TEST_TMPDIR/second"
  configured=$(cd "$BATS_TEST_TMPDIR/configured" && pwd -P)
  override=$(cd "$BATS_TEST_TMPDIR/override" && pwd -P)
  second=$(cd "$BATS_TEST_TMPDIR/second" && pwd -P)
  printf '{"schema_version":1,"projects_roots":["%s"]}\n' "$configured" > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; c=json.load(sys.stdin)["coverage"]; assert c["projects_roots_source"]=="config" and c["projects_roots"]==[sys.argv[1]]' "$configured"
  run env HOME="$TEST_HOME" RIG_PROJECTS_ROOTS="$override:$second" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; c=json.load(sys.stdin)["coverage"]; assert c["projects_roots_source"]=="environment" and c["projects_roots"]==sys.argv[1:]' "$override" "$second"
}

@test "empty configured list suppresses legacy root and missing roots are reported" {
  mkdir -p "$TEST_HOME/code"
  printf '{"schema_version":1,"projects_roots":[]}\n' > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; c=json.load(sys.stdin)["coverage"]; assert c["projects_roots_source"]=="config" and c["projects_roots"]==[]'
  printf '{"schema_version":1,"projects_roots":["%s"]}\n' "$BATS_TEST_TMPDIR/missing" > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; c=json.load(sys.stdin)["coverage"]; assert c["missing_projects_roots"]==[sys.argv[1]]' "$BATS_TEST_TMPDIR/missing"
}

@test "invalid config and empty environment fail closed" {
  printf '{"schema_version":1,"projects_roots":["relative"]}\n' > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" session index --json
  [ "$status" -ne 0 ]
  [[ "$output" == *invalid_projects_roots* ]] || return 1
  run env HOME="$TEST_HOME" RIG_PROJECTS_ROOTS='' "$CASE_DIR/bin/rig" session index --json
  [ "$status" -ne 0 ]
}

@test "doctor reports roots as advisory or failure" {
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" doctor --json
  printf '%s' "$output" | python3 -c 'import json,sys; x=next(c for c in json.load(sys.stdin)["checks"] if c["name"]=="projects_roots"); assert x["state"]=="advisory"'
  printf '{"schema_version":1,"projects_roots":["relative"]}\n' > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" doctor --json
  printf '%s' "$output" | python3 -c 'import json,sys; x=next(c for c in json.load(sys.stdin)["checks"] if c["name"]=="projects_roots"); assert x["state"]=="fail"'
  rootfile="$BATS_TEST_TMPDIR/not-a-directory"
  printf 'content\n' > "$rootfile"
  printf '{"schema_version":1,"projects_roots":["%s"]}\n' "$rootfile" > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" doctor --json
  printf '%s' "$output" | python3 -c 'import json,sys; x=next(c for c in json.load(sys.stdin)["checks"] if c["name"]=="projects_roots"); assert x["state"]=="fail"'
  mkdir -p "$BATS_TEST_TMPDIR/real-directory"
  ln -s "$BATS_TEST_TMPDIR/real-directory" "$BATS_TEST_TMPDIR/alias-directory"
  printf '{"schema_version":1,"projects_roots":["%s"]}\n' "$BATS_TEST_TMPDIR/alias-directory" > "$TEST_HOME/.rig/config.json"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" doctor --json
  printf '%s' "$output" | python3 -c 'import json,sys; x=next(c for c in json.load(sys.stdin)["checks"] if c["name"]=="projects_roots"); assert x["state"]=="fail"'
}

@test "doctor treats unsafe legacy code root as advisory" {
  mkdir -p "$BATS_TEST_TMPDIR/real-code"
  ln -s "$BATS_TEST_TMPDIR/real-code" "$TEST_HOME/code"
  run env HOME="$TEST_HOME" "$CASE_DIR/bin/rig" doctor --json
  printf '%s' "$output" | python3 -c 'import json,sys; x=next(c for c in json.load(sys.stdin)["checks"] if c["name"]=="projects_roots"); assert x["state"]=="advisory"'
}

@test "installer writes roots only from explicit flag and upgrade keeps one entry" {
  project="$BATS_TEST_TMPDIR/install-project"
  catalog="$BATS_TEST_TMPDIR/catalog"
  mkdir -p "$project" "$catalog"
  project=$(cd "$project" && pwd -P)
  catalog=$(cd "$catalog" && pwd -P)
  git -C "$project" init -q
  installer="$BATS_TEST_DIRNAME/../install.sh"
  old_source="$BATS_TEST_TMPDIR/old-source"
  mkdir -p "$old_source"
  git -C "$BATS_TEST_DIRNAME/.." archive v1.29.2 | tar -x -C "$old_source"
  run env HOME="$TEST_HOME" bash "$old_source/install.sh" --project-only --target "$project" --tracking repo --strategy merge --project-agent claude
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ ! -e "$TEST_HOME/.rig/config.json" ]
  run env HOME="$TEST_HOME" bash "$installer" --project-only --target "$project" --tracking repo --strategy upgrade --project-agent claude --projects-root "$catalog"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [ -f "$project/bin/rig_project_roots.py" ]
  printf '%s' "$(cat "$TEST_HOME/.rig/config.json")" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d=={"schema_version":1,"projects_roots":[sys.argv[1]]}' "$catalog"
  run env HOME="$TEST_HOME" bash "$installer" --project-only --target "$project" --tracking repo --strategy upgrade --project-agent claude --projects-root "$catalog"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  printf '%s' "$(cat "$TEST_HOME/.rig/config.json")" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["projects_roots"]==[sys.argv[1]]' "$catalog"
}

@test "installer refuses malformed user config before project mutations" {
  project="$BATS_TEST_TMPDIR/untouched-project"
  catalog="$BATS_TEST_TMPDIR/catalog"
  mkdir -p "$project" "$catalog"
  git -C "$project" init -q
  printf '{broken\n' > "$TEST_HOME/.rig/config.json"
  before=$(cksum "$TEST_HOME/.rig/config.json")
  run env HOME="$TEST_HOME" bash "$BATS_TEST_DIRNAME/../install.sh" --project-only --target "$project" --tracking repo --strategy merge --project-agent claude --projects-root "$catalog"
  [ "$status" -ne 0 ]
  [ ! -e "$project/CLAUDE.md" ]
  [ "$(cksum "$TEST_HOME/.rig/config.json")" = "$before" ]
}

@test "installer rejects missing and empty projects-root values without writes" {
  project="$BATS_TEST_TMPDIR/untouched-project"
  mkdir -p "$project"
  git -C "$project" init -q
  installer="$BATS_TEST_DIRNAME/../install.sh"
  run env HOME="$TEST_HOME" bash "$installer" --project-only --target "$project" --tracking repo --strategy merge --projects-root
  [ "$status" -eq 2 ]
  run env HOME="$TEST_HOME" bash "$installer" --project-only --target "$project" --tracking repo --strategy merge --projects-root ''
  [ "$status" -eq 2 ]
  [ ! -e "$project/CLAUDE.md" ]
  [ ! -e "$TEST_HOME/.rig/config.json" ]
}

@test "installer canonicalizes a selected root through a symlink" {
  real="$BATS_TEST_TMPDIR/real-catalog"
  mkdir -p "$real"
  real=$(cd "$real" && pwd -P)
  ln -s "$real" "$BATS_TEST_TMPDIR/catalog-alias"
  run env HOME="$TEST_HOME" python3 "$BATS_TEST_DIRNAME/../installer/set-projects-root.py" check "$BATS_TEST_TMPDIR/catalog-alias"
  [ "$status" -eq 0 ]
  [ "$output" = "$real" ]
  [ ! -e "$TEST_HOME/.rig/config.json" ]
}
