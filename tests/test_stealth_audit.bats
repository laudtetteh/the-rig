#!/usr/bin/env bats
#
# tests/test_stealth_audit.bats — read-only classification and safe repair
# for stealth-mode git-exclude coverage (installer/audit-stealth.py and
# installer/repair-stealth.py).
#
# Every fixture lives under BATS_TEST_TMPDIR (a fresh per-test directory
# bats-core creates and removes automatically) — no real project directory
# is ever touched.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
AUDIT="$REPO_ROOT/installer/audit-stealth.py"
REPAIR="$REPO_ROOT/installer/repair-stealth.py"

# Builds a minimal stealth-tracked project fixture at $1 with an external
# Rig dir at $2, four bin/rig* launchers present, and only "bin/rig" in
# .git/info/exclude — i.e. exactly the pre-fix leak this lane closes.
make_leaky_stealth_fixture() {
  local project="$1" external="$2"
  mkdir -p "$project/bin" "$project/.git/info" "$external/memory"
  git -C "$project" init -q
  git -C "$project" config user.email "test@test.com"
  git -C "$project" config user.name "Test"
  printf '%s\n' "$external" > "$project/.rigpath"
  printf 'CLAUDE.md\nPROJECT_BRIEF.md\n.claude/\n.rigpath\nbin/rig\n' \
    > "$project/.git/info/exclude"
  : > "$project/bin/rig"
  : > "$project/bin/rig-connector-preflight"
  : > "$project/bin/rig-sprint"
  : > "$project/bin/rig-tab-title-watch"
  : > "$project/CLAUDE.md"
  {
    echo "hash  bin/rig"
    echo "hash  bin/rig-connector-preflight"
    echo "hash  bin/rig-sprint"
    echo "hash  bin/rig-tab-title-watch"
    echo "hash  CLAUDE.md"
  } > "$external/memory/.rig-manifest"
}

# ── audit-stealth.py: classification ──────────────────────────────────────

@test "audit: identifies an uncovered launcher sibling as untracked_leak" {
  local project="$BATS_TEST_TMPDIR/project"
  local external="$BATS_TEST_TMPDIR/external"
  make_leaky_stealth_fixture "$project" "$external"

  run python3 "$AUDIT" "$project"
  [ "$status" -eq 1 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }

  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is False and d["leak_count"] == 3'
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); a={x["path"]:x["status"] for x in d["artifacts"]}; assert a["bin/rig-connector-preflight"] == "untracked_leak"'
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); a={x["path"]:x["status"] for x in d["artifacts"]}; assert a["bin/rig-sprint"] == "untracked_leak"'
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); a={x["path"]:x["status"] for x in d["artifacts"]}; assert a["bin/rig-tab-title-watch"] == "untracked_leak"'
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); a={x["path"]:x["status"] for x in d["artifacts"]}; assert a["bin/rig"] == "excluded"'
}

@test "audit: a user's own file that merely starts with 'rig' is never classified as a leak (retro-audit finding, PR #449)" {
  # discover_launcher_paths() previously matched ANY bin/ file whose name
  # started with "rig" -- not just launchers The Rig actually generated.
  # A user's own unrelated script coincidentally named this way would be
  # silently misclassified as untracked_leak, and the documented manual
  # repair workflow (repair-stealth.py) would then append it to
  # .git/info/exclude, hiding real content from git. Now scoped to the
  # installer's own real template source, mirroring install.sh's own
  # stealth-exclude enumeration.
  local project="$BATS_TEST_TMPDIR/project"
  local external="$BATS_TEST_TMPDIR/external"
  make_leaky_stealth_fixture "$project" "$external"
  printf '#!/bin/sh\necho my own deploy script\n' > "$project/bin/rig-my-deploy-script.sh"

  run python3 "$AUDIT" "$project"
  [ "$status" -eq 1 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); paths={x["path"] for x in d["artifacts"]}; assert "bin/rig-my-deploy-script.sh" not in paths'
}

