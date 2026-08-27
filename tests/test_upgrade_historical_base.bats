#!/usr/bin/env bats
#
# tests/test_upgrade_historical_base.bats — Coverage for the content-addressed
# historical-base resolver (issue #560).
#
# Run with: bats tests/test_upgrade_historical_base.bats
#
# Context: installer/merge-*.py have always accepted a --base, but
# attempt_convergence_merge() in install.sh never supplied one, so every
# customized unstructured Rig-owned file conflicted by design (see the "no
# trusted base" notes in installer/merge-text3way.py). Issue #560 supplies
# that base.
#
# The resolver is content-addressed, not version-keyed. That is not a stylistic
# choice: on the real install that motivated this work
# (/Users/beaconavenue/code/4Culture, Rig 1.27.1) all 16 refused Rig-owned
# files were tracked only in the legacy flat `.rig-manifest`, which records
# `sha256  path` and nothing else. base_revision was absent for 16 of 16, so a
# version-keyed lookup resolves zero of them. Matching the recorded SHA256
# against rendered template content across historical tags recovered 16/16 --
# at v1.14.0-v1.17.0, not the v1.27.1 base_revision would have claimed.
#
# The fixtures below are 4Culture-shaped: a synthetic installer-source git repo
# carrying several release tags, and a target whose baseline is recorded in a
# legacy flat manifest with no provenance metadata at all. Nothing here reads
# the developer's real checkouts.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RESOLVER="$REPO_ROOT/installer/resolve-historical-base.py"

setup() {
  TEMP_DIR="$(mktemp -d)"
  SOURCE_REPO="$TEMP_DIR/rig-source"
  mkdir -p "$SOURCE_REPO"
  git -C "$SOURCE_REPO" init -q
  git -C "$SOURCE_REPO" config user.email "test@test.com"
  git -C "$SOURCE_REPO" config user.name "Test"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_sha256() {
  # `command -v`, not `||` on the pipeline: a pipeline exits with awk's status
  # (0 even on empty input), so the fallback never fires and this helper
  # silently returns "" on a host without sha256sum -- turning every hash
  # comparison into a vacuous "" = "" pass.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_sha256_string() {
  printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}'
}

# Write one template file into the synthetic source tree.
_write_template() {
  # Separate statements on purpose: a single `local a=$1 b=$SOURCE/$a` expands
  # every right-hand side before any assignment takes effect, so `$a` would be
  # empty there.
  local rel="$1"
  local content="$2"
  local path="$SOURCE_REPO/templates/project/$rel"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$path"
}

# Commit everything currently staged and tag it as a release.
_release() {
  local tag="$1"
  git -C "$SOURCE_REPO" add -A
  git -C "$SOURCE_REPO" commit -qm "release $tag"
  git -C "$SOURCE_REPO" tag "$tag"
}

# Build a three-release history where a command file changes at each release.
# v1.14.0 content is the "old downstream baseline" a 4Culture-shaped install
# would still be sitting on.
_build_history() {
  _write_template ".claude/commands/wrap.md" "# wrap v1.14.0
Original body.
"
  _write_template ".claude/hooks/stop.sh" '#!/usr/bin/env bash
echo v1.14.0
'
  _write_template ".gitleaks.toml" 'title = "rig"
[allowlist]
description = "v1.14.0"
'
  _release "v1.14.0"

  _write_template ".claude/commands/wrap.md" "# wrap v1.17.0
Original body.
Added upstream line.
"
  _release "v1.17.0"

  _write_template ".claude/commands/wrap.md" "# wrap v1.29.0
Original body.
Added upstream line.
Newest upstream line.
"
  _release "v1.29.0"
}

_resolve() {
  run python3 "$RESOLVER" --source-repo "$SOURCE_REPO" "$@"
}

# ── Core contract: base proven by hash, from a provenance-free baseline ───────

@test "historical base: resolves a legacy flat-manifest baseline with no base_revision" {
  _build_history
  local baseline
  baseline="$(_sha256_string "# wrap v1.14.0
Original body.
")"

  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline" \
    --output "$TEMP_DIR/base.out"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
  [[ "$output" == *'"base_tag":"v1.14.0"'* ]] || return 1
}

@test "historical base: resolved content is the exact recorded baseline" {
  _build_history
  local baseline
  baseline="$(_sha256_string "# wrap v1.14.0
Original body.
")"

  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline" \
    --output "$TEMP_DIR/base.out"

  [ "$status" -eq 0 ]
  [ "$(_sha256 "$TEMP_DIR/base.out")" = "$baseline" ]
}

