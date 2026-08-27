#!/usr/bin/env bats
#
# tests/test_upgrade_rollback.bats — Completed-upgrade rollback (issue #563).
#
# Run with: bats tests/test_upgrade_rollback.bats
#
# Distinct from `install.sh --recover`, which restores an *interrupted*
# transaction from .rig-backup/.in-progress. This undoes one *completed*
# upgrade from the durable report that run wrote (issue #562), touching only
# the paths that report records as changed -- never the whole preflight
# snapshot, which would also revert unrelated work done since.
#
# The refusal tests matter more than the happy path: rollback writes to paths
# named in a file on disk, so it must refuse anything it cannot prove is still
# exactly as the upgrade left it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/test-project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email "test@test.com"
  git -C "$TEST_PROJECT" config user.name "Test"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_sha256() {
  # `command -v`, not `||` on the pipeline: a pipeline exits with awk's status
  # (0 even on empty input), so the fallback would never fire and this helper
  # would silently return "" -- turning every hash comparison into a vacuous
  # "" = "" pass.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

run_installer() {
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}

rig() {
  run "$TEST_PROJECT/bin/rig" "$@"
}

# Make one Rig-owned file look like an older, UNMODIFIED install: replace its
# content and record that content as the manifest baseline. The next upgrade
# then genuinely updates it.
#
# Without this the fixture is far weaker than it looks: seeding and upgrading
# both run the same installer, so every template already matches and the only
# thing an upgrade has to do is the one customized file. Tests that manipulate
# some other path would find it absent from the report and assert nothing.
_age_file() {
  local rel="$1"
  local path="$TEST_PROJECT/$rel"
  [ -f "$path" ] || return 1
  printf '# aged fixture content for %s\n' "$rel" > "$path"
  local hash
  hash="$(_sha256 "$path")"
  python3 - "$TEST_PROJECT/.rig/memory/.rig-manifest" "$hash" "$rel" <<'PYEOF'
import sys
manifest, digest, rel = sys.argv[1:4]
suffix = "  " + rel
out = []
for line in open(manifest):
    out.append("%s  %s\n" % (digest, rel) if line.rstrip("\n").endswith(suffix) else line)
open(manifest, "w").writelines(out)
PYEOF
}

# Install, age a couple of Rig-owned files so the upgrade has real work,
# customize another, then upgrade — leaving one completed upgrade with a
# durable report to roll back.
#
# The seed uses `merge`, not `upgrade`: only the upgrade family writes reports,
# so seeding with `upgrade` would leave one behind and assertions about "the
# report this run wrote" would read the seed's instead.
_upgraded_project() {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  _age_file .claude/commands/wrap.md
  _age_file .claude/hooks/pre-compact.sh
  printf '\n# local note\n' >> "$TEST_PROJECT/.claude/commands/task.md"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy agent-upgrade
  [ "$status" -eq 0 ]
}

_rollback_id() {
  "$TEST_PROJECT/bin/rig" upgrade rollback --last --dry-run --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["rollback_id"])'
}

# ── Usage contract ───────────────────────────────────────────────────────────

@test "rollback: is listed in the dispatcher usage" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  rig --help
  [[ "$output" == *"upgrade rollback"* ]] || return 1
}

@test "rollback: help distinguishes it from install.sh --recover" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  rig upgrade --help
  [[ "$output" == *"--recover"* ]] || return 1
  [[ "$output" == *"interrupted"* ]] || return 1
}

@test "rollback: subcommand help prints rollback usage" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  rig upgrade rollback --help
  [ "$status" -eq 0 ]
  case "$output" in *"Usage: rig upgrade rollback"*) ;; *) return 1 ;; esac
  case "$output" in *"Exit codes: 0 fully undone, 3 some paths refused, 70 a restore failed."*) ;; *) return 1 ;; esac
}

@test "rollback: requires --last or --id" {
  _upgraded_project
  rig upgrade rollback --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--last or --id"* ]] || return 1
}

@test "rollback: refuses to act without --dry-run or --confirm" {
  _upgraded_project
  rig upgrade rollback --last
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dry-run or --confirm"* ]] || return 1
}

@test "rollback: refuses a confirmation token that does not match the report" {
  _upgraded_project
  rig upgrade rollback --last --confirm not-the-right-id
  [ "$status" -ne 0 ]
  [[ "$output" == *"confirmation token does not match"* ]] || return 1
}

@test "rollback: reports when no upgrade report exists" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy skip
  rig upgrade rollback --last --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no upgrade reports"* ]] || return 1
}

@test "rollback: reports when no report matches the given id" {
  _upgraded_project
  rig upgrade rollback --id 19990101_000000_1 --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no upgrade report matches"* ]] || return 1
}

# ── Dry run is genuinely dry ─────────────────────────────────────────────────

@test "rollback: dry run lists what it would restore" {
  _upgraded_project
  rig upgrade rollback --last --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rollback plan"* ]] || return 1
  [[ "$output" == *"restore:"* ]] || return 1
}