@test "audit: a fully covered stealth project reports zero leaks" {
  local project="$BATS_TEST_TMPDIR/project"
  local external="$BATS_TEST_TMPDIR/external"
  make_leaky_stealth_fixture "$project" "$external"
  {
    echo "bin/rig-connector-preflight"
    echo "bin/rig-sprint"
    echo "bin/rig-tab-title-watch"
  } >> "$project/.git/info/exclude"

  run python3 "$AUDIT" "$project"
  [ "$status" -eq 0 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is True and d["leak_count"] == 0'
}

@test "audit: a tracked launcher is classified tracked_leak, not untracked_leak" {
  local project="$BATS_TEST_TMPDIR/project"
  local external="$BATS_TEST_TMPDIR/external"
  mkdir -p "$project/bin" "$project/.git/info" "$external/memory"
  git -C "$project" init -q
  git -C "$project" config user.email "test@test.com"
  git -C "$project" config user.name "Test"
  printf '%s\n' "$external" > "$project/.rigpath"
  printf 'CLAUDE.md\n.rigpath\n' > "$project/.git/info/exclude"
  : > "$project/bin/rig-sprint"
  git -C "$project" add bin/rig-sprint
  git -C "$project" commit -qm seed
  echo "hash  bin/rig-sprint" > "$external/memory/.rig-manifest"

  run python3 "$AUDIT" "$project"
  [ "$status" -eq 1 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); a={x["path"]:x["status"] for x in d["artifacts"]}; assert a["bin/rig-sprint"] == "tracked_leak"'
}

@test "audit: a non-stealth project (no .rigpath) reports stealth:false and ok" {
  local project="$BATS_TEST_TMPDIR/project"
  mkdir -p "$project/.git"
  git -C "$project" init -q

  run python3 "$AUDIT" "$project"
  [ "$status" -eq 0 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is True and d["stealth"] is False'
}

@test "audit: a non-git directory fails with a clear error, not a crash" {
  local project="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$project"

  run python3 "$AUDIT" "$project"
  [ "$status" -eq 2 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is False and d["error"]["code"] == "not-a-git-repo"'
}

# ── repair-stealth.py: safe, additive repair ──────────────────────────────

@test "repair: adds missing exclude patterns without duplicating or touching unrelated rules" {
  local project="$BATS_TEST_TMPDIR/project"
  local external="$BATS_TEST_TMPDIR/external"
  make_leaky_stealth_fixture "$project" "$external"
  printf '*.local\n' >> "$project/.git/info/exclude"

  run python3 "$REPAIR" "$project"
  [ "$status" -eq 0 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert sorted(d["repaired"]) == ["bin/rig-connector-preflight","bin/rig-sprint","bin/rig-tab-title-watch"]'

  # Unrelated pre-existing rule survives untouched.
  grep -qx '\*.local' "$project/.git/info/exclude"
  # Original bin/rig line is untouched (still exactly one occurrence).
  [ "$(grep -cx 'bin/rig' "$project/.git/info/exclude")" -eq 1 ]

  # Re-running audit now reports zero leaks.
  run python3 "$AUDIT" "$project"
  [ "$status" -eq 0 ]

  # Re-running repair is a no-op — no duplicate lines are ever written.
  run python3 "$REPAIR" "$project"
  [ "$status" -eq 0 ]
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["repaired"] == []'
  [ "$(grep -cx 'bin/rig-sprint' "$project/.git/info/exclude")" -eq 1 ]
}

@test "repair: never untracks an already-tracked leak, only reports it" {
  local project="$BATS_TEST_TMPDIR/project"
  local external="$BATS_TEST_TMPDIR/external"
  mkdir -p "$project/bin" "$project/.git/info" "$external/memory"
  git -C "$project" init -q
  git -C "$project" config user.email "test@test.com"
  git -C "$project" config user.name "Test"
  printf '%s\n' "$external" > "$project/.rigpath"
  printf 'CLAUDE.md\n.rigpath\n' > "$project/.git/info/exclude"
  : > "$project/bin/rig-sprint"
  git -C "$project" add bin/rig-sprint
  git -C "$project" commit -qm seed
  echo "hash  bin/rig-sprint" > "$external/memory/.rig-manifest"

  run python3 "$REPAIR" "$project"
  [ "$status" -eq 0 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["still_tracked"] == ["bin/rig-sprint"]'

  # The file remains tracked — repair never runs git rm --cached.
  run git -C "$project" ls-files bin/rig-sprint
  [ "$status" -eq 0 ]
  [ "$output" = "bin/rig-sprint" ]
}

@test "repair: a non-stealth project is a safe no-op" {
  local project="$BATS_TEST_TMPDIR/project"
  mkdir -p "$project/.git"
  git -C "$project" init -q

  run python3 "$REPAIR" "$project"
  [ "$status" -eq 0 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is True and d["repaired"] == []'
}

# ── End-to-end: real installer output feeds the classification tool ───────

@test "end-to-end: a fresh install.sh stealth install audits clean" {
  local project="$BATS_TEST_TMPDIR/project"
  local external="$BATS_TEST_TMPDIR/external"
  mkdir -p "$project"
  git -C "$project" init -q
  git -C "$project" config user.email "test@test.com"
  git -C "$project" config user.name "Test"

  run bash "$REPO_ROOT/install.sh" --project-only \
    --target "$project" --project-name "AuditFixture" \
    --tracking stealth --rig-dir "$external" --strategy skip
  [ "$status" -eq 0 ]

  run python3 "$AUDIT" "$project"
  [ "$status" -eq 0 ]
  json_assert() { JSON_OUTPUT="$output" python3 -c "$1"; }
  json_assert 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is True and d["leak_count"] == 0'

  run git -C "$project" status --porcelain --untracked-files=all
  [ "$status" -eq 0 ]
  [[ "$output" != *"bin/rig"* ]] || return 1
}