@test "historical base: picks the tag whose content matches, not the newest" {
  _build_history
  local baseline
  baseline="$(_sha256_string "# wrap v1.17.0
Original body.
Added upstream line.
")"

  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"base_tag":"v1.17.0"'* ]] || return 1
}

@test "historical base: a wrong base_revision hint never changes the resolved base" {
  _build_history
  local baseline
  baseline="$(_sha256_string "# wrap v1.14.0
Original body.
")"

  # 1.29.0 is deliberately the wrong hint -- exactly the 4Culture-shaped case
  # where a version field would have pointed at the wrong template. The hint
  # only orders the scan; hash equality decides.
  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline" \
    --hint-revision 1.29.0

  [ "$status" -eq 0 ]
  [[ "$output" == *'"base_tag":"v1.14.0"'* ]] || return 1
}

@test "historical base: a correct hint short-circuits the tag scan" {
  _build_history
  local baseline
  baseline="$(_sha256_string "# wrap v1.14.0
Original body.
")"

  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline" \
    --hint-revision 1.14.0

  [ "$status" -eq 0 ]
  # The checked-out-template candidate does not match here. It is not a tag,
  # so the counter reports only the hinted tag.
  [[ "$output" == *'"tags_scanned":1'* ]] || return 1
}

# ── Checked-out template candidate ───────────────────────────────────────────

@test "historical base: resolves from the checked-out template before any tag" {
  _build_history
  # v1.29.0 content is what is checked out, and is also the baseline here --
  # the common real case of a file customized since the last install whose
  # template has not moved.
  local baseline
  baseline="$(_sha256_string "# wrap v1.29.0
Original body.
Added upstream line.
Newest upstream line.
")"

  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"base_tag":"worktree"'* ]] || return 1
  [[ "$output" == *'"tags_scanned":0'* ]] || return 1
}

@test "historical base: resolves from the checked-out template with no tags at all" {
  # A shallow clone has no tags. Convergence must still work for the common
  # case rather than degrading to refuse-always.
  _write_template ".claude/commands/wrap.md" "# wrap

Body.
"
  git -C "$SOURCE_REPO" add -A
  git -C "$SOURCE_REPO" commit -qm "no tags here"
  local baseline
  baseline="$(_sha256_string "# wrap

Body.
")"

  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline" \
    --output "$TEMP_DIR/base.out"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"base_tag":"worktree"'* ]] || return 1
  [ "$(_sha256 "$TEMP_DIR/base.out")" = "$baseline" ]
}

@test "historical base: refuses helpfully when there are no tags and the tree does not match" {
  _write_template ".claude/commands/wrap.md" "# wrap

Body.
"
  git -C "$SOURCE_REPO" add -A
  git -C "$SOURCE_REPO" commit -qm "no tags here"

  _resolve --rel .claude/commands/wrap.md \
    --recorded-hash "$(_sha256_string 'some older release content')"

  [ "$status" -eq 1 ]
  [[ "$output" == *"no release tags"* ]] || return 1
  [[ "$output" == *"git fetch --tags"* ]] || return 1
}

@test "historical base: never follows a symlinked template in the checked-out tree" {
  _build_history
  local template="$SOURCE_REPO/templates/project/.claude/commands/linked.md"
  printf 'secret content\n' > "$TEMP_DIR/outside.md"
  ln -s "$TEMP_DIR/outside.md" "$template"

  _resolve --rel .claude/commands/linked.md \
    --recorded-hash "$(_sha256_string 'secret content
')"

  [ "$status" -eq 1 ]
  [[ "$output" == *'"ok":false'* ]] || return 1
}

# ── Artifact-kind coverage ───────────────────────────────────────────────────

@test "historical base: resolves a shell hook baseline" {
  _build_history
  local baseline
  baseline="$(_sha256_string '#!/usr/bin/env bash
echo v1.14.0
')"

  _resolve --rel .claude/hooks/stop.sh --recorded-hash "$baseline" \
    --output "$TEMP_DIR/base.out"

  [ "$status" -eq 0 ]
  # This hook is byte-identical across every fixture release, so several tags
  # reproduce the baseline and the newest matching one is reported. Assert on
  # the resolved *content*, which is what the merge actually consumes -- the
  # reported tag is provenance, and any tag yielding identical bytes is an
  # equally correct answer.
  [ "$(_sha256 "$TEMP_DIR/base.out")" = "$baseline" ]
}

@test "historical base: resolves a TOML baseline" {
  _build_history
  local baseline
  baseline="$(_sha256_string 'title = "rig"
[allowlist]
description = "v1.14.0"
')"

  _resolve --rel .gitleaks.toml --recorded-hash "$baseline"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
}