@test "rollback: dry run changes nothing on disk" {
  _upgraded_project
  local version_before task_before
  version_before="$(cat "$TEST_PROJECT/.rig/VERSION")"
  task_before="$(_sha256 "$TEST_PROJECT/.claude/commands/task.md")"

  rig upgrade rollback --last --dry-run
  [ "$status" -eq 0 ]

  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" = "$version_before" ]
  [ "$(_sha256 "$TEST_PROJECT/.claude/commands/task.md")" = "$task_before" ]
}

@test "rollback: dry run emits machine-readable JSON on request" {
  _upgraded_project
  rig upgrade rollback --last --dry-run --json
  [ "$status" -eq 0 ]
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['dry_run'] is True
assert d['rollback_id']
assert isinstance(d['would_restore'], list)
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# ── Confirmed rollback ───────────────────────────────────────────────────────

@test "rollback: restores the version the project was on before the upgrade" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  local version_before
  # Age a file so the measured run has real work. Without it the only change
  # is a convergence to identical bytes, which is correctly dropped as a no-op
  # — leaving no report, so --last would reach back to an earlier one.
  _age_file .claude/commands/wrap.md
  printf '\n# local note\n' >> "$TEST_PROJECT/.claude/commands/task.md"
  # Force a version difference so the rollback has something to undo.
  echo "0.0.1-test" > "$TEST_PROJECT/.rig/VERSION"
  version_before="0.0.1-test"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy agent-upgrade
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" != "$version_before" ]

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" = "$version_before" ]
}

@test "rollback: restores the manifest pair alongside the files" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  _age_file .claude/commands/wrap.md
  printf '\n# local note\n' >> "$TEST_PROJECT/.claude/commands/task.md"
  local manifest="$TEST_PROJECT/.rig/memory/.rig-manifest"
  local flat_before json_before
  flat_before="$(_sha256 "$manifest")"
  json_before="$(_sha256 "${manifest}.json")"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy agent-upgrade
  [ "$status" -eq 0 ]
  # The upgrade must actually have changed the manifest, or this proves nothing.
  [ "$(_sha256 "$manifest")" != "$flat_before" ]

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]

  # The manifest is a dotfile; a naive glob-based snapshot silently skips it,
  # leaving a rollback that restores VERSION but not the baseline hashes.
  [ "$(_sha256 "$manifest")" = "$flat_before" ]
  [ "$(_sha256 "${manifest}.json")" = "$json_before" ]
}

@test "rollback: preserves the user customization it rolled back to" {
  _upgraded_project
  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]
  grep -q "# local note" "$TEST_PROJECT/.claude/commands/task.md"
}

@test "rollback: writes a durable rollback report" {
  _upgraded_project
  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]
  [ "$(ls "$TEST_PROJECT/.rig/upgrade-reports/rollback_${id}"_*.json | wc -l | tr -d ' ')" = "1" ]
}

@test "rollback: its report is not world-readable" {
  _upgraded_project
  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  local report; report="$(ls "$TEST_PROJECT/.rig/upgrade-reports/rollback_${id}"_*.json | head -1)"
  local mode
  mode="$(stat -c '%a' "$report" 2>/dev/null || stat -f '%Lp' "$report")"
  [ "$mode" = "600" ]
}

@test "rollback: restoring twice is refused the second time, not silently redone" {
  _upgraded_project
  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]

  # Everything is now at its pre-upgrade state, which no longer matches the
  # report's recorded after-state, so a second pass must refuse rather than
  # restore stale content over current files.
  rig upgrade rollback --id "$id" --confirm "$id" --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['refused'], 'second rollback restored instead of refusing'
assert not d['restored'], d['restored']
assert d['ok'] is False, 'a rollback that restored nothing is not ok'
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# ── Retired artifacts are inside the rollback contract ───────────────────────

# An old install carrying the legacy session-end.sh hook, which the upgrade
# retires. Without a recorded `deleted` operation the removal would sit outside
# the rollback contract entirely: the backup exists, but nothing would ever
# restore it.
_project_with_retired_legacy_hook() {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy skip
  [ "$status" -eq 0 ]
  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  printf '# legacy Rig hook\n' > "$legacy"
  printf '%s  .claude/hooks/session-end.sh\n' "$(_sha256 "$legacy")" \
    >> "$TEST_PROJECT/.rig/memory/.rig-manifest"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$legacy" ]
}

@test "rollback: a retired legacy hook is recorded as a deleted change" {
  _project_with_retired_legacy_hook

  local report
  report="$(ls "$TEST_PROJECT/.rig/upgrade-reports/"*.json | tail -1)"
  run python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
deleted = [c for c in d['changes'] if c['operation'] == 'deleted']
assert deleted, 'retirement was not recorded as a deleted change'
entry = deleted[0]
assert entry['path'].endswith('session-end.sh'), entry['path']
assert entry['before']['hash'], 'no pre-state hash to restore against'
assert 'backup_path' in entry, 'no backup recorded'
print('ok')
" "$report"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: restores a retired legacy hook" {
  _project_with_retired_legacy_hook
  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]

  [ -f "$legacy" ]
  grep -q "# legacy Rig hook" "$legacy"
}

