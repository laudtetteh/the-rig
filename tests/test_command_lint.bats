#!/usr/bin/env bats
#
# tests/test_command_lint.bats — Structural linting for command markdown files
#
# Run with: bats tests/test_command_lint.bats
#
# Enforces four structural invariants across every .md file in
# templates/project/.claude/commands/:
#   1. H1 first line matches "# Command: /slug"
#   2. Slug in H1 matches the filename (debug.md → /debug)
#   3. At least one H2 section exists
#   4. No H2 header is missing a space after "##"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
COMMAND_DIR="$REPO_ROOT/templates/project/.claude/commands"

# ── Helpers ───────────────────────────────────────────────────────────────────

_fail_with_list() {
  local label="$1"
  shift
  printf '%s:\n' "$label"
  printf '  %s\n' "$@"
  return 1
}

# ── Tests ─────────────────────────────────────────────────────────────────────

@test "command files: H1 first line matches '# Command: /slug' format" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    local first
    first="$(head -1 "$f")"
    if ! echo "$first" | grep -qE '^# Command: /[a-z-]+$'; then
      failures+=("$(basename "$f"): got '${first}'")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Malformed H1" "${failures[@]}"
}

@test "command files: slug in H1 matches filename" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    local name first slug
    name="$(basename "$f" .md)"
    first="$(head -1 "$f")"
    slug="${first#\# Command: /}"
    if [[ "$slug" != "$name" ]]; then
      failures+=("$(basename "$f"): expected /${name}, H1 says /${slug}")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Slug mismatch" "${failures[@]}"
}

@test "command files: all files have at least one H2 section" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    if ! grep -q "^## " "$f"; then
      failures+=("$(basename "$f")")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "Missing H2 section" "${failures[@]}"
}