@test "historical base: resolves a process Markdown baseline" {
  _write_template ".rig/processes/SHIP_WORKFLOW.md" "# Ship
Step one.
"
  _release "v1.20.0"
  local baseline
  baseline="$(_sha256_string "# Ship
Step one.
")"

  _resolve --rel .rig/processes/SHIP_WORKFLOW.md --recorded-hash "$baseline"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
}

@test "historical base: resolves a dispatcher baseline" {
  _write_template "bin/rig" '#!/usr/bin/env bash
echo rig v1.20.0
'
  _release "v1.20.0"
  local baseline
  baseline="$(_sha256_string '#!/usr/bin/env bash
echo rig v1.20.0
')"

  _resolve --rel bin/rig --recorded-hash "$baseline"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
}

# ── Substitution ─────────────────────────────────────────────────────────────

@test "historical base: resolves a baseline that was substituted after copy" {
  _write_template "CLAUDE.md" "# [Project Name]

base-branch: [BASE_BRANCH]
"
  _release "v1.20.0"
  local baseline
  baseline="$(_sha256_string "# 4Culture

base-branch: develop
")"

  _resolve --rel CLAUDE.md --recorded-hash "$baseline" \
    --project-name "4Culture" --base-branch "develop"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
}

@test "historical base: resolves an unsubstituted baseline for a non-allowlisted file" {
  # install.sh substitutes [BASE_BRANCH] only in an allowlist of files, so a
  # command file containing the placeholder lands on disk unsubstituted. Both
  # renderings are candidates; only the one that hashes correctly is accepted.
  _write_template ".claude/commands/task.md" "# task

Target: [BASE_BRANCH]
"
  _release "v1.20.0"
  local baseline
  baseline="$(_sha256_string "# task

Target: [BASE_BRANCH]
")"

  _resolve --rel .claude/commands/task.md --recorded-hash "$baseline" \
    --base-branch "develop"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":true'* ]] || return 1
}

# ── Generated Codex mirrors ──────────────────────────────────────────────────

@test "historical base: reproduces a generated Codex mirror from the historical generator" {
  _write_template ".claude/commands/wrap.md" "# wrap

Run /wrap to finish.
"
  mkdir -p "$SOURCE_REPO/installer"
  cp "$REPO_ROOT/installer/generate-codex-skills.py" "$SOURCE_REPO/installer/"
  _release "v1.20.0"

  # Produce the artifact the same way the release would have.
  local out="$TEMP_DIR/gen"
  mkdir -p "$out"
  python3 "$SOURCE_REPO/installer/generate-codex-skills.py" --output "$out" \
    --base-branch develop "$SOURCE_REPO/templates/project/.claude/commands/wrap.md"
  local baseline
  baseline="$(_sha256 "$out/wrap/references/command.md")"

  _resolve --rel .agents/skills/wrap/references/command.md \
    --recorded-hash "$baseline" --base-branch develop \
    --output "$TEMP_DIR/gen-base.out"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"generated":true'* ]] || return 1
  # Reproduced by replaying the generator, never copied from downstream.
  [ "$(_sha256 "$TEMP_DIR/gen-base.out")" = "$baseline" ]
}

@test "historical base: reproduces a generated mirror from a tag when the tree has moved on" {
  _write_template ".claude/commands/wrap.md" "# wrap

Run /wrap to finish.
"
  mkdir -p "$SOURCE_REPO/installer"
  cp "$REPO_ROOT/installer/generate-codex-skills.py" "$SOURCE_REPO/installer/"
  _release "v1.20.0"

  local out="$TEMP_DIR/gen"
  mkdir -p "$out"
  python3 "$SOURCE_REPO/installer/generate-codex-skills.py" --output "$out" \
    --base-branch develop "$SOURCE_REPO/templates/project/.claude/commands/wrap.md"
  local baseline
  baseline="$(_sha256 "$out/wrap/references/command.md")"

  # Move the checked-out command on, so only the tagged revision reproduces it.
  _write_template ".claude/commands/wrap.md" "# wrap

Rewritten upstream.
"
  _release "v1.21.0"

  _resolve --rel .agents/skills/wrap/references/command.md \
    --recorded-hash "$baseline" --base-branch develop

  [ "$status" -eq 0 ]
  [[ "$output" == *'"base_tag":"v1.20.0"'* ]] || return 1
}