@test "rollback: refuses to restore a retired path that was recreated since" {
  _project_with_retired_legacy_hook
  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  printf '# deliberately put back by the user\n' > "$legacy"

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
refused = [r for r in d['refused'] if r['path'].endswith('session-end.sh')]
assert refused, d['refused']
assert 'recreated since the upgrade' in refused[0]['reason'], refused
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]

  grep -q "deliberately put back by the user" "$legacy"
}

# ── --last must not select a previous rollback's own report ──────────────────

@test "rollback: --last still selects the upgrade report after a rollback has run" {
  _upgraded_project
  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]
  [ "$(ls "$TEST_PROJECT/.rig/upgrade-reports/rollback_${id}"_*.json | wc -l | tr -d ' ')" = "1" ]

  # "rollback_" sorts after any timestamp, so a naive newest-file pick would
  # select the rollback's own outcome document — which has no changes, making
  # a dry run print an empty plan and --confirm silently do nothing.
  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['rollback_id'] == sys.argv[1], (d['rollback_id'], sys.argv[1])
print('ok')
" "$id" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# ── The report is untrusted input ────────────────────────────────────────────
#
# A report is a plain JSON file in the project. A user, another tool, or a
# report copied in from elsewhere can name any path at all, so every write the
# rollback performs must be anchored to THIS installation's own roots — which
# are computed from the running install, never read from the document.

_latest_report() {
  ls "$TEST_PROJECT/.rig/upgrade-reports/"[0-9]*.json | tail -1
}

@test "rollback: refuses a report written for another project target" {
  _upgraded_project
  local report id
  report="$(_latest_report)"
  id="$(python3 -c "import json; print(json.load(open('$report'))['rollback_id'])")"

  python3 - "$report" "$TEMP_DIR/other-project" <<'PYEOF'
import json
import sys

report, other = sys.argv[1:3]
with open(report) as handle:
    data = json.load(handle)
data["target"] = other
with open(report, "w") as handle:
    json.dump(data, handle)
PYEOF

  rig upgrade rollback --id "$id" --dry-run --json
  [ "$status" -eq 69 ]
  case "$output" in *"different project target"*) ;; *) return 1 ;; esac
}

@test "rollback: refuses a stealth report written for another Rig directory" {
  local rig_ext="$TEMP_DIR/rig-ext"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking stealth --rig-dir "$rig_ext" \
    --project-agent claude --strategy merge
  [ "$status" -eq 0 ]

  rm -f "$TEST_PROJECT/.claude/commands/wrap.md"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking stealth --rig-dir "$rig_ext" \
    --project-agent claude --strategy agent-upgrade
  [ "$status" -eq 0 ]

  local report id
  report="$(ls "$rig_ext/upgrade-reports/"[0-9]*.json | tail -1)"
  id="$(python3 -c "import json; print(json.load(open('$report'))['rollback_id'])")"
  python3 - "$report" "$TEMP_DIR/other-rig" <<'PYEOF'
import json
import sys

report, other = sys.argv[1:3]
with open(report) as handle:
    data = json.load(handle)
data["rig_dir"] = other
data["tracking"] = "repo"
with open(report, "w") as handle:
    json.dump(data, handle)
PYEOF

  rig upgrade rollback --id "$id" --dry-run --json
  [ "$status" -eq 69 ]
  case "$output" in *"different Rig directory"*) ;; *) return 1 ;; esac
}

