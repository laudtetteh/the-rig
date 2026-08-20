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
  rig --help
  [[ "$output" == *"upgrade rollback"* ]]
}

@test "rollback: help distinguishes it from install.sh --recover" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy upgrade
  rig upgrade --help
  [[ "$output" == *"--recover"* ]]
  [[ "$output" == *"interrupted"* ]]
}

@test "rollback: requires --last or --id" {
  _upgraded_project
  rig upgrade rollback --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--last or --id"* ]]
}

@test "rollback: refuses to act without --dry-run or --confirm" {
  _upgraded_project
  rig upgrade rollback --last
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dry-run or --confirm"* ]]
}

@test "rollback: refuses a confirmation token that does not match the report" {
  _upgraded_project
  rig upgrade rollback --last --confirm not-the-right-id
  [ "$status" -ne 0 ]
  [[ "$output" == *"confirmation token does not match"* ]]
}

@test "rollback: reports when no upgrade report exists" {
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name "TestProject" --tracking repo --strategy skip
  rig upgrade rollback --last --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no upgrade reports"* ]]
}

@test "rollback: reports when no report matches the given id" {
  _upgraded_project
  rig upgrade rollback --id 19990101_000000_1 --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no upgrade report matches"* ]]
}

# ── Dry run is genuinely dry ─────────────────────────────────────────────────

@test "rollback: dry run lists what it would restore" {
  _upgraded_project
  rig upgrade rollback --last --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rollback plan"* ]]
  [[ "$output" == *"restore:"* ]]
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
    --project-name "TestProject" --tracking repo --strategy upgrade
  local version_before
  version_before="$(cat "$TEST_PROJECT/.rig/VERSION")"
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
  [[ "$output" == *"schema_version"* ]]
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
  [[ "$output" == *"mutually exclusive"* ]]
  [ "$(cat "$TEST_PROJECT/.rig/VERSION")" = "$version_before" ]
}

@test "rollback: --id followed by another flag is rejected, not silently misread" {
  _upgraded_project
  rig upgrade rollback --id --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--id requires a report id"* ]]
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

  [[ "$output" != *"Traceback"* ]]
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
  [[ "$output" != *"Traceback"* ]]
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
  [[ "$output" != *"Traceback"* ]]
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
  snapshot="$(ls -d "$TEST_PROJECT/.rig/upgrade-reports/"*.metadata | tail -1)"
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
  ! grep -q "ATTACKER CONTENT" "$outside"
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