@test "historical base: refuses a generated mirror whose canonical command is unresolvable" {
  _write_template ".claude/commands/wrap.md" "# wrap
"
  mkdir -p "$SOURCE_REPO/installer"
  cp "$REPO_ROOT/installer/generate-codex-skills.py" "$SOURCE_REPO/installer/"
  _release "v1.20.0"

  _resolve --rel .agents/skills/no-such-command/SKILL.md \
    --recorded-hash "$(_sha256_string 'anything')" --base-branch develop

  [ "$status" -eq 1 ]
  [[ "$output" == *'"ok":false'* ]] || return 1
  [[ "$output" == *"no canonical Claude command"* ]] || return 1
}

@test "historical base: refuses a generated skill path with no <name>/<artifact> shape" {
  _build_history

  _resolve --rel .agents/skills/SKILL.md \
    --recorded-hash "$(_sha256_string 'anything')"

  [ "$status" -eq 1 ]
  [[ "$output" == *"no <name>/<artifact> shape"* ]] || return 1
}

# ── Hostile manifest input ───────────────────────────────────────────────────

@test "historical base: refuses a manifest path that escapes the template tree" {
  _build_history
  # `rel` comes from the target project's manifest — the file this resolver
  # exists to distrust. Without a traversal guard this is an arbitrary file
  # read anywhere the installer can reach.
  printf 'secret content\n' > "$TEMP_DIR/outside.txt"

  _resolve --rel ../../../outside.txt \
    --recorded-hash "$(_sha256_string 'secret content
')" --output "$TEMP_DIR/leaked"

  [ "$status" -eq 1 ]
  [[ "$output" == *"escapes the template tree"* ]] || return 1
  [ ! -e "$TEMP_DIR/leaked" ]
}

@test "historical base: refuses an absolute manifest path" {
  _build_history

  _resolve --rel /etc/hosts --recorded-hash "$(_sha256_string 'anything')"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not relative"* ]] || return 1
}

@test "historical base: refuses a manifest path with an embedded traversal" {
  _build_history

  _resolve --rel .claude/commands/../../../../outside.txt \
    --recorded-hash "$(_sha256_string 'anything')"

  [ "$status" -eq 1 ]
  [[ "$output" == *"escapes the template tree"* ]] || return 1
}

# ── I/O failures stay on the JSON contract ───────────────────────────────────

@test "historical base: an unwritable output path reports JSON, not a traceback" {
  _build_history
  local baseline
  baseline="$(_sha256_string "# wrap v1.14.0
Original body.
")"

  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline" \
    --output "$TEMP_DIR/no-such-dir/base.out"

  # Exit 2 is the I/O code; exit 1 would misreport this as a refusal.
  [ "$status" -eq 2 ]
  [[ "$output" != *"Traceback"* ]] || return 1
  echo "$output" | python3 -c 'import json,sys; json.loads(sys.stdin.read())'
}

# ── Generated mirrors: a gap at one revision is not a dead end ───────────────

@test "historical base: keeps scanning when a command is absent at a newer tag" {
  # v1.10.0 has the command (and is the provable base); v1.11.0 removes it.
  # Aborting the scan at v1.11.0 would refuse a base v1.10.0 reproduces exactly.
  _write_template ".claude/commands/wrap.md" "# wrap

Original.
"
  mkdir -p "$SOURCE_REPO/installer"
  cp "$REPO_ROOT/installer/generate-codex-skills.py" "$SOURCE_REPO/installer/"
  _release "v1.10.0"

  local out="$TEMP_DIR/gen"
  mkdir -p "$out"
  python3 "$SOURCE_REPO/installer/generate-codex-skills.py" --output "$out" \
    --base-branch develop "$SOURCE_REPO/templates/project/.claude/commands/wrap.md"
  local baseline
  baseline="$(_sha256 "$out/wrap/references/command.md")"

  rm "$SOURCE_REPO/templates/project/.claude/commands/wrap.md"
  _write_template ".claude/commands/other.md" "# other
"
  _release "v1.11.0"

  _resolve --rel .agents/skills/wrap/references/command.md \
    --recorded-hash "$baseline" --base-branch develop

  [ "$status" -eq 0 ]
  [[ "$output" == *'"base_tag":"v1.10.0"'* ]] || return 1
}

# ── Refusals: never guess ────────────────────────────────────────────────────

@test "historical base: refuses when no revision reproduces the recorded baseline" {
  _build_history

  _resolve --rel .claude/commands/wrap.md \
    --recorded-hash "$(_sha256_string 'content that was never released')"

  [ "$status" -eq 1 ]
  [[ "$output" == *'"ok":false'* ]] || return 1
  [[ "$output" == *"no historical revision reproduces the recorded baseline"* ]] || return 1
  [[ "$output" == *'"repair_guidance"'* ]] || return 1
}

