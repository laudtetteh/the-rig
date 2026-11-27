#!/usr/bin/env bats
#
# tests/test_retired_artifacts.bats — issue #612.
#
# install.sh retires Rig artifacts a release no longer ships through two
# tables, RENAMED_RIG_ARTIFACTS ("layer|old_rel|new_rel|builtin") and
# RETIRED_RIG_ARTIFACTS ("layer|old_rel|reason"), plus generated rows that move
# flat global Claude skills into their directories. These tests guard the
# tables' contract (nothing retired is still shipped; every project row can be
# rolled back) and prove the no-replacement path: an unchanged artifact is
# backed up and removed, anything else is preserved as a conflict.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@example.com
  git -C "$TEST_PROJECT" config user.name Test
  git -C "$TEST_PROJECT" commit -q --allow-empty -m init
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Print every static table row as "table|row", read from an installer file.
table_rows() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for table in ("RENAMED_RIG_ARTIFACTS", "RETIRED_RIG_ARTIFACTS"):
    body = re.search(r"^%s=\(\n(.*?)^\)" % table, text, re.M | re.S)
    if not body:
        raise SystemExit("missing table " + table)
    for row in re.findall(r'^\s*"([^"]+)"\s*$', body.group(1), re.M):
        print(f"{table}|{row}")
PY
}

# Print every retired old_rel that a template tree would still install, one
# per line. Arguments: installer file, templates root.
still_shipped() {
  table_rows "$1" | python3 -c '
import os, sys
templates = sys.argv[1]
def sources(layer, rel):
    """Template files that would install `rel` for `layer`."""
    if layer == "project":
        yield os.path.join(templates, "project", rel)
        if rel.startswith(".agents/skills/"):
            yield os.path.join(templates, "project", ".claude", "commands", rel.split("/")[2] + ".md")
    elif layer == "claude-global":
        name = rel.split("/")[1]
        if name.endswith(".md"):
            name = name[:-3]
        yield os.path.join(templates, "global", "skills", name + ".md")
    elif layer == "codex-global":
        yield os.path.join(templates, "global", "skills", rel.split("/")[2] + ".md")
for line in sys.stdin:
    table, layer, rel = line.rstrip("\n").split("|")[:3]
    for source in sources(layer, rel):
        if os.path.exists(source):
            print(f"{layer}:{rel} (still shipped as {os.path.relpath(source, templates)})")
' "$2"
}