@test "rollback: refuses a change whose storage root is outside the project" {
  _upgraded_project
  mkdir -p "$TEMP_DIR/outside"
  printf 'ORIGINAL VICTIM CONTENT\n' > "$TEMP_DIR/outside/victim"
  printf 'ATTACKER CONTENT\n' > "$TEMP_DIR/evil-backup"

  python3 - "$(_latest_report)" "$TEMP_DIR" <<'PYEOF'
import hashlib, json, sys
report, temp = sys.argv[1:3]
with open(report) as fh:
    d = json.load(fh)
victim = temp + "/outside/victim"
backup = temp + "/evil-backup"
d["changes"].append({
    "operation": "modified",
    "storage_root": temp + "/outside",
    "path": "victim",
    "before": {"hash": hashlib.sha256(open(backup, "rb").read()).hexdigest(),
               "mode": "644", "type": "file"},
    "after": {"hash": hashlib.sha256(open(victim, "rb").read()).hexdigest(),
              "mode": "644", "type": "file"},
    "backup_path": backup,
})
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id" --json

  # The file outside the project must be untouched.
  grep -q "ORIGINAL VICTIM CONTENT" "$TEMP_DIR/outside/victim"
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any('outside this project' in r['reason'] for r in d['refused']), d['refused']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses a forged backup path elsewhere inside the project" {
  _upgraded_project
  local report victim payload
  report="$(_latest_report)"
  victim="$TEST_PROJECT/.claude/commands/wrap.md"
  payload="$TEST_PROJECT/payload.txt"
  printf 'ATTACKER PAYLOAD\n' > "$payload"

  python3 - "$report" "$TEST_PROJECT" "$victim" "$payload" <<'PYEOF'
import hashlib, json, sys
report, root, victim, payload = sys.argv[1:5]
with open(report) as fh:
    d = json.load(fh)
d["changes"] = [{
    "operation": "modified",
    "storage_root": root,
    "path": ".claude/commands/wrap.md",
    "before": {"hash": hashlib.sha256(open(payload, "rb").read()).hexdigest(),
               "mode": "644", "type": "file"},
    "after": {"hash": hashlib.sha256(open(victim, "rb").read()).hexdigest(),
              "mode": "644", "type": "file"},
    "backup_path": payload,
}]
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id" --json
  local rollback_output="$output"

  run grep -q "ATTACKER PAYLOAD" "$victim"
  [ "$status" -ne 0 ]
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any('not in this upgrade' in r['reason'] for r in d['refused']), d['refused']
print('ok')
" <<< "$rollback_output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses a forged created path outside the Rig surface" {
  _upgraded_project
  local report victim
  report="$(_latest_report)"
  victim="$TEST_PROJECT/app.txt"
  printf 'application data\n' > "$victim"

  python3 - "$report" "$TEST_PROJECT" "$victim" <<'PYEOF'
import hashlib, json, sys
report, root, victim = sys.argv[1:4]
with open(report) as fh:
    d = json.load(fh)
d["changes"] = [{
    "operation": "created",
    "storage_root": root,
    "path": "app.txt",
    "before": {"hash": None, "mode": None, "type": "absent"},
    "after": {"hash": hashlib.sha256(open(victim, "rb").read()).hexdigest(),
              "mode": "644", "type": "file"},
    "absent_before": True,
}]
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id" --json
  local rollback_output="$output"

  grep -q "application data" "$victim"
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any('not a Rig-managed rollback target' in r['reason'] for r in d['refused']), d['refused']
print('ok')
" <<< "$rollback_output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses a forged modified path outside the Rig surface" {
  _upgraded_project
  local report victim backup id
  report="$(_latest_report)"
  victim="$TEST_PROJECT/app.txt"
  printf 'application data\n' > "$victim"
  id="$(_rollback_id)"
  backup="$TEST_PROJECT/.rig-backup/$id/app.txt"
  mkdir -p "$(dirname "$backup")"
  printf 'ATTACKER PAYLOAD\n' > "$backup"

  python3 - "$report" "$TEST_PROJECT" "$victim" "$backup" <<'PYEOF'
import hashlib, json, sys
report, root, victim, backup = sys.argv[1:5]
with open(report) as fh:
    d = json.load(fh)
d["changes"] = [{
    "operation": "modified",
    "storage_root": root,
    "path": "app.txt",
    "before": {"hash": hashlib.sha256(open(backup, "rb").read()).hexdigest(),
               "mode": "644", "type": "file"},
    "after": {"hash": hashlib.sha256(open(victim, "rb").read()).hexdigest(),
              "mode": "644", "type": "file"},
    "backup_path": backup,
}]
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  rig upgrade rollback --id "$id" --confirm "$id" --json
  local rollback_output="$output"

  grep -q "application data" "$victim"
  run grep -q "ATTACKER PAYLOAD" "$victim"
  [ "$status" -ne 0 ]
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any('not a Rig-managed rollback target' in r['reason'] for r in d['refused']), d['refused']
print('ok')
" <<< "$rollback_output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses an operation it does not understand instead of restoring blind" {
  _upgraded_project
  # wrap.md, not task.md: task.md converges to identical bytes here, so it is
  # correctly dropped from the report as a no-op and would not be in the plan.
  local victim="$TEST_PROJECT/.claude/commands/wrap.md"
  printf 'MY IMPORTANT WORK WRITTEN AFTER THE UPGRADE\n' > "$victim"

  # An unhandled operation must not skip the "unchanged since the upgrade"
  # guard. mode-only and manifest-only are declared in the report schema but
  # emitted by nothing, so a reader that ignores them silently overwrites work.
  python3 - "$(_latest_report)" <<'PYEOF'
import json, sys
report = sys.argv[1]
with open(report) as fh:
    d = json.load(fh)
for change in d["changes"]:
    if change["path"].endswith("commands/wrap.md"):
        change["operation"] = "mode-only"
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id" --json

  grep -q "MY IMPORTANT WORK WRITTEN AFTER THE UPGRADE" "$victim"
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
refused = [r for r in d['refused'] if r['path'].endswith('commands/wrap.md')]
assert refused, d['refused']
assert 'unsupported operation' in refused[0]['reason'], refused
# Other aged files in this fixture legitimately restore; what matters is that
# the path with the unrecognised operation was not touched.
assert not any(p.endswith('commands/wrap.md') for p in d['restored']), d['restored']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses a report whose schema version it does not support" {
  _upgraded_project
  python3 - "$(_latest_report)" <<'PYEOF'
import json, sys
report = sys.argv[1]
with open(report) as fh:
    d = json.load(fh)
d["schema_version"] = 99
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  rig upgrade rollback --last --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema_version"* ]] || return 1
}