@test "historical base: refusal names how many revisions were scanned" {
  _build_history

  _resolve --rel .claude/commands/wrap.md \
    --recorded-hash "$(_sha256_string 'never released')"

  [ "$status" -eq 1 ]
  # Each distinct released revision of this file. The checked-out template is
  # examined first but is not a tag, so it is not included in this count.
  [[ "$output" == *'"tags_scanned":3'* ]] || return 1
}

@test "historical base: writes no output file when it refuses" {
  _build_history

  _resolve --rel .claude/commands/wrap.md \
    --recorded-hash "$(_sha256_string 'never released')" \
    --output "$TEMP_DIR/should-not-exist"

  [ "$status" -eq 1 ]
  [ ! -e "$TEMP_DIR/should-not-exist" ]
}

@test "historical base: refuses a path with no template of record" {
  _build_history

  _resolve --rel .rig/memory/PROGRESS.md \
    --recorded-hash "$(_sha256_string 'anything')"

  [ "$status" -eq 1 ]
  [[ "$output" == *"no historical template exists"* ]] || return 1
}

@test "historical base: refuses when the installer source is not a git work tree" {
  mkdir -p "$TEMP_DIR/not-a-repo"

  run python3 "$RESOLVER" --source-repo "$TEMP_DIR/not-a-repo" \
    --rel .claude/commands/wrap.md \
    --recorded-hash "$(_sha256_string 'anything')"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git work tree"* ]] || return 1
}

@test "historical base: refuses when the installer source exposes no release tags" {
  _write_template ".claude/commands/wrap.md" "# wrap
"
  git -C "$SOURCE_REPO" add -A
  git -C "$SOURCE_REPO" commit -qm "no tags"

  _resolve --rel .claude/commands/wrap.md \
    --recorded-hash "$(_sha256_string 'anything')"

  [ "$status" -eq 1 ]
  [[ "$output" == *"no release tags"* ]] || return 1
}

@test "historical base: refuses a malformed recorded hash" {
  _build_history

  _resolve --rel .claude/commands/wrap.md --recorded-hash "not-a-sha256"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not a SHA256 hex digest"* ]] || return 1
}

@test "historical base: emits exactly one machine-readable JSON line" {
  _build_history
  local baseline
  baseline="$(_sha256_string "# wrap v1.14.0
Original body.
")"

  _resolve --rel .claude/commands/wrap.md --recorded-hash "$baseline"

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  echo "$output" | python3 -c 'import json,sys; json.loads(sys.stdin.read())'
}

# ── 4Culture-shaped end-to-end fixture ───────────────────────────────────────

@test "4Culture-shaped fixture: every legacy flat-manifest baseline resolves" {
  _build_history

  # A legacy flat manifest: sha256 + path, no provenance whatsoever. This is
  # exactly the shape that blocked the v1.29.0 rollout.
  local manifest="$TEMP_DIR/.rig-manifest"
  {
    echo "# The Rig manifest"
    echo "$(_sha256_string "# wrap v1.14.0
Original body.
")  .claude/commands/wrap.md"
    echo "$(_sha256_string '#!/usr/bin/env bash
echo v1.14.0
')  .claude/hooks/stop.sh"
    echo "$(_sha256_string 'title = "rig"
[allowlist]
description = "v1.14.0"
')  .gitleaks.toml"
  } > "$manifest"

  local resolved=0 total=0 line hash rel
  while read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    hash="${line%% *}"
    rel="${line##* }"
    total=$((total + 1))
    if python3 "$RESOLVER" --source-repo "$SOURCE_REPO" --rel "$rel" \
        --recorded-hash "$hash" >/dev/null 2>&1; then
      resolved=$((resolved + 1))
    fi
  done < "$manifest"

  [ "$total" -eq 3 ]
  [ "$resolved" -eq 3 ]
}

@test "4Culture-shaped fixture: resolving a base mutates nothing in the source" {
  _build_history
  local before
  before="$(git -C "$SOURCE_REPO" status --porcelain)"

  _resolve --rel .claude/commands/wrap.md \
    --recorded-hash "$(_sha256_string "# wrap v1.14.0
Original body.
")" --output "$TEMP_DIR/base.out"

  [ "$status" -eq 0 ]
  [ "$(git -C "$SOURCE_REPO" status --porcelain)" = "$before" ]
  [ "$(git -C "$SOURCE_REPO" rev-parse HEAD)" = "$(git -C "$SOURCE_REPO" rev-parse v1.29.0)" ]
}