@test "command files: no H2 header missing space after '##'" {
  local failures=()
  for f in "$COMMAND_DIR"/*.md; do
    # Matches ## at line start followed by a char that is not # or space.
    # This catches "##Foo" but not "### Foo" (H3) or "## Foo" (valid H2).
    if grep -qE '^##[^# ]' "$f"; then
      failures+=("$(basename "$f")")
    fi
  done
  [ "${#failures[@]}" -eq 0 ] || _fail_with_list "H2 missing space after ##" "${failures[@]}"
}

# ── wrap / post-merge behavior spec ───────────────────────────────────────────

@test "wrap.md: contains Wrap report step section" {
  grep -q "## Wrap report step" "$COMMAND_DIR/wrap.md"
}

@test "wrap checkpoint has an explicit exact-active route that stops before finalization" {
  run python3 - "$COMMAND_DIR/wrap.md" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
route = s[s.index('## Checkpoint route'):s.index('> **RIG_DIR resolution:**')]
for required in ('/wrap --checkpoint', 'confidence: exact', 'state: active',
                 'Checkpoint report', 'before changing any file',
                 'memory workflow-lock acquire --owner-anchor',
                 'memory write-snapshot', 'memory workflow-lock release --token',
                 '**Stop here.**', 'A later ordinary `/wrap`'):
    assert required in route, required
assert route.index('Checkpoint report') < route.index('memory workflow-lock acquire') < route.index('memory write-snapshot') < route.index('memory workflow-lock release') < route.index('**Stop here.**')
for skipped in ('obligation clear', 'session completion', 'transcript pruning',
                'permission scan', 'PR freshness'):
    assert skipped in route[route.index('**Stop here.**'):], skipped
assert 'do not prompt for a commit' in route
assert 'If it is unresolved, ended, ambiguous, or unsafe' in route
PY
  [ "$status" -eq 0 ]
}

@test "wrap.md: Wrap report step defines collection phase and report format" {
  grep -q "Collection phase" "$COMMAND_DIR/wrap.md"
  grep -q "This session" "$COMMAND_DIR/wrap.md"
  grep -q "Wrap report —" "$COMMAND_DIR/wrap.md"
  grep -Fq 'Codex `$wrap` skill' "$COMMAND_DIR/wrap.md"
  grep -Fq 'Session: unresolved — no final session-file write performed' "$COMMAND_DIR/wrap.md"
  grep -Fq '**Final session name:**' "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: combined-task wrap report is final response" {
  grep -Fq 'multiple actions and an argument-free final wrap' "$COMMAND_DIR/wrap.md"
  grep -Fq 'turn must be the Wrap report' "$COMMAND_DIR/wrap.md"
  grep -Fq 'Do not end with an implementation report after a requested final wrap' "$COMMAND_DIR/wrap.md"
  grep -Fq 'Checkpoint report and saved-handoff result' "$COMMAND_DIR/wrap.md"
}

@test "generated Codex wrap reference preserves the explicit checkpoint route" {
  local generated="$BATS_TEST_TMPDIR/generated"
  run python3 "$REPO_ROOT/installer/generate-codex-skills.py" \
    --output "$generated" --base-branch main "$COMMAND_DIR/wrap.md"
  [ "$status" -eq 0 ]
  [ -f "$generated/wrap/SKILL.md" ]
  grep -Fq '$wrap --checkpoint' "$generated/wrap/references/command.md"
  grep -Fq '## Checkpoint route — preserve the exact active session' "$generated/wrap/references/command.md"
  grep -Fq 'checkpoint_verify_snapshot_identity' "$generated/wrap/references/command.md"
}

@test "wrap.md: documents project-only scope and unresolved-session degraded mode" {
  grep -Fq '**Scope:** wrapping [project name] only' "$COMMAND_DIR/wrap.md"
  grep -Fq 'Cross-project work' "$COMMAND_DIR/wrap.md"
  grep -Fq 'run `/post-merge` first' "$COMMAND_DIR/wrap.md"
  grep -Fq 'degraded mode' "$COMMAND_DIR/wrap.md"
  grep -Fq 'fabricate a' "$COMMAND_DIR/wrap.md"
  grep -Fq 'session UUID' "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PROGRESS.md trim executes automatically — no confirmation gate" {
  # Must NOT contain the old 'Trim now?' prompt
  if grep -q "Trim now?" "$COMMAND_DIR/wrap.md"; then return 1; fi
}

@test "wrap.md: ERRORS.md logging infers from context — no 'ask' prompt" {
  # Must NOT ask the user whether anything unexpected happened
  if grep -q "Did anything unexpected" "$COMMAND_DIR/wrap.md"; then return 1; fi
}

@test "wrap.md: trim steps reference Wrap report — not standalone confirmations" {
  grep -q "note in the Wrap report" "$COMMAND_DIR/wrap.md"
}

@test "post-merge.md: contains Post-merge report step section" {
  grep -q "## Post-merge report step" "$COMMAND_DIR/post-merge.md"
}

@test "post-merge.md: Post-merge report step defines collection and report format" {
  grep -q "Collection phase" "$COMMAND_DIR/post-merge.md"
  grep -q "Post-merge report —" "$COMMAND_DIR/post-merge.md"
  grep -Fq 'Codex `$post-merge` skill' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'Post-merge report — skipped' "$COMMAND_DIR/post-merge.md"
  grep -Fq '**Final session name:**' "$COMMAND_DIR/post-merge.md"
}

@test "post-merge.md: documents project-only scope and unresolved-session degraded mode" {
  grep -Fq '**Scope:** post-merge for [project name] only' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'Cross-project work' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'run `/post-merge` for the merged project first, then run' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'In degraded mode for `not_found` or `ended_record`' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'do not fabricate a' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'session UUID' "$COMMAND_DIR/post-merge.md"
}

@test "post-merge.md: executes POST_MERGE_WORKFLOW automatically after report" {
  grep -q "execute POST_MERGE_WORKFLOW steps" "$COMMAND_DIR/post-merge.md"
}

@test "session naming commands share compact-safe evidence model" {
  grep -Fq 'naming_evidence.progress_titles' "$COMMAND_DIR/session-name.md"
  grep -Fq 'Session naming evidence' "$COMMAND_DIR/session-name.md"
  grep -Fq 'checkpoints for another anchor' "$COMMAND_DIR/session-name.md"
  grep -Fq 'naming_evidence.progress_titles' "$COMMAND_DIR/wrap.md"
  grep -Fq 'Session naming evidence' "$COMMAND_DIR/wrap.md"
  grep -Fq 'checkpoints for another anchor' "$COMMAND_DIR/wrap.md"
  grep -Fq 'naming_evidence.progress_titles' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'Session naming evidence' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'checkpoints for another anchor' "$COMMAND_DIR/post-merge.md"
}

@test "rig-upgrade.md: --version separates installed layers from installer checkout" {
  grep -Fq 'GLOBAL_MANIFEST="$HOME/.claude/.rig-global-manifest"' "$COMMAND_DIR/rig-upgrade.md"
  run grep -F '.rig-global-manifest.json' "$COMMAND_DIR/rig-upgrade.md"
  [ "$status" -ne 0 ]
  grep -Fq 'GLOBAL_LAYER_VERSION' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'INSTALLER_CHECKOUT=~/tools/the-rig' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'INSTALLER_BRANCH=$(git -C "$INSTALLER_CHECKOUT" rev-parse --abbrev-ref HEAD' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'INSTALLER_DIRTY="clean"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'INSTALLER_DIRTY="dirty"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'Global installed layer:' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'Preferred installer checkout:' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'branch: main, state: clean' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'global installed layer is at `$GLOBAL_LAYER_VERSION`' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'Preferred installer checkout is at `$INSTALLER_VERSION` but latest release is `$GITHUB_VERSION`' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'git -C ~/tools/the-rig pull --ff-only origin main' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 're-run `/rig-upgrade --version`' "$COMMAND_DIR/rig-upgrade.md"
}

@test "wrap and post-merge stop on external Rig memory permission failure" {
  for command in wrap post-merge; do
    grep -Fq 'Unable to write Rig memory lock' "$COMMAND_DIR/$command.md"
    grep -Fq 'Operation not permitted' "$COMMAND_DIR/$command.md"
    grep -Fq 'request scoped write approval for $RIG_DIR' "$COMMAND_DIR/$command.md"
    grep -Fq 'No further memory writes were attempted.' "$COMMAND_DIR/$command.md"
  done
}

@test "task uses the fixed PROGRESS anchor and run defers completion to post-merge" {
  grep -q 'immediately after the `## Format`' "$COMMAND_DIR/task.md"
  grep -q "Never anchor the insertion to the" "$COMMAND_DIR/task.md"
  grep -q "own prior PROGRESS edit from the same" "$COMMAND_DIR/task.md"
  grep -Fq '/post-merge` owns the single active-to-done move' "$COMMAND_DIR/run.md"
}

@test "rig-help baseline deny patterns match shipped settings.json" {
  grep -Fq '`rm -rf *`, `git push --force*`, `git push -f*`' "$COMMAND_DIR/rig-help.md"

  run grep -Eq 'DROP TABLE|TRUNCATE' "$COMMAND_DIR/rig-help.md"
  [ "$status" -ne 0 ]
}

@test "rig-help lists every shipped command and only documented sprint selection" {
  run python3 - "$COMMAND_DIR" <<'PY'
from pathlib import Path
import re
import sys

commands = Path(sys.argv[1])
help_text = (commands / "rig-help.md").read_text()
listed = set(re.findall(r"^\| `/([a-z-]+)(?: <[^`]+>)?` \|", help_text, re.M))
shipped = {path.stem for path in commands.glob("*.md")}
assert shipped <= listed, f"missing commands: {sorted(shipped - listed)}"
row = next(line for line in help_text.splitlines() if line.startswith("| `/sprint` |"))
assert "--issues" not in row
for term in ("issue refs", "--all", "audit-only", "plan-only", "repair-and-plan", "resume"):
    assert term in row, term
PY
  [ "$status" -eq 0 ]
}

@test "post-merge summary specifies an input for snapshot writing" {
  run python3 - "$COMMAND_DIR/post-merge.md" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
summary = text.split("### Execution", 1)[1].split("All steps execute automatically", 1)[0]
line = next(line for line in summary.splitlines() if "memory write-snapshot" in line)
assert "--file" in line or "--stdin" in line, line
assert "--shared-only" in line
assert '"$SNAP_DRAFT"' in line, line
assert 'SNAP_DRAFT="$RIG_DIR/memory/.snapshot-draft-' in text
PY
  [ "$status" -eq 0 ]
}

@test "rig-gaps.md: quick-add mode uses structured memory helper" {
  grep -Fq '/rig-gaps --add "short title"' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq '## Quick-add mode (`--add`)' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq 'memory append-gap' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq -- '--scope "$SCOPE"' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq 'Do not mark the entry' "$COMMAND_DIR/rig-gaps.md"
}

@test "rig-gaps.md: triage mode delegates to validated workflow" {
  grep -Fq '/rig-gaps --triage' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq '## Triage mode (`--triage`)' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq '.rig/processes/RIG_GAPS_TRIAGE.md' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq 'file-new' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq 'covered-open' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq 'covered-closed/stale' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq 'project-local' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq 'needs-more-evidence' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq 'separate explicit mutation approval' "$COMMAND_DIR/rig-gaps.md"
}

@test "new-task workflow uses shipped GitHub issue field for batches" {
  local process="$REPO_ROOT/templates/project/.rig/processes/NEW_TASK_WORKFLOW.md"
  local task="$REPO_ROOT/templates/project/.rig/tasks/backlog/TASK_example.md"
  grep -Fq '**GitHub issue**: #[N]' "$task"
  grep -Fq 'for GitHub projects `**GitHub issue**: [ref]`' "$process"
  grep -Fq 'for GitHub projects `**GitHub issue**: #N, #M`' "$process"
  if grep -Fq '**Issue**:' "$process"; then return 1; fi
}

@test "shipped tracker mutation examples require nearby exact action approval" {
  run python3 - "$REPO_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]) / "templates/project"
paths = list((root / ".claude/commands").glob("*.md"))
paths += list((root / ".rig/processes").glob("*.md"))
mutation = re.compile(r"\bgh\s+(?:issue\s+(?:create|edit|comment)|label\s+create|pr\s+comment|pr\s+edit\b[^\n]*--add-label)\b")
for command in ("gh issue create", "gh issue edit", "gh issue comment",
                "gh label create", "gh pr comment", "gh pr edit 1 --add-label bug"):
    assert mutation.search(command), command
assert not mutation.search("gh issue view 42")

def unguarded(lines):
    violations = []
    fence_start = None
    for index, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            fence_start = index if fence_start is None else None
            continue
        if fence_start is None:
            continue
        label_assignment = bool(re.search(r"\bgh\s+pr\s+create\b", line)
                                and "--label" in "\n".join(lines[index:index + 15]).split("```")[0])
        if not mutation.search(line) and not label_assignment:
            continue
        context = " ".join(lines[max(0, fence_start - 16):fence_start]).lower()
        context = re.sub(r"\s+", " ", context)
        if "exact tracker write approval" not in context:
            violations.append((index + 1, line.strip()))
    return violations

for command in ("gh issue create", "gh issue edit", "gh issue comment",
                "gh label create", "gh pr comment", "gh pr edit 1 --add-label bug",
                "gh pr create --label bug"):
    assert unguarded(["```bash", command, "```"]), command
    assert not unguarded(["Exact tracker write approval: show and ask first.",
                          "```bash", command, "```"]), command

violations = []
for path in paths:
    for number, line in unguarded(path.read_text().splitlines()):
        violations.append(f"{path.relative_to(root)}:{number}: {line}")
assert not violations, "Unguarded tracker mutation examples:\n" + "\n".join(violations)
PY
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output"; return 1; fi
  [ "$status" -eq 0 ]
}

@test "generated Codex task ship and rig-gaps retain tracker approval gates" {
  local generated="$BATS_TEST_TMPDIR/tracker-skills"
  run python3 "$REPO_ROOT/installer/generate-codex-skills.py" \
    --output "$generated" --base-branch main \
    "$COMMAND_DIR/task.md" "$COMMAND_DIR/ship.md" "$COMMAND_DIR/rig-gaps.md"
  [ "$status" -eq 0 ]
  for command in task ship rig-gaps; do
    [ -f "$generated/$command/references/command.md" ]
    grep -Fq 'Exact tracker write approval' "$generated/$command/references/command.md"
  done
}

@test "global and project policies require approval for each tracker write" {
  grep -Fq 'Require exact approval before every external tracker write' \
    "$REPO_ROOT/templates/global/CLAUDE.md"
  grep -Fq 'For a batch, repeat the' \
    "$REPO_ROOT/templates/project/.rig/rules/security.md"
  grep -Fq 'files it only after the user approves that individual write' \
    "$REPO_ROOT/templates/project/CLAUDE.md"
  grep -Fq 'Existing installations may retain a user-owned' \
    "$REPO_ROOT/docs/customizing.md"
}

@test "rig-gaps triage process names Claude and Codex collect commands" {
  local process="$REPO_ROOT/templates/project/.rig/processes/RIG_GAPS_TRIAGE.md"
  grep -Fq 'Claude `/rig-gaps --collect` or Codex' "$process"
  grep -Fq '`$rig-gaps --collect`' "$process"
  if grep -Fq 'Run `/rig-gaps --collect` first' "$process"; then return 1; fi
}

@test "run.md surfaces scaffold generator refusals and verifies expected files" {
  grep -Fq "### Step 2 — Execute tasks in queue order" "$COMMAND_DIR/run.md"
  grep -Fq "Guard scaffold generators" "$COMMAND_DIR/run.md"
  grep -Fq "Capture the command exit status and read both stdout and stderr" "$COMMAND_DIR/run.md"
  grep -Fq "non-empty directory" "$COMMAND_DIR/run.md"
  grep -Fq "verify every expected file or directory exists" "$COMMAND_DIR/run.md"
  grep -Fq "Do not report the scaffold as" "$COMMAND_DIR/run.md"
}

@test "docs index convention is wired into feature doc commands" {
  grep -Fq 'docs/INDEX.md' "$COMMAND_DIR/doc-list.md"
  grep -Fq 'runbooks/' "$COMMAND_DIR/doc-list.md"
  grep -Fq 'reports/' "$COMMAND_DIR/doc-list.md"
  grep -Fq 'spikes/' "$COMMAND_DIR/doc-list.md"
  grep -Fq 'agent-ops/' "$COMMAND_DIR/doc-list.md"
  grep -Fq 'not a catch-all bucket' "$COMMAND_DIR/doc-list.md"
  grep -Fq 'docs/INDEX.md' "$COMMAND_DIR/doc-feature.md"
  grep -Fq 'Use this command only for product or business feature traces' "$COMMAND_DIR/doc-feature.md"
  grep -Fq 'docs/INDEX.md' "$COMMAND_DIR/refresh-feature-doc.md"
  grep -Fq 'docs/INDEX.md' "$COMMAND_DIR/rig-help.md"
  run grep -R '\$RIG_DIR/docs' "$COMMAND_DIR"
  [ "$status" -ne 0 ]
}

@test "handoff-checklist preserves explicit two-gate consent" {
  grep -Fq 'explicitly agreed' "$COMMAND_DIR/handoff-checklist.md"
  grep -Fq 'Silence, hesitation, or an ambiguous answer is not consent' "$COMMAND_DIR/handoff-checklist.md"
  grep -Fq 'Do not run `/post-merge`, `/wrap`, or any checklist step' "$COMMAND_DIR/handoff-checklist.md"
}

@test "rig-upgrade commands: every installer pull targets the installer checkout (#663)" {
  local f
  for f in "$COMMAND_DIR/rig-upgrade.md" \
           "$REPO_ROOT/templates/project/.rig/processes/UPGRADE_WORKFLOW.md" \
           "$REPO_ROOT/templates/global/commands/rig-upgrade.md"; do
    run grep -nE '&& git pull|^ *git pull' "$f"
    [ "$status" -ne 0 ] || { echo "bare git pull in $f: $output"; return 1; }
  done
  grep -Fq 'git -C "$INSTALLER_SRC" pull --ff-only origin main' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'git -C "$INSTALLER_SRC" pull --ff-only origin main' "$REPO_ROOT/templates/project/.rig/processes/UPGRADE_WORKFLOW.md"
}

@test "rig-upgrade commands: no force-add, sed manifest splice, mapfile, or hook clobber (#663)" {
  local f
  for f in "$COMMAND_DIR/rig-upgrade.md" \
           "$REPO_ROOT/templates/project/.rig/processes/UPGRADE_WORKFLOW.md"; do
    run grep -nE 'git add -f \.|sed -i .*\$rel|mapfile -d|cp "\$tpl" "\$dest"' "$f"
    [ "$status" -ne 0 ] || { echo "forbidden pattern in $f: $output"; return 1; }
  done
}

@test "rig-upgrade commands: .rigpath is read verbatim, never whitespace-stripped (#663)" {
  local f
  for f in "$COMMAND_DIR/rig-upgrade.md" \
           "$REPO_ROOT/templates/project/.rig/processes/UPGRADE_WORKFLOW.md"; do
    run grep -nE "tr -d '\[:space:\]' < [^|]*rigpath" "$f"
    [ "$status" -ne 0 ] || { echo "whitespace-stripping .rigpath read in $f: $output"; return 1; }
  done
}

@test "rig-upgrade.md: tracking detection mirrors install.sh rules (#663)" {
  grep -Fq '"$HOME/.rig/projects/"*' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'TRACKING="local"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'TRACKING_ARGS+=(--rig-dir "$RIG_DIR")' "$COMMAND_DIR/rig-upgrade.md"
  run grep -F 'if [[ -d "$REPO/.husky" ]]; then TRACKING="external"' "$COMMAND_DIR/rig-upgrade.md"
  [ "$status" -ne 0 ]
}

@test "UPGRADE_WORKFLOW.md: commit approval follows staging and PR follows push (#663)" {
  local wf="$REPO_ROOT/templates/project/.rig/processes/UPGRADE_WORKFLOW.md"
  local stage_line touch_line push_line pr_line
  stage_line=$(grep -n 'git add -A --' "$wf" | head -1 | cut -d: -f1)
  touch_line=$(grep -n 'touch "$RIG_DIR/memory/.rig-commit-ok"' "$wf" | head -1 | cut -d: -f1)
  push_line=$(grep -n 'git push -u origin chore/rig-upgrade' "$wf" | head -1 | cut -d: -f1)
  pr_line=$(grep -n 'gh pr create --base "$BASE_BRANCH"' "$wf" | head -1 | cut -d: -f1)
  [ -n "$stage_line" ]
  [ -n "$touch_line" ]
  [ -n "$push_line" ]
  [ -n "$pr_line" ]
  [ "$stage_line" -lt "$touch_line" ]
  [ "$touch_line" -lt "$push_line" ]
  [ "$push_line" -lt "$pr_line" ]
  grep -Fq 'python3 "$INSTALLER_SRC/installer/repair-stealth.py"' "$wf"
}

@test "global rig-upgrade.md: asks before switching a non-main installer checkout (#663)" {
  local g="$REPO_ROOT/templates/global/commands/rig-upgrade.md"
  grep -Fq 'INSTALLER_BRANCH=$(git -C "$INSTALLER_SRC" branch --show-current' "$g"
  grep -Fq 'Wait for the user'"'"'s response. Only if they choose to switch' "$g"
  run grep -nE '^  git -C "\$INSTALLER_SRC" checkout main$' "$g"
  [ "$status" -ne 0 ]
}

@test "rig-upgrade.md: verifies Codex mirrors after command updates" {
  grep -Fq '.agents/skills/wrap/SKILL.md' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'installer/generate-codex-skills.py' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq -- '--output "$CODEX_STAGE"' "$COMMAND_DIR/rig-upgrade.md"
  run grep -F -- '--output "$REPO/.agents/skills"' "$COMMAND_DIR/rig-upgrade.md"
  [ "$status" -ne 0 ]
  grep -Fq -- '--base-branch "$BASE_BRANCH"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq -- '--skills-source "$INSTALLER_SRC/templates/project/.claude/skills"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq '"${CODEX_COMMAND_SOURCES[@]}"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'Do not patch generated `.agents/skills/*/references/command.md` files by hand' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'PROJECT_TARGETS_FILE="$RIG_DIR/install-targets.json"' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'CODEX_INFRA_STATUS' "$COMMAND_DIR/rig-upgrade.md"
  grep -Fq 'bin/rig session retrofit --agent codex --from-env --source resume --json' "$COMMAND_DIR/rig-upgrade.md"
}

# ── PR description freshness ───────────────────────────────────────────────────

@test "wrap.md: contains PR description freshness step" {
  grep -q "## PR description freshness step" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PR freshness step skips housekeeping commit types" {
  grep -q "chore(memory)" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: PR freshness step skips silently when no open PR" {
  grep -q "skip silently" "$COMMAND_DIR/wrap.md"
}

@test "ship.md: Step 9 compares commits against existing PR description before prompting" {
  grep -q "compare the branch commits against the existing PR description" "$COMMAND_DIR/ship.md"
}

@test "ship.md: Step 9 skips housekeeping commit types in freshness check" {
  grep -qE "chore\(memory\)" "$COMMAND_DIR/ship.md"
}

@test "code-review.md: requires dependency impact analysis before findings" {
  grep -Fq "## Step 4.5 — Dependency impact analysis" "$COMMAND_DIR/code-review.md"
  grep -Fq "Canonical sources and generated artifacts" "$COMMAND_DIR/code-review.md"
  grep -Fq "Upstream/downstream install and upgrade paths" "$COMMAND_DIR/code-review.md"
  grep -Fq "Dependency impact gaps" "$COMMAND_DIR/code-review.md"
}

@test "ship.md: dependency impact gate is blocking and feeds PR evidence" {
  grep -Fq "## Step 4.6 — Dependency impact gate" "$COMMAND_DIR/ship.md"
  grep -Fq "This is a blocking gate" "$COMMAND_DIR/ship.md"
  grep -Fq "Generated artifacts: PASS / N/A / HOLD" "$COMMAND_DIR/ship.md"
  grep -Fq "Retain this matrix and reuse it in the pull request **Dependency impact** section" "$COMMAND_DIR/ship.md"
  grep -Fq "## Dependency impact" "$COMMAND_DIR/ship.md"
}

@test "sprint workflow codifies Dependency Surface Audit planning gate" {
  local process="$REPO_ROOT/templates/project/.rig/processes/SPRINT_WORKFLOW.md"
  grep -Fq "Dependency Surface Audit (DSA)" "$process"
  grep -Fq "Upstream inputs" "$process"
  grep -Fq "Downstream dependents" "$process"
  grep -Fq "Generated artifacts" "$process"
  grep -Fq "Upgrade/install path" "$process"
  grep -Fq "Cross-agent parity" "$process"
  grep -Fq "Persistent state" "$process"
  grep -Fq "Validation hooks" "$process"
  grep -Fq "Dependency Surface Audit required by" "$COMMAND_DIR/sprint.md"
}

@test "sprint workflow codifies multi-issue and multi-PR batch ledger" {
  local process="$REPO_ROOT/templates/project/.rig/processes/SPRINT_WORKFLOW.md"
  grep -Fq "N issues mapped to M PRs" "$process"
  grep -Fq "## Batch ledger" "$process"
  grep -Fq "| Issue | Task card | Lane | PR | Status | Verification | Post-merge |" "$process"
  grep -Fq "one closing keyword for every intended GitHub issue" "$process"
  grep -Fq "batch post-merge" "$process"
  grep -Fq "summary: one line per PR" "$process"
  grep -Fq "first-class" "$COMMAND_DIR/sprint.md"
  grep -Fq "N-issues-to-M-PRs mapping" "$COMMAND_DIR/sprint.md"
}

@test "ship and post-merge document batch issue and PR handling" {
  grep -Fq "multi-issue PR candidate" "$COMMAND_DIR/ship.md"
  grep -Fq "one closing line per" "$COMMAND_DIR/ship.md"
  grep -Fq "For multi-issue PRs" "$COMMAND_DIR/ship.md"
  grep -Fq "batch ledger" "$COMMAND_DIR/post-merge.md"
  grep -Fq "verify each PR number, merge SHA" "$COMMAND_DIR/post-merge.md"
  grep -Fq "one entry per PR or an explicit combined batch summary" "$COMMAND_DIR/post-merge.md"
}

@test "delegated validation protocol forbids duplicate detached full-suite runs" {
  local process="$REPO_ROOT/templates/project/.rig/processes/SPRINT_WORKFLOW.md"
  grep -Fq "foreground tool calls" "$process"
  grep -Fq "exact command and" "$process"
  grep -Fq "tool/session identifier" "$process"
  grep -Fq "must not start duplicate validation" "$process"
  grep -Fq 'full local `bats tests/` suite requires' "$process"
  grep -Fq "must not run a local full \`bats tests/\` suite" "$COMMAND_DIR/handoff-checklist.md"
}

@test "ship merge guidance verifies GitHub PR state after non-zero merge" {
  grep -Fq "## Step 10 — Merge verification and branch cleanup" "$COMMAND_DIR/ship.md"
  grep -Fq 'gh pr view "$PR_NUMBER" --json state,mergedAt' "$COMMAND_DIR/ship.md"
  grep -Fq "linked worktree" "$COMMAND_DIR/ship.md"
  grep -Fq "local cleanup failure" "$COMMAND_DIR/ship.md"
  grep -Fq "Do not run" "$COMMAND_DIR/ship.md"
  grep -Fq "destructive local branch cleanup" "$COMMAND_DIR/ship.md"
  grep -Fq "do not delete a local linked-worktree branch" "$COMMAND_DIR/ship.md"
  grep -Fq "delete only the remote branch after confirming the PR is merged" "$COMMAND_DIR/ship.md"
  grep -Fq "target" "$COMMAND_DIR/ship.md"
  grep -Fq "PR head branch" "$COMMAND_DIR/ship.md"
}

@test "code-review and ship discover PR validation candidates safely" {
  for command in code-review ship; do
    grep -Fq "Local verification" "$COMMAND_DIR/$command.md"
    grep -Fq "Validation" "$COMMAND_DIR/$command.md"
    grep -Fq "Test plan" "$COMMAND_DIR/$command.md"
    grep -Fq "validation candidates" "$COMMAND_DIR/$command.md"
    grep -Fq "PR-body" "$COMMAND_DIR/$command.md"
    grep -Fq "Never execute arbitrary" "$COMMAND_DIR/$command.md"
    grep -Fq "PR-body commands" "$COMMAND_DIR/$command.md"
    grep -Fq "validation plan" "$COMMAND_DIR/$command.md"
    grep -Fq "safety gates" "$COMMAND_DIR/$command.md"
    grep -Fq "YARN_NO_PROXY" "$COMMAND_DIR/$command.md"
    grep -Fq "env -u YARN_NO_PROXY" "$COMMAND_DIR/$command.md"
    grep -Fq "at most once" "$COMMAND_DIR/$command.md"
  done
}

@test "wrap and post-merge try ended-record retrofit before degraded mode" {
  for command in wrap post-merge; do
    grep -Fq 'session retrofit --agent codex --from-env --source resume --json' "$COMMAND_DIR/$command.md"
    grep -Fq 'session retrofit --agent claude --from-env --source resume --json' "$COMMAND_DIR/$command.md"
    grep -Fq 'active continuation' "$COMMAND_DIR/$command.md"
    grep -Fq 'degraded mode' "$COMMAND_DIR/$command.md"
  done
}

@test "rig-gaps.md: quick-add mode resolves REPO before helper invocation" {
  grep -Fq 'REPO=$(git rev-parse --show-toplevel)' "$COMMAND_DIR/rig-gaps.md"
  grep -Fq '"$REPO/bin/rig" memory append-gap' "$COMMAND_DIR/rig-gaps.md"
}

@test "sprint and connector adapters invoke the repository-local Rig CLI" {
  local sprint_skill="$REPO_ROOT/templates/project/.codex/skills/sprint/SKILL.md"
  for adapter in "$COMMAND_DIR/sprint.md" "$COMMAND_DIR/connector-preflight.md" "$sprint_skill"; do
    grep -Fq 'REPO=$(git rev-parse --show-toplevel)' "$adapter"
    grep -Fq '"$REPO/bin/rig"' "$adapter"
  done
  grep -Fq '"$REPO/bin/rig" sprint audit|plan|status --json' "$COMMAND_DIR/sprint.md"
  grep -Fq '"$REPO/bin/rig" sprint audit|plan|status --json' "$sprint_skill"
  grep -Fq '"$REPO/bin/rig" connector preflight' "$COMMAND_DIR/connector-preflight.md"
}

@test "project brain points feature docs to the repository in every tracking mode" {
  local brain="$REPO_ROOT/templates/project/CLAUDE.md"
  grep -Fq 'including stealth and external installs' "$brain"
  grep -Fq 'project repository' "$brain"
  grep -Fq '`docs/features/`' "$brain"
  grep -Fq '/feature-context' "$brain"
  if grep -Fq '/feature-doc`' "$brain"; then return 1; fi
  if grep -Fq '$RIG_DIR/docs/features/' "$brain"; then return 1; fi
  grep -Fq 'currently skips automatic transcript pruning' "$brain"
  grep -Fq 'project ownership check' "$brain"
  grep -Fq 'automatic transcript scanning and permission promotion are disabled' "$COMMAND_DIR/wrap.md"
}

