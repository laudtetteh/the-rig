#!/usr/bin/env bats
# Backed-up Codex skill parity repair (#604): `rig doctor fix --check
# codex_skill_parity` previews by default, and with --confirm regenerates
# drifted generated skills and copied skills exactly as the installer would,
# backs up every replaced file, never deletes extra or user-owned files, and
# refuses what it cannot generate safely.

setup_file() {
  export INSTALLED="$BATS_FILE_TMPDIR/installed"
  mkdir -p "$INSTALLED"
  git -C "$INSTALLED" init -q
  git -C "$INSTALLED" commit -q --allow-empty -m init
  bash "$BATS_TEST_DIRNAME/../install.sh" --project-only --target "$INSTALLED" --project-name Parity \
    --tracking repo --project-agent both --strategy merge >/dev/null 2>&1
}

setup() {
  unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID RIG_SESSION_FILE RIG_SESSION_ANCHOR RIG_SESSION_PID RIG_AGENT
  PROJECT="$BATS_TEST_TMPDIR/project"
  cp -R "$INSTALLED" "$PROJECT"
  PRISTINE="$INSTALLED"
}

fix() {
  run bash -c 'cd "$1" && shift && bin/rig doctor fix --check codex_skill_parity "$@"' _ "$PROJECT" "$@"
}

parity_state() {
  (cd "$PROJECT" && bin/rig doctor --json) | python3 -c 'import json,sys; print(next(c["state"] for c in json.load(sys.stdin)["checks"] if c["name"]=="codex_skill_parity"))'
}

@test "parity repair: a clean install is already complete" {
  fix --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"already_complete"'* ]] || return 1
}

@test "parity repair: preview lists only drifted files and writes nothing" {
  printf '\nlocal edit\n' >> "$PROJECT/.agents/skills/wrap/references/command.md"
  rm "$PROJECT/.agents/skills/ship/SKILL.md"
  local before
  before="$(cd "$PROJECT" && find .agents -type f -exec shasum {} + | sort)"
  fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"Doctor fix preview: 2 file(s) would be written"* ]] || return 1
  [[ "$output" == *"replace: .agents/skills/wrap/references/command.md"* ]] || return 1
  [[ "$output" == *"create: .agents/skills/ship/SKILL.md"* ]] || return 1
  [[ "$output" != *"ship/references/command.md"* ]] || return 1
  [ "$before" = "$(cd "$PROJECT" && find .agents -type f -exec shasum {} + | sort)" ]
  [ ! -e "$PROJECT/.rig/backups/doctor-fix" ]
}

@test "parity repair: confirm restores installer-identical files and backs up what it replaced" {
  printf '\nlocal edit\n' >> "$PROJECT/.agents/skills/wrap/references/command.md"
  rm "$PROJECT/.agents/skills/ship/SKILL.md"
  local edited
  edited="$(shasum < "$PROJECT/.agents/skills/wrap/references/command.md")"
  fix --confirm --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"applied"'* && "$output" == *'"check_after":"pass"'* ]] || return 1
  cmp -s "$PRISTINE/.agents/skills/wrap/references/command.md" "$PROJECT/.agents/skills/wrap/references/command.md"
  cmp -s "$PRISTINE/.agents/skills/ship/SKILL.md" "$PROJECT/.agents/skills/ship/SKILL.md"
  local backup
  backup="$(find "$PROJECT/.rig/backups/doctor-fix" -name command.md -path '*wrap*')"
  [ "$(shasum < "$backup")" = "$edited" ]
  python3 - "$PROJECT/.rig/backups/doctor-fix" <<'PY'
import json, pathlib, sys
manifest = json.loads(next(pathlib.Path(sys.argv[1]).glob("*/manifest.json")).read_text())
paths = {entry["path"]: entry for entry in manifest["files"]}
assert set(paths) == {".agents/skills/wrap/references/command.md", ".agents/skills/ship/SKILL.md"}, paths
assert "backup" in paths[".agents/skills/wrap/references/command.md"]
assert paths[".agents/skills/ship/SKILL.md"]["action"] == "create"
PY
  [ "$(parity_state)" = pass ]
}