# Copy the installer into a scratch source tree that shares the real
# templates and helpers, so a test can add a table row without editing the
# repository.
scratch_installer() {
  local src="$BATS_TEST_TMPDIR/rig-src" entry
  mkdir -p "$src"
  for entry in "$REPO_ROOT"/*; do
    [[ "$(basename "$entry")" == install.sh ]] && continue
    ln -s "$entry" "$src/$(basename "$entry")"
  done
  cp "$REPO_ROOT/install.sh" "$src/install.sh"
  printf '%s\n' "$src/install.sh"
}

# Insert a RETIRED_RIG_ARTIFACTS row into an installer copy.
add_retired_row() {
  python3 - "$1" "$2" <<'PY'
import sys
path, row = sys.argv[1:]
text = open(path, encoding="utf-8").read()
marker = "RETIRED_RIG_ARTIFACTS=(\n"
assert text.count(marker) == 1
open(path, "w", encoding="utf-8").write(text.replace(marker, f'{marker}  "{row}"\n'))
PY
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Record a Rig manifest entry for a project file, as an older install would.
track_in_manifest() {
  printf '%s  %s\n' "$(sha256 "$TEST_PROJECT/$1")" "$1" \
    >> "$TEST_PROJECT/.rig/memory/.rig-manifest"
}

install_with() {
  run bash "$1" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --project-agent both --strategy "$2" </dev/null
}

# ── Table contract ────────────────────────────────────────────────────────────

@test "retired tables: every row has a known layer and the right field count" {
  run table_rows "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | python3 -c '
import sys
for line in sys.stdin:
    table, *fields = line.rstrip("\n").split("|")
    want = 4 if table == "RENAMED_RIG_ARTIFACTS" else 3
    assert len(fields) == want, line
    assert fields[0] in ("project", "claude-global", "codex-global"), line
    assert fields[1] and fields[2], line
'
}

@test "retired tables: no retired path is still shipped by the templates" {
  run still_shipped "$REPO_ROOT/install.sh" "$REPO_ROOT/templates"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "retired tables: a retired path that reappears in the templates is detected" {
  local templates="$BATS_TEST_TMPDIR/templates"
  cp -R "$REPO_ROOT/templates" "$templates"
  printf '# back again\n' > "$templates/project/.claude/commands/status.md"
  printf '# back again\n' > "$templates/project/.claude/hooks/session-end.sh"
  run still_shipped "$REPO_ROOT/install.sh" "$templates"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project:.claude/commands/status.md"* ]] || return 1
  [[ "$output" == *"project:.agents/skills/status/SKILL.md"* ]] || return 1
  [[ "$output" == *"project:.claude/hooks/session-end.sh"* ]] || return 1
}

@test "retired tables: every project row can be restored by rig upgrade rollback" {
  run table_rows "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETIRED_RIG_ARTIFACTS|project|"* ]] || return 1
  printf '%s\n' "$output" | python3 -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
body = re.search(r"^LEGACY_DELETED_RIG_PATHS = (\{.*?^\})", text, re.M | re.S).group(1)
allowed = eval(body)
missing = [line.split("|")[2] for line in sys.stdin.read().splitlines()
           if line.split("|")[1] == "project" and line.split("|")[2] not in allowed]
assert not missing, "not restorable by rollback: " + ", ".join(missing)
' "$REPO_ROOT/templates/project/bin/rig"
}

# ── No-replacement retirement ─────────────────────────────────────────────────

@test "upgrade: an unchanged artifact with no replacement is backed up, removed and dropped from the manifest" {
  install_with "$REPO_ROOT/install.sh" merge
  [ "$status" -eq 0 ]
  local legacy="$TEST_PROJECT/.claude/hooks/session-end.sh"
  printf '# legacy Rig hook\n' > "$legacy"
  track_in_manifest .claude/hooks/session-end.sh

  install_with "$REPO_ROOT/install.sh" upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$legacy" ]
  [[ "$output" == *"Removed obsolete legacy hook: .claude/hooks/session-end.sh (merged into stop.sh in v1.21.0)"* ]] || return 1
  if grep -q 'session-end.sh' "$TEST_PROJECT/.rig/memory/.rig-manifest"; then return 1; fi
  [ -n "$(find "$TEST_PROJECT/.rig-backup" -name session-end.sh -type f)" ]
}

@test "upgrade: an obsolete command whose content was customized is preserved as a conflict" {
  local installer
  installer="$(scratch_installer)"
  add_retired_row "$installer" "project|.claude/commands/obsolete-probe.md|probe retired without a successor"
  install_with "$installer" merge
  [ "$status" -eq 0 ]
  printf '# Command: /obsolete-probe\n' > "$TEST_PROJECT/.claude/commands/obsolete-probe.md"
  track_in_manifest .claude/commands/obsolete-probe.md
  printf 'team tweak\n' >> "$TEST_PROJECT/.claude/commands/obsolete-probe.md"

  install_with "$installer" upgrade
  [ "$status" -eq 0 ]
  grep -Fq 'team tweak' "$TEST_PROJECT/.claude/commands/obsolete-probe.md"
  [[ "$output" == *"Preserved Rig artifact requiring review: .claude/commands/obsolete-probe.md (probe retired without a successor)"* ]] || return 1
  [[ "$output" == *"Skipped conflicts: 1"* ]] || return 1
}

@test "upgrade: an obsolete Codex skill is kept whole when one half is customized, removed whole otherwise" {
  local installer
  installer="$(scratch_installer)"
  add_retired_row "$installer" "project|.agents/skills/obsolete-probe/SKILL.md|probe skill retired"
  add_retired_row "$installer" "project|.agents/skills/obsolete-probe/references/command.md|probe skill retired"
  install_with "$installer" merge
  [ "$status" -eq 0 ]
  local skill="$TEST_PROJECT/.agents/skills/obsolete-probe"
  mkdir -p "$skill/references"
  printf -- '---\nname: obsolete-probe\n---\n' > "$skill/SKILL.md"
  printf '# probe\n' > "$skill/references/command.md"
  track_in_manifest .agents/skills/obsolete-probe/SKILL.md
  track_in_manifest .agents/skills/obsolete-probe/references/command.md
  printf 'local edit\n' >> "$skill/references/command.md"

  install_with "$installer" upgrade
  [ "$status" -eq 0 ]
  [ -f "$skill/SKILL.md" ]
  grep -Fq 'local edit' "$skill/references/command.md"
  [[ "$output" == *"Preserved Rig artifact with its skill: .agents/skills/obsolete-probe/SKILL.md"* ]] || return 1

  printf '# probe\n' > "$skill/references/command.md"
  install_with "$installer" upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$skill" ]
  [[ "$output" == *"Removed obsolete Rig artifact: .agents/skills/obsolete-probe/SKILL.md (probe skill retired)"* ]] || return 1
}

@test "upgrade: agent-plan reports a no-replacement retirement without changing anything" {
  local installer
  installer="$(scratch_installer)"
  add_retired_row "$installer" "project|.claude/commands/obsolete-plan.md|probe planned without a successor"
  install_with "$installer" merge
  [ "$status" -eq 0 ]
  printf '# Command: /obsolete-plan\n' > "$TEST_PROJECT/.claude/commands/obsolete-plan.md"
  track_in_manifest .claude/commands/obsolete-plan.md
  local before
  before="$(cd "$TEST_PROJECT" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum)"
  run bash "$installer" --project-only --target "$TEST_PROJECT" --project-name Fixture \
    --tracking repo --project-agent both --strategy agent-plan </dev/null
  [ "$(cd "$TEST_PROJECT" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum)" = "$before" ]
  printf '%s\n' "$output" | grep -E '^\{' | tail -1 | python3 -c '
import json, sys
doc = json.load(sys.stdin)
paths = {item["path"]: item for item in doc["artifacts"]}
assert paths[".claude/commands/obsolete-plan.md"]["action"] == "remove", paths.get(".claude/commands/obsolete-plan.md")
'
}