# ── Flag handling ────────────────────────────────────────────────────────────

@test "rollback: --dry-run and --confirm together is a usage error, not a silent apply" {
  _upgraded_project
  local version_before
  version_before="$(cat "$TEST_PROJECT/.rig/VERSION")"
  local id; id="$(_rollback_id)"

  # --confirm used to win silently, making the belt-and-braces invocation the
  # destructive one.
  rig upgrade rollback --id "$id" --dry-run --confirm "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]] || return 1
  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" = "$version_before" ]
}

@test "rollback: --id followed by another flag is rejected, not silently misread" {
  _upgraded_project
  rig upgrade rollback --id --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--id requires a report id"* ]] || return 1
}

# ── Metadata is only restored when the file plan fully succeeded ─────────────

@test "rollback: does not revert manifest or VERSION when any path was refused" {
  _upgraded_project
  # Make one path refuse by editing it after the upgrade.
  echo "# edited after the upgrade" >> "$TEST_PROJECT/.claude/commands/wrap.md"

  local version_after_upgrade manifest_after_upgrade
  version_after_upgrade="$(cat "$TEST_PROJECT/.rig/VERSION")"
  manifest_after_upgrade="$(_sha256 "$TEST_PROJECT/.rig/memory/.rig-manifest")"

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id" --json

  # Reverting the bookkeeping while a file stayed at its post-upgrade content
  # would claim a state the tree is not in, and every later upgrade would then
  # misclassify files as customized.
  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" = "$version_after_upgrade" ]
  [ "$(_sha256 "$TEST_PROJECT/.rig/memory/.rig-manifest")" = "$manifest_after_upgrade" ]

  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['refused'], 'expected a refusal'
assert not d['metadata_restored'], d['metadata_restored']
assert d['ok'] is False, 'a rollback that refused paths is not ok'
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: an unreadable backup reports JSON, not a traceback" {
  _upgraded_project
  local backup
  backup="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(next(c['backup_path'] for c in d['changes'] if 'backup_path' in c))
" "$(_latest_report)")"
  chmod 000 "$backup"

  rig upgrade rollback --last --dry-run --json
  chmod 644 "$backup"

  [[ "$output" != *"Traceback"* ]] || return 1
  run python3 -c "
import json, sys
json.loads(sys.stdin.read())
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# ── Undoing a creation means deleting it ─────────────────────────────────────
#
# Recording creations (issue #562) gave rollback its only destructive path:
# undoing a created file means unlinking it. Adding artifacts is most of what a
# version bump does, so this is the common case, not an edge one.

_project_with_created_file() {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy merge
  [ "$status" -eq 0 ]
  rm -f "$TEST_PROJECT/.claude/commands/wrap.md"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/commands/wrap.md" ]
}

@test "rollback: deletes a file the upgrade created" {
  _project_with_created_file

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id" --json
  [ "$status" -eq 0 ]

  [ ! -e "$TEST_PROJECT/.claude/commands/wrap.md" ]
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any(p.endswith('commands/wrap.md') for p in d['deleted']), d['deleted']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: dry run lists a created file under would_delete, and deletes nothing" {
  _project_with_created_file

  rig upgrade rollback --last --dry-run --json
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/commands/wrap.md" ]
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any(x['path'].endswith('commands/wrap.md') for x in d['would_delete']), d['would_delete']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: will not delete a created file that was edited after the upgrade" {
  _project_with_created_file
  # The destructive direction of "edited since the upgrade": deleting here
  # would destroy work outright rather than merely reverting content.
  echo "MY WORK AFTER THE UPGRADE" >> "$TEST_PROJECT/.claude/commands/wrap.md"

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id" --json

  [ -f "$TEST_PROJECT/.claude/commands/wrap.md" ]
  grep -q "MY WORK AFTER THE UPGRADE" "$TEST_PROJECT/.claude/commands/wrap.md"
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert not d['deleted'], d['deleted']
assert any('edited since the upgrade' in r['reason'] for r in d['refused']), d['refused']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: will not delete a created path that became a directory" {
  _project_with_created_file
  rm -f "$TEST_PROJECT/.claude/commands/wrap.md"
  mkdir -p "$TEST_PROJECT/.claude/commands/wrap.md"

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert not d['would_delete'], d['would_delete']
assert any(r['path'].endswith('commands/wrap.md') for r in d['refused']), d['refused']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  [ -d "$TEST_PROJECT/.claude/commands/wrap.md" ]
}

# ── Corrupt and hostile report documents ─────────────────────────────────────

@test "rollback: a corrupt report in the directory does not break --id lookup" {
  _upgraded_project
  local id; id="$(_rollback_id)"
  # --id scans every candidate, so one unparseable document used to kill the
  # run with a JSONDecodeError traceback and no JSON at all. The tool writes
  # its own reports into this directory, so a truncated write is self-inflicted.
  printf 'not json' > "$TEST_PROJECT/.rig/upgrade-reports/00000000_000001.json"

  rig upgrade rollback --id "$id" --dry-run --json
  [[ "$output" != *"Traceback"* ]] || return 1
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['rollback_id'] == sys.argv[1], d['rollback_id']
print('ok')
" "$id" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses a recorded mode that is not valid octal, before writing" {
  _upgraded_project
  python3 - "$(_latest_report)" <<'PYEOF'
import json, sys
report = sys.argv[1]
with open(report) as fh:
    d = json.load(fh)
for change in d["changes"]:
    change["before"]["mode"] = "zzz"
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  # The refusal has to happen at plan time: os.chmod raising ValueError would
  # kill the process AFTER the file was already overwritten — tree mutated,
  # no JSON, no rollback report.
  rig upgrade rollback --last --dry-run --json
  [[ "$output" != *"Traceback"* ]] || return 1
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any('not a valid octal mode' in r['reason'] for r in d['refused']), d['refused']
assert not d['would_restore'], d['would_restore']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: will not follow a symlinked metadata destination out of the project" {
  _upgraded_project
  local outside="$TEMP_DIR/outside-metadata.txt"
  printf 'ORIGINAL OUTSIDE CONTENT\n' > "$outside"
  # A symlink INSIDE the project pointing out of it. under_anchor() does not
  # resolve the final component (so a symlinked change is reported as a
  # symlink, not as out-of-project), which means the metadata path needs its
  # own islink refusal or shutil.copyfile follows it.
  ln -s "$outside" "$TEST_PROJECT/.rig/memory/.rig-manifest-link"
  local snapshot
  snapshot="$(ls -d "$TEST_PROJECT/.rig/upgrade-reports/"*.metadata 2>/dev/null | tail -1)"
  # Guard the glob: an absent .metadata directory would leave this empty and
  # send the next write to /.rig-manifest-link, outside the temp dir.
  [ -n "$snapshot" ] || { echo "no .metadata snapshot to tamper with" >&2; return 1; }
  printf 'ATTACKER CONTENT\n' > "$snapshot/.rig-manifest-link"
  python3 - "$(_latest_report)" "$TEST_PROJECT" <<'PYEOF'
import json, sys
report, project = sys.argv[1:3]
with open(report) as fh:
    d = json.load(fh)
d["metadata"]["manifest_file"] = project + "/.rig/memory/.rig-manifest-link"
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id" --json

  grep -q "ORIGINAL OUTSIDE CONTENT" "$outside"
  run grep -q "ATTACKER CONTENT" "$outside"
  [ "$status" -ne 0 ]
}

@test "rollback: refuses a forged metadata snapshot directory" {
  _upgraded_project
  local report payload_dir id
  report="$(_latest_report)"
  id="$(_rollback_id)"
  payload_dir="$TEST_PROJECT/payload-metadata"
  mkdir -p "$payload_dir"
  printf 'attacker manifest\n' > "$payload_dir/.rig-manifest"
  printf '{"schema_version":1,"entries":{}}\n' > "$payload_dir/.rig-manifest.json"
  printf '999.999.999\n' > "$payload_dir/VERSION"

  python3 - "$report" "$payload_dir" <<'PYEOF'
import json, sys
report, payload_dir = sys.argv[1:3]
with open(report) as fh:
    d = json.load(fh)
d["changes"] = []
d["metadata"]["snapshot_dir"] = payload_dir
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  rig upgrade rollback --id "$id" --confirm "$id" --json
  [ "$status" -eq 0 ]
  [ "$(_sha256 "$TEST_PROJECT/.rig/memory/.rig-manifest")" != "$(_sha256 "$payload_dir/.rig-manifest")" ]
  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" != "999.999.999" ]
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['ok'] is True, d
assert d['metadata_restored'] == [], d
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: skips metadata restore for a forged report with no artifact changes" {
  _upgraded_project
  local report payload_dir id snapshot
  report="$(_latest_report)"
  id="$(_rollback_id)"
  snapshot="$(ls -d "$TEST_PROJECT/.rig/upgrade-reports/"*.metadata 2>/dev/null | tail -1)"
  [ -n "$snapshot" ] || { echo "no .metadata snapshot to tamper with" >&2; return 1; }
  payload_dir="$snapshot"
  printf 'attacker manifest\n' > "$payload_dir/.rig-manifest"
  printf '{"schema_version":1,"entries":{}}\n' > "$payload_dir/.rig-manifest.json"
  printf '999.999.999\n' > "$payload_dir/VERSION"

  python3 - "$report" <<'PYEOF'
import json, sys
report = sys.argv[1]
with open(report) as fh:
    d = json.load(fh)
d["changes"] = []
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  rig upgrade rollback --id "$id" --confirm "$id" --json
  [ "$status" -eq 0 ]
  [ "$(_sha256 "$TEST_PROJECT/.rig/memory/.rig-manifest")" != "$(_sha256 "$payload_dir/.rig-manifest")" ]
  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" != "999.999.999" ]
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['ok'] is True, d
assert d['metadata_restored'] == [], d
assert 'no artifact changes' in d['metadata_skipped'], d
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: rejects rollback_id traversal before metadata restore" {
  _upgraded_project
  local report payload_dir
  report="$(_latest_report)"
  payload_dir="$TEST_PROJECT/.rig/payload.metadata"
  mkdir -p "$payload_dir"
  printf 'attacker manifest\n' > "$payload_dir/.rig-manifest"
  printf '{"schema_version":1,"entries":{}}\n' > "$payload_dir/.rig-manifest.json"
  printf '999.999.999\n' > "$payload_dir/VERSION"

  python3 - "$report" "$payload_dir" <<'PYEOF'
import json, sys
report, payload_dir = sys.argv[1:3]
with open(report) as fh:
    d = json.load(fh)
d["rollback_id"] = "../payload"
d["changes"] = []
d["metadata"]["snapshot_dir"] = payload_dir
with open(report, "w") as fh:
    json.dump(d, fh)
PYEOF

  rig upgrade rollback --id "../payload" --confirm "../payload" --json
  [ "$status" -eq 64 ]
  [ "$(_sha256 "$TEST_PROJECT/.rig/memory/.rig-manifest")" != "$(_sha256 "$payload_dir/.rig-manifest")" ]
  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" != "999.999.999" ]
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['ok'] is False, d
assert 'unsupported characters' in d['error'], d
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# ── Exit-code contract ───────────────────────────────────────────────────────

@test "rollback: exits 3 when paths were refused, not 0" {
  _upgraded_project
  echo "# edited after the upgrade" >> "$TEST_PROJECT/.claude/commands/wrap.md"
  local id; id="$(_rollback_id)"

  # A caller must be able to tell "undone" from "declined" without parsing JSON.
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 3 ]
}

@test "rollback: exits 0 when everything was undone" {
  _upgraded_project
  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]
}

@test "rollback: restores Codex direct-writer state when undoing a Codex target upgrade" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --project-agent claude --strategy merge
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_PROJECT/.codex/config.toml" ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --project-agent codex --strategy agent-upgrade
  [ "$status" -eq 0 ]
  [ -e "$TEST_PROJECT/.codex/config.toml" ]
  /usr/bin/grep -q '"agents":\["codex"\]' "$TEST_PROJECT/.rig/install-targets.json"

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]

  [ ! -e "$TEST_PROJECT/.codex/config.toml" ]
  /usr/bin/grep -q '"agents":\["claude"\]' "$TEST_PROJECT/.rig/install-targets.json"
}

