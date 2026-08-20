#!/usr/bin/env bats
#
# tests/test_upgrade_reports.bats — Durable upgrade reports (issue #562).
#
# Run with: bats tests/test_upgrade_reports.bats
#
# A report is a rollback contract, not an audit log: `rig upgrade rollback`
# (issue #563) reads it to decide what it may safely restore, so the fields
# asserted here are the ones rollback depends on. In particular a recorded
# backup path must still resolve *after* the run ends -- backups are written
# into .rig-backup/.in-progress/ and that directory is renamed on finalize, so
# an unresolved path would dangle the moment the upgrade completes.

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

run_installer() {
  run bash "$INSTALLER" --project-only \
    --target "$TEST_PROJECT" \
    --project-name "TestProject" \
    --tracking repo \
    "$@"
}

_sha256() {
  { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | awk '{print $1}'
}

# Make one Rig-owned file look like an older, UNMODIFIED install: replace its
# content and record that content as the manifest baseline, so the next upgrade
# genuinely updates it.
#
# Seeding and upgrading both run the same installer, so without this every
# template already matches and the only change in the report is the single
# customized file — which would make the `all(...)` assertions below true over
# a one-element list and hide whole classes of defect.
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

# Install once, age a few Rig-owned files, then customize another, so the next
# run has real multi-file work.
#
# The seed deliberately uses `merge`, not `upgrade`: only the upgrade family
# writes reports, so seeding with `upgrade` would leave a report behind and
# every assertion about "the report this run wrote" would read the seed's.
_seed_project() {
  run_installer --strategy merge
  [ "$status" -eq 0 ]
  _age_file .claude/commands/wrap.md
  _age_file .claude/hooks/pre-compact.sh
  _age_file .rig/processes/POST_MERGE_WORKFLOW.md
  printf '\n# local note\n' >> "$TEST_PROJECT/.claude/commands/task.md"
}

# Newest report: reports are named by timestamp, and a test may legitimately
# produce more than one.
_report_file() {
  ls "$TEST_PROJECT/.rig/upgrade-reports/"*.json 2>/dev/null | tail -1
}

_report_count() {
  ls "$TEST_PROJECT/.rig/upgrade-reports/"*.json 2>/dev/null | wc -l | tr -d ' '
}

# The expression is interpolated into the script body rather than passed as
# argv: a set/dict literal contains spaces and commas, which the shell would
# split into separate arguments.
_report_field() {
  python3 -c "
import json
d = json.load(open('$(_report_file)'))
print($1)
"
}

# ── agent-plan stays zero-write ──────────────────────────────────────────────

@test "upgrade report: agent-plan writes no report at all" {
  _seed_project

  run_installer --strategy agent-plan
  [ ! -d "$TEST_PROJECT/.rig/upgrade-reports" ]
}

@test "upgrade report: agent-plan stdout carries no report_path or rollback_id" {
  _seed_project

  run_installer --strategy agent-plan
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('report_path' in d or 'rollback_id' in d)
" <<< "$output"
  [ "$output" = "False" ]
}

# ── A completed apply run writes one ─────────────────────────────────────────

@test "upgrade report: a completed apply run writes exactly one report" {
  _seed_project

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  [ -d "$TEST_PROJECT/.rig/upgrade-reports" ]
  [ "$(_report_count)" = "1" ]
}

@test "upgrade report: stdout stays one JSON document and gains report_path and rollback_id" {
  _seed_project

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  # Exactly one machine-readable document, no extra narration around it.
  run python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['report_path'], 'missing report_path'
assert d['rollback_id'], 'missing rollback_id'
print('ok')
" <<< "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "upgrade report: stdout report_path names the file that was written" {
  _seed_project

  run_installer --strategy agent-upgrade
  local reported
  reported="$(python3 -c "
import json, sys
print(json.loads(sys.stdin.read())['report_path'])
" <<< "$output")"

  [ -f "$reported" ]
  [ "$reported" = "$(_report_file)" ]
}

# ── Schema and rollback-critical fields ──────────────────────────────────────

@test "upgrade report: records schema, rollback id, mode and status" {
  _seed_project
  run_installer --strategy agent-upgrade

  [ "$(_report_field "d['schema_version']")" = "1" ]
  [ "$(_report_field "d['status']")" = "success" ]
  [ "$(_report_field "bool(d['rollback_id'])")" = "True" ]
  [ "$(_report_field "d['mode']")" = "apply" ]
}

@test "upgrade report: records the version before and after the upgrade" {
  _seed_project
  run_installer --strategy agent-upgrade

  [ "$(_report_field "d['version']['after']")" = "$(cat "$REPO_ROOT/VERSION")" ]
  [ "$(_report_field "bool(d['version']['before'])")" = "True" ]
}

@test "upgrade report: the fixture produces several changes, not one" {
  _seed_project
  run_installer --strategy agent-upgrade

  # An anchor, not a behaviour assertion. Every `all(...)` check in this file
  # would pass vacuously on an empty list and near-vacuously on a single-element
  # one, so if the fixture ever stops generating real multi-file work this test
  # fails loudly instead of the suite quietly proving less than it claims.
  [ "$(_report_field "len(d['changes'])")" -ge 3 ]
}

@test "upgrade report: after-hashes stay correct for files rewritten by post-copy substitution" {
  _seed_project
  run_installer --strategy agent-upgrade

  # Regression guard. Several passes rewrite a file AFTER _upgrade_write()
  # recorded its after-state (the [BASE_BRANCH] substitution, the stealth
  # CLAUDE.md rewrite). A stale after-hash is silent here but makes rollback
  # refuse the file as "edited since the upgrade". This has now been fixed
  # three separate times, most recently for .rig/-rooted paths under repo
  # tracking, where the refresh keyed on a different storage root than the
  # original record and was dropped on collapse.
  run python3 -c "
import hashlib, json, os, sys
d = json.load(open(sys.argv[1]))
stale = []
for change in d['changes']:
    path = os.path.join(change['storage_root'], change['path'])
    if not os.path.isfile(path):
        continue
    digest = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    if digest != change['after']['hash']:
        stale.append(change['path'])
assert not stale, stale
print('ok')
" "$(_report_file)"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "upgrade report: records files the upgrade created" {
  _seed_project
  # Creations are the bulk of a real version-to-version upgrade, and they go
  # through copy_file()'s no-collision branch, which never reaches
  # _upgrade_write(). Without a record there, the rollback contract is
  # near-empty for exactly the upgrades that change the most.
  rm -f "$TEST_PROJECT/.claude/commands/wrap.md" "$TEST_PROJECT/.claude/hooks/stop.sh"

  run_installer --strategy agent-upgrade
  [ "$status" -eq 0 ]

  [ "$(_report_field "sorted(c['path'] for c in d['changes'] if c['operation'] == 'created')")" = "['.claude/commands/wrap.md', '.claude/hooks/stop.sh']" ]
  [ "$(_report_field "all(c['before']['type'] == 'absent' for c in d['changes'] if c['operation'] == 'created')")" = "True" ]
  [ "$(_report_field "all(c.get('absent_before') for c in d['changes'] if c['operation'] == 'created')")" = "True" ]
}

@test "upgrade report: executable hooks record the mode they actually end up with" {
  _seed_project
  # chmod +x runs AFTER _upgrade_write records the after-state, so without a
  # refresh the report says 644 while the file is 755 — and rollback then
  # refuses it as "mode changed since the upgrade". Fifth site of that class.
  local hook="$TEST_PROJECT/.claude/hooks/post-tool.sh"
  printf '# aged hook content\n' > "$hook"
  chmod 644 "$hook"
  local hash
  hash="$(_sha256 "$hook")"
  python3 - "$TEST_PROJECT/.rig/memory/.rig-manifest" "$hash" <<'PYEOF'
import sys
manifest, digest = sys.argv[1:3]
suffix = "  .claude/hooks/post-tool.sh"
out = []
for line in open(manifest):
    out.append("%s%s\n" % (digest, suffix) if line.rstrip("\n").endswith(suffix) else line)
open(manifest, "w").writelines(out)
PYEOF

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  run python3 -c "
import json, os, sys
d = json.load(open(sys.argv[1]))
for change in d['changes']:
    if not change['path'].endswith('post-tool.sh'):
        continue
    path = os.path.join(change['storage_root'], change['path'])
    disk = oct(os.stat(path).st_mode & 0o777)[2:]
    assert change['after']['mode'] == disk, (change['after']['mode'], disk)
    print('ok')
    break
else:
    raise SystemExit('post-tool.sh not recorded')
" "$(_report_file)"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "upgrade report: records storage root and relative path for every change" {
  _seed_project
  run_installer --strategy agent-upgrade

  [ "$(_report_field "all(c['storage_root'] and c['path'] for c in d['changes'])")" = "True" ]
  [ "$(_report_field "all(not c['path'].startswith('/') for c in d['changes'])")" = "True" ]
}

@test "upgrade report: records before and after hash, mode and type per change" {
  _seed_project
  run_installer --strategy agent-upgrade

  # No `{...}` literals in these expressions: bash brace-expands `{'a','b'}`
  # into separate words before python ever sees it, which silently turns a set
  # into a string. Build sets from lists instead.
  [ "$(_report_field "all(sorted(c['before']) == sorted(['hash','mode','type']) for c in d['changes'])")" = "True" ]
  [ "$(_report_field "all(sorted(c['after']) == sorted(['hash','mode','type']) for c in d['changes'])")" = "True" ]
  [ "$(_report_field "all(c['after']['hash'] for c in d['changes'] if c['operation'] != 'deleted')")" = "True" ]
}

@test "upgrade report: every recorded operation is a known kind" {
  _seed_project
  run_installer --strategy agent-upgrade

  [ "$(_report_field "all(c['operation'] in ['created','modified','deleted'] for c in d['changes'])")" = "True" ]
}

@test "upgrade report: the after-hash matches what is actually on disk" {
  _seed_project
  run_installer --strategy agent-upgrade

  run python3 -c "
import hashlib, json, os, sys
d = json.load(open(sys.argv[1]))
for change in d['changes']:
    path = os.path.join(change['storage_root'], change['path'])
    if not os.path.isfile(path):
        continue
    digest = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    assert digest == change['after']['hash'], change['path']
print('ok')
" "$(_report_file)"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# ── Backups must still resolve once the run is over ──────────────────────────

@test "upgrade report: every recorded backup path exists after the run finishes" {
  _seed_project
  run_installer --strategy agent-upgrade

  # The regression this guards: backups are written to
  # .rig-backup/.in-progress/ and that directory is renamed on finalize, so a
  # naively recorded path dangles as soon as the upgrade completes.
  run python3 -c "
import json, os, sys
d = json.load(open(sys.argv[1]))
dangling = [c['backup_path'] for c in d['changes']
            if 'backup_path' in c and not os.path.exists(c['backup_path'])]
assert not dangling, dangling
print('ok')
" "$(_report_file)"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "upgrade report: a modified path records a backup rather than absent_before" {
  _seed_project
  run_installer --strategy agent-upgrade

  [ "$(_report_field "all('backup_path' in c for c in d['changes'] if c['operation'] == 'modified')")" = "True" ]
  [ "$(_report_field "not any(c.get('absent_before') for c in d['changes'] if c['operation'] == 'modified')")" = "True" ]
}

@test "upgrade report: a restored backup reproduces the recorded before-hash" {
  _seed_project
  run_installer --strategy agent-upgrade

  run python3 -c "
import hashlib, json, sys
d = json.load(open(sys.argv[1]))
checked = 0
for change in d['changes']:
    if 'backup_path' not in change or not change['before']['hash']:
        continue
    digest = hashlib.sha256(open(change['backup_path'], 'rb').read()).hexdigest()
    assert digest == change['before']['hash'], change['path']
    checked += 1
assert checked, 'no backed-up change to verify'
print('ok')
" "$(_report_file)"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "upgrade report: names the backup root and preflight snapshot" {
  _seed_project
  run_installer --strategy agent-upgrade

  [ "$(_report_field "bool(d['backup_root'])")" = "True" ]
  [ "$(_report_field "'preflight_snapshot' in d")" = "True" ]
}

# ── Privacy and hygiene ──────────────────────────────────────────────────────

@test "upgrade report: is not world-readable" {
  _seed_project
  run_installer --strategy agent-upgrade

  local mode
  mode="$(stat -c '%a' "$(_report_file)" 2>/dev/null || stat -f '%Lp' "$(_report_file)")"
  [ "$mode" = "600" ]
}

@test "upgrade report: records paths and metadata, never file contents" {
  _seed_project
  # A distinctive string in a customized file must not be copied into the
  # report: reports are shared when diagnosing upgrades.
  printf '\n# SUPERSECRET-CANARY-VALUE\n' >> "$TEST_PROJECT/.claude/hooks/pre-tool.sh"

  run_installer --strategy agent-upgrade
  ! grep -q "SUPERSECRET-CANARY-VALUE" "$(_report_file)"
}

@test "upgrade report: does not embed the recovery journal" {
  _seed_project
  run_installer --strategy agent-upgrade

  # The transaction journal is local recovery metadata and is deliberately
  # never copied into a report.
  [ "$(_report_field "'journal' in json.dumps(d)")" = "False" ]
}

# ── Classic upgrade ──────────────────────────────────────────────────────────

@test "upgrade report: classic upgrade strategy also writes a report" {
  _seed_project

  run_installer --strategy upgrade
  [ "$status" -eq 0 ]

  [ -f "$(_report_file)" ]
}

@test "upgrade report: classic upgrade summary points at the report and rollback" {
  _seed_project

  run_installer --strategy upgrade
  [[ "$output" == *"Upgrade report:"* ]]
  [[ "$output" == *"rig upgrade rollback"* ]]
}
