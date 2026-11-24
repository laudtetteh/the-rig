# Command: /rig-status

Show where the project stands, with a one-line Rig health verdict. Add
`--health` for the full installation health check.
Pure diagnostic — no writes, no side effects.

## What this does

- **Default (`/rig-status`):** a project dashboard — branch, active tasks,
  backlog count, recent progress, pending flags — followed by one health line
  from `bin/rig doctor --json`.
- **`/rig-status --health`:** the full six-section installation check below.
  Items that are missing or broken are flagged with ✗ and a one-line fix hint.
  Items that are healthy are shown with ✓.

This command replaces the former `/rig-status`, which shadowed Claude Code's
built-in `/status` panel (version, model, account, API connectivity). Use the
built-in `/status` for those.

## Usage

```
/rig-status            # project dashboard + one-line health verdict
/rig-status --health   # full installation health check
```

Run the default:
- At the start of a session as a faster alternative to reading full context files
- After a long task to orient before deciding what's next
- When the user asks "where are we?", "what's active?", or "what's in the backlog?"

Run `--health`:
- After a fresh install to verify everything wired correctly
- When a hook is not firing and you want to diagnose why
- After an upgrade to confirm files updated as expected
- Any time you need a full "is The Rig healthy?" answer

---

> **RIG_DIR resolution (stealth mode):** Before reading any `.rig/` path,
> resolve where `.rig/` actually lives. If `.rigpath` exists at the project
> root, read it — it contains the absolute path to the external `.rig/`
> directory.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> if [[ -e "$REPO/.rigpath" || -L "$REPO/.rigpath" ]]; then
>   RIG_DIR=$(python3 "$REPO/bin/rig-path.py" "$REPO") || exit 1
> else
>   RIG_DIR="$REPO/.rig"
> fi
> ```
>
> Substitute `$RIG_DIR` for `.rig/` in every check below. `$RIG_DIR` is the
> resolved Rig directory, not the repository; `$REPO` is the repository root.

---

## Default mode — project dashboard

Use this mode unless the arguments contain `--health`. Output a clean,
scannable dashboard — not walls of text.

### 1. Branch

```bash
git branch --show-current
```

Show: `**Branch:** [name]`

### 2. Active tasks

```bash
ls "$RIG_DIR/tasks/active/" 2>/dev/null
```

Ignore dotfiles such as `.gitkeep`. For each task file: read the `## Goal`
section (first sentence only) and the `**Status**` field. Format as a bullet
list:

```
**Active tasks (N):**
- TASK_foo.md — [one-sentence goal]
```

If none: `**Active tasks:** none`

### 3. Backlog

Count task files in `$RIG_DIR/tasks/backlog/`, excluding dotfiles and
`TASK_example.md*`. Show: `**Backlog:** N task(s)` — count only, no details.

### 4. Recent progress

Read `$RIG_DIR/memory/PROGRESS.md`. New entries are inserted at the top
(after the `## Format` section when it exists), so the most recent entries are
the first entry headings in the file — not the last ones. Skip the `## Format`
heading and any `##` line inside a fenced code block (the format example).
Show the five most recent entry headings and the first body line under each:

```
**Recent progress:**
- [section heading] — [first body line]
```

If the file is absent: skip this section.

### 5. Pending flags

```bash
[[ -f "$RIG_DIR/memory/.wrap-needed" ]] && echo "wrap-needed"
[[ -f "$RIG_DIR/memory/.post-merge-pending" ]] && echo "post-merge-pending"
```

If `.wrap-needed` exists: `⚠️ /wrap needed — last session didn't wrap`
If `.post-merge-pending` exists: `⚠️ /post-merge pending — a merge landed since last run`

If no flags: omit this section.

### 6. Health verdict

```bash
python3 - "$REPO" <<'PY'
import json, subprocess, sys
repo = sys.argv[1]
try:
    out = subprocess.run([f"{repo}/bin/rig", "doctor", "--json"], capture_output=True,
                         text=True, timeout=60).stdout
    summary = json.loads(out)["summary"]
    print(f"pass={summary.get('pass', 0)} fail={summary.get('fail', 0)}")
except Exception as exc:
    print(f"unavailable ({type(exc).__name__})")
PY
```