@test "rollback: restores stealth git-exclude bookkeeping written during upgrade" {
  local rig_ext="$TEMP_DIR/rig-ext"
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking stealth --rig-dir "$rig_ext" \
    --project-agent claude --strategy merge
  [ "$status" -eq 0 ]

  local rel=".claude/commands/wrap.md"
  printf '# aged fixture content\n' > "$TEST_PROJECT/$rel"
  local hash
  hash="$(_sha256 "$TEST_PROJECT/$rel")"
  python3 - "$rig_ext/memory/.rig-manifest" "$hash" "$rel" <<'PYEOF'
import sys
manifest, digest, rel = sys.argv[1:4]
out = []
for line in open(manifest):
    out.append("%s  %s\n" % (digest, rel) if line.rstrip("\n").endswith("  " + rel) else line)
open(manifest, "w").writelines(out)
PYEOF

  # Model an older stealth install whose local exclude predates the current
  # full stealth-entry set. The upgrade should add the entries, and rollback
  # should restore this exact per-clone bookkeeping file.
  python3 - "$TEST_PROJECT/.git/info/exclude" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
remove = {
    "CLAUDE.md", "PROJECT_BRIEF.md", ".claude/", ".agents/", ".codex/",
    ".mcp.json", ".playwright-mcp/", ".github/", ".gitleaks.toml",
    "docs/INDEX.md", "docs/features/README.md", ".rig-backup/", ".rig/",
    "bin/rig", "bin/rig-sprint", "bin/rig-connector-preflight",
    "bin/rig-tab-title-watch",
}
lines = [
    line for line in p.read_text().splitlines()
    if "The Rig" not in line and line not in remove
]
p.write_text("\n".join(lines).rstrip() + "\n")
PYEOF
  cp "$TEST_PROJECT/.git/info/exclude" "$TEMP_DIR/exclude.before"

  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking stealth --rig-dir "$rig_ext" \
    --project-agent claude --strategy agent-upgrade
  [ "$status" -eq 0 ]
  grep -q "The Rig" "$TEST_PROJECT/.git/info/exclude"

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"
  [ "$status" -eq 0 ]
  cmp -s "$TEMP_DIR/exclude.before" "$TEST_PROJECT/.git/info/exclude"
}