@test "PR template captures dependency impact evidence" {
  local template="$REPO_ROOT/templates/project/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fq "## Dependency impact" "$template"
  grep -Fq "Generated artifacts:" "$template"
  grep -Fq "Downstream install/upgrade:" "$template"
  grep -Fq "Cross-agent/runtime parity:" "$template"
  grep -Fq "Runtime/config dependencies:" "$template"
}

@test "rig-help advertises dependency impact review gates" {
  grep -Fq "dependency impact" "$COMMAND_DIR/rig-help.md"
  grep -Fq "coverage, dependency impact, style" "$COMMAND_DIR/rig-help.md"
}

@test "wrap.md: transcript pruning skips ambiguous provider paths" {
  grep -q "transcript-retention-days" "$COMMAND_DIR/wrap.md"
  ! grep -Fq '$HOME/.claude/projects' "$COMMAND_DIR/wrap.md"
  grep -Fq 'Codex has no documented project-scoped transcript directory' "$COMMAND_DIR/wrap.md"
  grep -Fq 'Claude project directory mapping can collide' "$COMMAND_DIR/wrap.md"
  ! grep -Fq 'find "$TRANSCRIPT_DIR"' "$COMMAND_DIR/wrap.md"
}

@test "post-merge housekeeping subjects pass the configured GitHub commit guard" {
  local workflow="$REPO_ROOT/templates/project/.rig/processes/POST_MERGE_WORKFLOW.md"
  local config="$BATS_TEST_TMPDIR/CLAUDE.md"
  printf 'issue-tracking: github\n' > "$config"
  local subjects
  subjects="$(python3 - "$workflow" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
subjects = re.findall(r'commit -m "([^"]+)"', text)
assert len(subjects) == 2, subjects
print('\n'.join(subject.replace('#N', '#664') for subject in subjects))
PY
)"
  while IFS= read -r subject; do
    python3 "$REPO_ROOT/templates/project/bin/rig-tracker-config.py" \
      validate-subject "$config" "$subject" >/dev/null || return 1
  done <<< "$subjects"
}