- `fail=0`: `**Rig health:** ✓ healthy`
- `fail>0`: `**Rig health:** ✗ [N] check(s) failing — run /rig-status --health or bin/rig doctor`
- `unavailable`: `**Rig health:** not checked (bin/rig doctor unavailable) — run /rig-status --health`

Stop here in default mode.

---

## Health mode (`--health`) — report format

Print the header line, then work through each section. Keep it scannable:
✓ lines are one-liners. ✗ lines include a concrete fix hint.

```
## Rig Status — [project name from CLAUDE.md] — [YYYY-MM-DD]
```

---

## Section 1 — Identity

Read from `CLAUDE.md` and `$RIG_DIR/VERSION`:

```bash
RIG_VERSION=$(cat "$RIG_DIR/VERSION" 2>/dev/null || echo "unknown")
BASE_BRANCH=$(grep "^base-branch:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
TRACKER_JSON=$(python3 "$REPO/bin/rig-tracker-config.py" show "$REPO/CLAUDE.md") || exit 1
ISSUE_TRACKING=$(printf '%s' "$TRACKER_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tracker"])') || exit 1
```

Output:
```
**Rig version:** [RIG_VERSION]
**Base branch:** [BASE_BRANCH or "not set in CLAUDE.md"]
**Issue tracking:** [ISSUE_TRACKING (normalized; `github` when absent)]
```

**Tracking mode** — detect from the file system:
- If `.rigpath` exists: `stealth → [contents of .rigpath]`
- Else if `$RIG_DIR` is inside the repo AND in `.git/info/exclude`: `local`
- Else if `$RIG_DIR` is inside the repo AND tracked by git: `repo`
- Else: `unknown`

```
**Tracking mode:** [mode]
```

---

## Section 2 — Hooks

Check each hook file for existence and executable bit. Two categories:

**Claude Code hooks** (in `$REPO/.claude/hooks/`):

| Hook event | File |
|---|---|
| PreToolUse | `pre-tool.sh` |
| PostToolUse | `post-tool.sh` |
| Stop | `stop.sh` |
| SessionStart | `session-start.sh` |
| UserPromptSubmit | `prompt-submit.sh` |
| PermissionRequest | `permission-request.sh` |
| PreCompact | `pre-compact.sh` |
| PostCompact | `post-compact.sh` |
| SessionEnd | `stop.sh` |

For each, check `$REPO/.claude/hooks/<name>.sh`:
- ✓ `[event] → .claude/hooks/[file] (exists, executable)`
- ✗ `[event] → .claude/hooks/[file] (MISSING)` — Fix: run `/rig-upgrade` or reinstall
- ✗ `[event] → .claude/hooks/[file] (not executable)` — Fix: `chmod +x .claude/hooks/[file]`

**Git hooks** — check both `.git/hooks/` (stealth/local) and `.husky/` (repo mode):

Determine which hooks directory is active:
```bash
if [[ -d "$REPO/.git/hooks" ]] && [[ -f "$REPO/.git/hooks/pre-commit" || -f "$REPO/.husky/pre-commit" ]]; then
  # Check both locations
fi
```

For each git hook (`pre-commit`, `commit-msg`, `post-commit`, `post-merge`):
- Check `.git/hooks/<name>` first, then `.husky/<name>`
- ✓ `[hook] → [location] (exists, executable)`
- ✗ `[hook] → (MISSING in both .git/hooks/ and .husky/)` — Fix: run installer repair mode

Output section heading: `**Hooks:**`

---

## Section 3 — Memory files

Check existence and basic stats for each memory file:

```bash
SNAP="$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
PROG="$RIG_DIR/memory/PROGRESS.md"
ERRS="$RIG_DIR/memory/ERRORS.md"
DECS="$RIG_DIR/memory/DECISIONS.md"
GAPS="$RIG_DIR/memory/RIG_GAPS.md"
```

For `CONTEXT_SNAPSHOT.md`:
- ✓ `CONTEXT_SNAPSHOT.md (last updated: [date from **Last updated:** field in file])`
- ✗ `CONTEXT_SNAPSHOT.md (missing)` — Fix: run `/wrap` to create it