@test "rollback: a dry run with refusals does not advertise metadata it will skip" {
  _upgraded_project
  echo "# edited after the upgrade" >> "$TEST_PROJECT/.claude/commands/wrap.md"

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['refused'], 'expected a refusal'
assert d['ok'] is False, 'a plan that cannot complete is not ok'
assert not d['would_restore_metadata'], d['would_restore_metadata']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: a text dry run with refusals does not advertise metadata it will skip" {
  _upgraded_project
  echo "# edited after the upgrade" >> "$TEST_PROJECT/.claude/commands/wrap.md"

  rig upgrade rollback --last --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"  metadata: 0"* ]] || return 1
}

# ── Safety refusals ──────────────────────────────────────────────────────────

@test "rollback: refuses a path edited after the upgrade" {
  _upgraded_project
  # Simulate work done after upgrading; rollback must not silently discard it.
  echo "# edited after the upgrade" >> "$TEST_PROJECT/.claude/commands/wrap.md"

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
refused = [r for r in d['refused'] if r['path'].endswith('commands/wrap.md')]
assert refused, d['refused']
assert 'edited since the upgrade' in refused[0]['reason'], refused
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: leaves a post-upgrade edit untouched when it refuses it" {
  _upgraded_project
  echo "# edited after the upgrade" >> "$TEST_PROJECT/.claude/commands/wrap.md"
  local edited; edited="$(_sha256 "$TEST_PROJECT/.claude/commands/wrap.md")"

  local id; id="$(_rollback_id)"
  rig upgrade rollback --id "$id" --confirm "$id"

  [ "$(_sha256 "$TEST_PROJECT/.claude/commands/wrap.md")" = "$edited" ]
  grep -q "# edited after the upgrade" "$TEST_PROJECT/.claude/commands/wrap.md"
}