@test "parity repair: copied Claude skills are re-copied and extra mirror files are kept" {
  mkdir -p "$PROJECT/.claude/skills/helper" "$PROJECT/.agents/skills/helper"
  printf 'canonical\n' > "$PROJECT/.claude/skills/helper/SKILL.md"
  printf 'stale\n' > "$PROJECT/.agents/skills/helper/SKILL.md"
  printf 'mine\n' > "$PROJECT/.agents/skills/helper/notes.md"
  fix --confirm
  [ "$status" -eq 3 ]
  [ "$(cat "$PROJECT/.agents/skills/helper/SKILL.md")" = canonical ]
  [ "$(cat "$PROJECT/.agents/skills/helper/notes.md")" = mine ]
  [[ "$output" == *"refused: .agents/skills/helper/notes.md (extra file in the Codex copy is left in place (never deleted))"* ]] || return 1
}

@test "parity repair: a skill without a Claude source is reported, never deleted" {
  mkdir -p "$PROJECT/.agents/skills/mine"
  printf 'user skill\n' > "$PROJECT/.agents/skills/mine/SKILL.md"
  fix --confirm --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"status":"refused"'* && "$output" == *'.agents/skills/mine'* ]] || return 1
  [ "$(cat "$PROJECT/.agents/skills/mine/SKILL.md")" = "user skill" ]
}

@test "parity repair: base-branch content is refused when the branch setting is ambiguous" {
  python3 - "$PROJECT/CLAUDE.md" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
path.write_text(re.sub(r"(?m)^base-branch:.*\n", "", path.read_text()))
PY
  printf '\nlocal edit\n' >> "$PROJECT/.agents/skills/rig-upgrade/references/command.md"
  local before
  before="$(shasum < "$PROJECT/.agents/skills/rig-upgrade/references/command.md")"
  fix --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"refused: .agents/skills/rig-upgrade (base-branch is not set exactly once"* ]] || return 1
  [ "$(shasum < "$PROJECT/.agents/skills/rig-upgrade/references/command.md")" = "$before" ]
}

@test "parity repair: a symlinked target is refused and left untouched" {
  printf 'outside\n' > "$BATS_TEST_TMPDIR/outside.md"
  rm "$PROJECT/.agents/skills/wrap/references/command.md"
  ln -s "$BATS_TEST_TMPDIR/outside.md" "$PROJECT/.agents/skills/wrap/references/command.md"
  fix --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"wrap/references/command.md (symlinked target or parent; repair manually)"* ]] || return 1
  [ "$(cat "$BATS_TEST_TMPDIR/outside.md")" = outside ]
}

@test "parity repair: without Codex skills the fix is not applicable" {
  rm -rf "$PROJECT/.agents"
  fix --json
  [ "$status" -eq 3 ]
  [[ "$output" == *'"status":"not_applicable"'* ]] || return 1
}

@test "doctor fix: other checks still have no automatic repair" {
  run bash -c 'cd "$1" && bin/rig doctor fix --check claude_commands' _ "$PROJECT"
  [ "$status" -eq 64 ]
  [[ "$output" == *"worktree_bootstrap and codex_skill_parity"* ]] || return 1
}

@test "parity repair: copied skills are byte copies, so CRLF content converges" {
  mkdir -p "$PROJECT/.claude/skills/crlf" "$PROJECT/.agents/skills/crlf"
  printf 'a\r\nb\r\n' > "$PROJECT/.claude/skills/crlf/SKILL.md"
  printf 'a\nb\n' > "$PROJECT/.agents/skills/crlf/SKILL.md"
  fix --confirm --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"applied"'* ]] || return 1
  cmp -s "$PROJECT/.claude/skills/crlf/SKILL.md" "$PROJECT/.agents/skills/crlf/SKILL.md"
  fix --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"already_complete"'* ]] || return 1
}