@test "ship dependency diff includes committed, staged, and new task files" {
  local remote="$BATS_TEST_TMPDIR/remote.git" repo="$BATS_TEST_TMPDIR/project"
  git init -q --bare "$remote"
  git init -q "$repo"
  git -C "$repo" checkout -qb main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" remote add origin "$remote"
  printf 'base\n' > "$repo/base.md"
  git -C "$repo" add base.md
  git -C "$repo" commit -qm base
  git -C "$repo" push -q -u origin main
  git -C "$repo" checkout -qb feature
  printf 'feature\n' > "$repo/feature.md"
  git -C "$repo" add feature.md
  git -C "$repo" commit -qm feature
  printf 'staged\n' > "$repo/staged.md"
  git -C "$repo" add staged.md
  printf 'new\n' > "$repo/new.md"
  local block
  block="$(sed -n '/^# ship-changed-paths:start$/,/^# ship-changed-paths:end$/p' "$COMMAND_DIR/ship.md")"
  run env REPO="$repo" BASE=main bash -c "$block"
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature.md"* && "$output" == *"staged.md"* && "$output" == *"new.md"* ]] || return 1
  [[ "$output" != *"base.md"* ]] || return 1

  # A failed first diff must not be hidden by later successful Git commands.
  local real_git wrapper="$BATS_TEST_TMPDIR/wrapper"
  real_git="$(command -v git)"
  mkdir -p "$wrapper"
  cat > "$wrapper/git" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == diff && "$2" == --name-only && "$3" == origin/main...HEAD ]]; then
  exit 99
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$wrapper/git"
  run env REAL_GIT="$real_git" PATH="$wrapper:$PATH" REPO="$repo" BASE=main bash -c "$block"
  [ "$status" -ne 0 ]

  # Both copies of the command must carry the same explicit failure checks.
  [ "$(grep -Fc 'git diff --name-only "origin/$BASE"...HEAD || exit 1;' "$COMMAND_DIR/ship.md")" -eq 2 ]
}