@test "rollback: refuses a destination that became a symlink" {
  _upgraded_project
  local victim="$TEST_PROJECT/.claude/commands/wrap.md"
  printf 'outside\n' > "$TEMP_DIR/outside.md"
  rm -f "$victim"
  ln -s "$TEMP_DIR/outside.md" "$victim"

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
refused = [r for r in d['refused'] if r['path'].endswith('commands/wrap.md')]
assert refused, d['refused']
assert 'symlink' in refused[0]['reason'], refused
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]

  # The symlink target must not have been written through.
  [ "$(cat "$TEMP_DIR/outside.md")" = "outside" ]
}

@test "rollback: refuses a destination that became a directory" {
  _upgraded_project
  local victim="$TEST_PROJECT/.claude/commands/wrap.md"
  rm -f "$victim"
  mkdir -p "$victim"

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
refused = [r for r in d['refused'] if r['path'].endswith('commands/wrap.md')]
assert refused, d['refused']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses a report entry whose path escapes its storage root" {
  _upgraded_project
  local report
  report="$(ls "$TEST_PROJECT/.rig/upgrade-reports/"*.json | head -1)"
  python3 - "$report" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    document = json.load(fh)
document["changes"].append({
    "operation": "modified",
    "storage_root": document["changes"][0]["storage_root"],
    "path": "../../escaped.md",
    "before": {"hash": None, "mode": "644", "type": "file"},
    "after": {"hash": None, "mode": "644", "type": "file"},
    "backup_path": "/etc/hosts",
})
with open(path, "w") as fh:
    json.dump(document, fh)
PYEOF

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
refused = [r for r in d['refused'] if 'escaped.md' in r['path']]
assert refused, d['refused']
assert 'traversal' in refused[0]['reason'], refused
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses when the recorded backup no longer matches its pre-state" {
  _upgraded_project
  local report backup
  report="$(ls "$TEST_PROJECT/.rig/upgrade-reports/"*.json | head -1)"
  backup="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(next(c['backup_path'] for c in d['changes'] if 'backup_path' in c))
" "$report")"
  echo "tampered" >> "$backup"

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any('no longer matches' in r['reason'] for r in d['refused']), d['refused']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "rollback: refuses a change whose backup is missing entirely" {
  _upgraded_project
  local report backup
  report="$(ls "$TEST_PROJECT/.rig/upgrade-reports/"*.json | head -1)"
  backup="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(next(c['backup_path'] for c in d['changes'] if 'backup_path' in c))
" "$report")"
  rm -f "$backup"

  rig upgrade rollback --last --dry-run --json
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert any('backup is unavailable' in r['reason'] for r in d['refused']), d['refused']
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