@test "parity repair: a user-added command neither changes Rig rewrites nor gets a generated skill" {
  printf '# local\n' > "$PROJECT/.claude/commands/tmp.md"
  printf '\nlocal edit\n' >> "$PROJECT/.agents/skills/recon/references/command.md"
  fix --confirm
  [ "$status" -eq 3 ]
  cmp -s "$PRISTINE/.agents/skills/recon/references/command.md" "$PROJECT/.agents/skills/recon/references/command.md"
  [ ! -e "$PROJECT/.agents/skills/tmp" ]
  [[ "$output" == *"refused: .agents/skills/tmp (command is not a Rig-generated skill"* ]] || return 1
}

@test "parity repair: without an install manifest generated skills are refused, not guessed" {
  rm -f "$PROJECT/.rig/memory/.rig-manifest" "$PROJECT/.rig/memory/.rig-manifest.json"
  printf '\nlocal edit\n' >> "$PROJECT/.agents/skills/wrap/references/command.md"
  local before
  before="$(shasum < "$PROJECT/.agents/skills/wrap/references/command.md")"
  fix --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"refused: .agents/skills/wrap (no install manifest records the generated skill inventory"* ]] || return 1
  [ "$(shasum < "$PROJECT/.agents/skills/wrap/references/command.md")" = "$before" ]
}

@test "parity repair: works from a subdirectory and refuses a non-file target without leftovers" {
  mkdir -p "$PROJECT/sub"
  printf '\nlocal edit\n' >> "$PROJECT/.agents/skills/wrap/references/command.md"
  rm "$PROJECT/.agents/skills/ship/SKILL.md"
  mkdir "$PROJECT/.agents/skills/ship/SKILL.md"
  run bash -c 'cd "$1/sub" && ../bin/rig doctor fix --check codex_skill_parity --confirm' _ "$PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"replace: .agents/skills/wrap/references/command.md"* ]] || return 1
  [[ "$output" == *"refused: .agents/skills/ship/SKILL.md (target exists but is not a regular file"* ]] || return 1
  [[ "$output" == *"codex_skill_parity is fail"* ]] || return 1
  cmp -s "$PRISTINE/.agents/skills/wrap/references/command.md" "$PROJECT/.agents/skills/wrap/references/command.md"
  [ -z "$(find "$PROJECT/.agents" -name '*.rig-fix-*')" ]
}

@test "parity repair: a missing base-branch skill is refused while other repairs still run" {
  python3 - "$PROJECT/CLAUDE.md" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
path.write_text(re.sub(r"(?m)^base-branch:.*\n", "", path.read_text()))
PY
  rm -rf "$PROJECT/.agents/skills/rig-upgrade"
  printf '\nlocal edit\n' >> "$PROJECT/.agents/skills/wrap/references/command.md"
  fix --confirm
  [ "$status" -eq 3 ]
  [[ "$output" != *"Traceback"* && "$output" != *"TypeError"* ]] || return 1
  [[ "$output" == *"refused: .agents/skills/rig-upgrade (base-branch is not set exactly once"* ]] || return 1
  cmp -s "$PRISTINE/.agents/skills/wrap/references/command.md" "$PROJECT/.agents/skills/wrap/references/command.md"
  [ ! -e "$PROJECT/.agents/skills/rig-upgrade" ]
}

@test "parity repair: doctor's optional command list covers every template command not installed by default" {
  python3 - "$BATS_TEST_DIRNAME/../templates/project/.claude/commands" "$INSTALLED/.claude/commands" "$BATS_TEST_DIRNAME/../templates/project/bin/rig" <<'PY'
import pathlib, re, sys
template = {p.stem for p in pathlib.Path(sys.argv[1]).glob("*.md")}
installed = {p.stem for p in pathlib.Path(sys.argv[2]).glob("*.md")}
source = pathlib.Path(sys.argv[3]).read_text()
block = re.search(r"optional_commands = \{(.*?)\}", source, re.S).group(1)
optional = set(re.findall(r'"([a-z-]+)"', block))
assert template - installed <= optional, sorted(template - installed - optional)
assert optional <= template, sorted(optional - template)
PY
}