@test "wrap orphan scan finds active record under external Rig path with apostrophe" {
  local rig="$BATS_TEST_TMPDIR/Rig O'Brien"
  mkdir -p "$rig/memory/sessions/done"
  printf '{"lifecycle":{"state":"active"},"created_at":"2026-11-20","names":{"tentative":"review"}}\n' \
    > "$rig/memory/sessions/session-test.json"
  local block
  block="$(sed -n '/^# orphan-session-scan:start$/,/^# orphan-session-scan:end$/p' "$COMMAND_DIR/wrap.md")"
  run env RIG_DIR="$rig" bash -c "$block"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Orphan session (active, unwrapped): review"* ]] || return 1
  [[ "$output" == *"started 2026-11-20"* ]] || return 1
  [[ "$output" == *"session-test.json"* ]] || return 1

  # A historical flat record still reports its legacy timestamp.
  printf '{"status":"active","started_at":"2020-01-01","tentative_name":"legacy"}\n' \
    > "$rig/memory/sessions/session-legacy.json"
  run env RIG_DIR="$rig" bash -c "$block"
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy (started 2020-01-01"* ]] || return 1
}

@test "ship workflows push the branch before PR creation and find docs templates" {
  python3 - "$COMMAND_DIR/ship.md" "$REPO_ROOT/templates/project/.rig/processes/SHIP_WORKFLOW.md" <<'PY'
import pathlib, sys
for file in sys.argv[1:]:
    text = pathlib.Path(file).read_text()
    assert text.index('git push -u origin "$BRANCH"') < text.index('gh pr create')
    assert 'docs/pull_request_template.md' in text
    assert 'docs/PULL_REQUEST_TEMPLATE.md' in text
PY
}

@test "task completion has one post-merge owner across run and ship" {
  python3 - "$COMMAND_DIR/run.md" "$COMMAND_DIR/ship.md" \
    "$REPO_ROOT/templates/project/.rig/processes/NEW_TASK_WORKFLOW.md" \
    "$REPO_ROOT/templates/project/.rig/processes/SHIP_WORKFLOW.md" \
    "$COMMAND_DIR/post-merge.md" <<'PY'
import pathlib, sys
run, ship, task, workflow, post = [pathlib.Path(p).read_text() for p in sys.argv[1:]]
assert '/post-merge` owns the single active-to-done move' in run
for text in (ship, task, workflow):
    assert 'tasks/active/' in text and '/post-merge' in text
    assert 'until the PR merges' in text or 'after merge' in text
assert 'moves the task file from `$RIG_DIR/tasks/active/`' in post
assert '--retire-task' in post
PY
}

@test "review and workflow docs use remote base, resolved directories, and project CLI" {
  local process="$REPO_ROOT/templates/project/.rig/processes"
  grep -Fq 'git fetch origin "$BASE" || exit 1' "$COMMAND_DIR/code-review.md"
  grep -Fq 'git diff --stat "origin/$BASE"...HEAD || exit 1' "$COMMAND_DIR/code-review.md"
  grep -Fq 'git diff --name-only "origin/$BASE"...HEAD || exit 1' "$COMMAND_DIR/code-review.md"
  grep -Fq 'git diff "origin/$BASE"...HEAD || exit 1' "$COMMAND_DIR/code-review.md"
  grep -Fq 'DOCS_DIR="$REPO/docs"' "$COMMAND_DIR/wrap.md"
  grep -Fq 'DOCS_DIR="$REPO/docs"' "$COMMAND_DIR/post-merge.md"
  grep -Fq 'bin/rig session resolve --json' "$REPO_ROOT/templates/project/.rig/memory/PROGRESS.md"
  grep -Fq '`confidence: exact`' "$REPO_ROOT/templates/project/.rig/memory/PROGRESS.md"
  grep -Fq '"$REPO/bin/rig" sprint audit' "$process/SPRINT_WORKFLOW.md"
  grep -Fq '"$REPO/bin/rig" connector preflight' "$process/CONNECTOR_PREFLIGHT.md"
  grep -Fq 'lint-command from CLAUDE.md' "$COMMAND_DIR/ship.md"
}

@test "wrap.md: contains Permission scan opt-in section" {
  grep -q "## Permission scan (opt-in)" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: permission scan checks .fewer-prompts-enabled sentinel" {
  grep -q ".fewer-prompts-enabled" "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: legacy permission sentinel reports disabled automatic promotion" {
  grep -Fq 'Permission scan skipped: Claude transcript directory mapping can collide' "$COMMAND_DIR/wrap.md"
  grep -Fq 'automatic transcript scanning and permission promotion are disabled' "$COMMAND_DIR/wrap.md"
}

@test "wrap.md: permission scan block reads no transcript or settings file" {
  local block
  block="$(sed -n '/^# permission-scan:start$/,/^# permission-scan:end$/p' "$COMMAND_DIR/wrap.md")"
  [[ "$block" != *"jsonl"* ]] || return 1
  [[ "$block" != *"settings.json"* ]] || return 1
  [[ "$block" != *"python"* ]] || return 1
}