For `PROGRESS.md`:
- Count `## ` headers: `grep -c "^## " "$PROG" 2>/dev/null || echo 0`
- ✓ `PROGRESS.md ([N] entries)`
- ✗ `PROGRESS.md (missing)` — Fix: run `/wrap` or create manually

For `ERRORS.md`:
- ✓ `ERRORS.md ([N] entries)`
- If missing: note "ERRORS.md (missing — will be created on first error)"

For `DECISIONS.md`:
- ✓ `DECISIONS.md (exists)`
- If missing: note "DECISIONS.md (missing — will be created when first decision is logged)"

For `RIG_GAPS.md`:
- Count unsubmitted entries (lines matching `^## ` but NOT containing `\[submitted`)
- ✓ `RIG_GAPS.md ([N] unsubmitted gap(s))`
- If missing: `RIG_GAPS.md (missing — will be created on first /wrap)`

Output section heading: `**Memory files:**`

---

## Section 4 — Pending flags

Check runtime flag files:

```bash
WRAP_FLAG="$RIG_DIR/memory/.wrap-needed"
MERGE_FLAG="$RIG_DIR/memory/.post-merge-pending"
WORKFLOW_FLAG="$RIG_DIR/memory/.memory-workflow-in-progress"
LOCK_FLAG="$RIG_DIR/memory/.snapshot-write-in-progress"
NUDGE_FLAG="$RIG_DIR/memory/.permission-nudge-offered"
```

For each:
- If present: `✗ [flag-name] (SET)` with a one-line explanation of what it means
- If absent: `✓ [flag-name] (not set)`

Explanations:
- `.wrap-needed` SET → "last session didn't run /wrap; run it before starting new work"
- `.post-merge-pending` SET → "a merge landed; run /post-merge to sync memory"
- `.memory-workflow-in-progress` SET → "a /wrap or /post-merge memory workflow owns the lock (or was interrupted)"
- `.snapshot-write-in-progress` SET → "the snapshot writer is active or was interrupted; a fresh empty legacy marker blocks writes"
- `.permission-nudge-offered` — this is informational, not a problem; skip in output

Output section heading: `**Pending flags:**`

---

## Section 5 — settings.json

Read `$REPO/.claude/settings.json` using `python3`:

```bash
python3 -c "
import json, sys
try:
    with open('$REPO/.claude/settings.json') as f:
        s = json.load(f)
    hooks = s.get('hooks', {})
    allow = s.get('permissions', {}).get('allow', [])
    events = list(hooks.keys())
    print('HOOKS=' + ','.join(events))
    print('ALLOW_COUNT=' + str(len(allow)))
except Exception as e:
    print('ERROR=' + str(e))
" 2>/dev/null
```

**If `settings.json` is missing:**
- ✗ `.claude/settings.json (MISSING)` — Fix: run installer to create it

**If present:**

For each expected hook event (`PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`,
`UserPromptSubmit`, `PermissionRequest`, `SessionEnd`, `PreCompact`, `PostCompact`):
- ✓ `[event] hook registered`
- ✗ `[event] hook NOT registered` — Fix: run `/rig-upgrade` or reinstall

For `permissions.allow`:
- ✓ `[N] allowed permission patterns` — if N ≥ 5
- `[N] allowed permission patterns (only baseline — in Claude Code, run /fewer-permission-prompts to expand)` — if N > 0 but < 8
- ✗ `0 allowed permission patterns — review provider permission settings; in Claude Code, run /fewer-permission-prompts` — if N == 0

Output section heading: `**settings.json:**`

---

## Section 6 — Overall summary

Count all ✗ items across all sections.

- If 0: `**Overall: ✓ healthy** — no issues detected`
- If 1: `**Overall: 1 issue** — see ✗ item above`
- If 2+: `**Overall: [N] issues** — see ✗ items above`

Do not list the issues again — the user has already read them in context.

---

## Notes

- `/rig-status` is read-only in both modes. It never modifies any file.
- For manifest/stealth diagnostics (provenance, mode/hash drift, stale entries), run
  `bin/rig doctor` (or `bin/rig doctor --json`). Reserve `/rig-debug` for genuine
  hypothesis-driven bug investigation, not manifest inspection.
- If the report shows hooks as present but they still aren't firing, the likely cause
  is that `settings.json` does not register them — check Section 5 output.
