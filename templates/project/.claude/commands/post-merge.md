# Command: /post-merge

Trigger this command immediately after a PR is merged to main.

`/post-merge` runs the housekeeping that keeps the system clean between sessions:
pulls latest main, updates memory, moves the task file, and surfaces what's next.
It takes about 5 minutes and prevents the drift that accumulates when post-merge
hygiene is skipped.

**Always run this after a merge.** A `.husky/post-merge` git hook will remind you
when you pull a merge commit.

`/post-merge` is scoped to the repository whose PR was merged. If the same
conversation also contains work in another project, do not update that other
project's Rig memory, task files, or session records here. For a combined
handoff after a merge, run `/post-merge` for the merged project first, then run
`/wrap` for the current project; each command owns only its own project state.

---

## What this does

Follows `.rig/processes/POST_MERGE_WORKFLOW.md`:

1. Pulls latest `main` and confirms the expected commit is at HEAD
2. Adds an entry at the top of `.rig/memory/PROGRESS.md` for the merged PR
3. Moves the task file from `.rig/tasks/active/` → `.rig/tasks/done/`; marks `**Status**` as `done`
4. Overwrites `.rig/memory/CONTEXT_SNAPSHOT.md` with the current project state
5. **Checks feature doc freshness** — detects if merged changes overlap with documented features (see below)
6. Checks `.rig/memory/ERRORS.md` and `.rig/memory/RIG_GAPS.md` — prompts you to log anything unexpected or any workflow friction observed
7. Makes a housekeeping commit if memory updates weren't included in the PR
8. **Suggests a session name** based on the merged PR via `/session-name` logic (see below)
9. Surfaces the next priority and asks: **"What's next?"**

---

## Usage

```
/post-merge
```

Run this immediately after you merge (or are told a PR merged). Claude will ask
which PR merged if it's not clear from context.

> **RIG_DIR resolution (stealth mode):** Before reading or writing any `.rig/` path,
> resolve where `.rig/` actually lives. If `.rigpath` exists at the project root, read
> it — it contains the absolute path to the external `.rig/` directory.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> if [[ -f "$REPO/.rigpath" ]]; then
>   RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
> else
>   RIG_DIR="$REPO/.rig"
> fi
> ```
>
> Substitute `$RIG_DIR` for `.rig/` in every step below.

## Concurrent session guard — run before anything else

Check for a `.snapshot-write-in-progress` sentinel before touching CONTEXT_SNAPSHOT.
Both `/wrap` and `/post-merge` write the snapshot; if either is running in another
session, block rather than silently overwrite:

```bash
SNAP_LOCK="$RIG_DIR/memory/.snapshot-write-in-progress"
if [[ -f "$SNAP_LOCK" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$SNAP_LOCK" 2>/dev/null || stat -f %m "$SNAP_LOCK" 2>/dev/null || echo 0) ))
  if [[ "$LOCK_AGE" -gt 1800 ]]; then
    echo "⚠️  Stale lock detected (age: ${LOCK_AGE}s). Auto-removing and proceeding."
    rm -f "$SNAP_LOCK"
  else
    echo "⚠️  A snapshot write is already in progress (/wrap or /post-merge in another session, lock age: ${LOCK_AGE}s)."
    echo "   If the other session is no longer active: rm '$SNAP_LOCK'"
    exit 1
  fi
fi
if ! touch "$SNAP_LOCK"; then
  echo "Unable to write Rig memory lock: $SNAP_LOCK"
  echo "For Codex with an external .rigpath, request scoped write approval for $RIG_DIR and retry /post-merge."
  echo "No further memory writes were attempted."
  exit 1
fi
```

The lock is released in the Flag cleanup step at the very end. Locks older than
30 minutes are automatically expired — they are from crashed sessions.
If creating the sentinel fails with `Operation not permitted`, stop immediately.
This commonly means Codex is running in a project whose `.rigpath` points outside
the workspace writable roots. Request one scoped approval for the resolved
`$RIG_DIR` before retrying; do not continue with partial memory writes.

---

## Git state check — run first, before anything else

Before touching any files, verify the repo is in a known-good state:

```bash
git branch --show-current
git status --short
git log --oneline -3
```

Report briefly:

> "Branch: `[BASE_BRANCH]` | Clean working tree | HEAD: `abc1234 feat: merged PR #N`"

**If the working tree is not clean:** surface any uncommitted changes and ask
the user whether to stash, commit, or discard them before proceeding.

**If not on `[BASE_BRANCH]`:** note the current branch. The POST_MERGE_WORKFLOW Step 1
will `git checkout [BASE_BRANCH] && git pull`, but flag it now so the user is aware.

---

## Post-merge report step

**Run this after the git state check, before executing POST_MERGE_WORKFLOW steps.**
This report-first requirement applies equally to Claude `/post-merge` and the
generated Codex `$post-merge` skill. If no merge is applicable, print a
structured skipped report with the reason and next action, then stop before
writing memory.

### Collection phase

Gather all findings silently — no output yet:

1. **Merged PR** — title, number, branch name (from context or `git log --oneline -1`)
2. **"This session" summary** — from conversation context: all PRs merged or opened, tasks completed, issues resolved this session. Conversation context is the primary signal; PROGRESS.md markers are cross-reference only.
3. **Task file** — which active task file maps to the merged PR (for step 3 of POST_MERGE_WORKFLOW)
4. **ERRORS.md additions** — infer from session context whether any unexpected behaviors, footguns, or pitfalls should be added
5. **Feature doc overlaps** — files changed in the merged PR vs. documented feature entry points (see Feature doc freshness step below)
6. **Session name** — derive suggestion from session file and conversation context
7. **Session identity** — run `bin/rig session resolve --json`; if it returns
   `ended_record` and a native session environment variable is present, first run
   `bin/rig session retrofit --agent codex --from-env --source resume --json` or
   `bin/rig session retrofit --agent claude --from-env --source resume --json`
   to create an exact active continuation. If it returns `not_found`, or
   ended-record retrofit cannot create an exact active continuation, collect the
   rest of the report in degraded mode and skip final session-file mutation.
   Stop on ambiguous, duplicate, cross-project, malformed, or unsafe session
   state.

### Report

Print a single structured report before executing POST_MERGE_WORKFLOW:

```
## Post-merge report — [BASE_BRANCH] — [date]

**Scope:** post-merge for [project name] only
**Cross-project work:** [none | other projects mentioned: project-a, project-b — not updated here]

**Merged:** PR #N — type(scope): description

**This session:**
- PR #N merged: type(scope): description
- [other work items this session]
(omit if this is the only work item)

**ERRORS.md:** [N new entries: short-title-1 | no new entries]
**Feature docs:** [⚠ overlap — run /refresh-feature-doc X | no overlaps]
**Task file:** [TASK_N_slug.md → moving to done/ | no active task found]

**Session name:** [suggested: "type desc #N | type desc #N" | already set — appending: "..." | unresolved — no final session-file write performed | nothing meaningful shipped, skipped]
```

If `/post-merge` is skipped, print instead:

```
## Post-merge report — skipped — [date]

**Reason:** [no merged PR | not on merge commit | working tree dirty | other concrete reason]
**Next action:** [merge a PR first | commit/stash changes | run /wrap only | other concrete action]
```

### Execution

After printing the report, **execute POST_MERGE_WORKFLOW steps 1–8 automatically**:

- Pull latest [BASE_BRANCH] and confirm HEAD
- Update PROGRESS.md
- Move task file to done/
- Write CONTEXT_SNAPSHOT.md
- Add inferred ERRORS.md entries (if any)
- Make housekeeping commit
- Apply session name — only if user says "use that" or equivalent

All steps execute automatically. The session name is the only action requiring explicit user input.

In degraded mode for `not_found` or `ended_record`, continue project-level
post-merge housekeeping and write `CONTEXT_SNAPSHOT.md`, but do not fabricate a
session UUID, do not move any session record to `sessions/done/`, and do not
clear exact-session obligations that require a resolvable active session.

---

## Feature doc freshness step

After updating PROGRESS.md (step 2), check whether the merged PR touched any files
that are covered by an existing feature doc.

**How:**

1. Resolve `$RIG_DIR` and `$DOCS_DIR` (see RIG_DIR resolution block above).
2. If `$DOCS_DIR` doesn't exist or has no `.md` files (other than `README.md`): skip this step silently.
3. Get the set of files changed in the merged commit:
   ```bash
   git diff --name-only HEAD~1 HEAD
   ```
4. For each `.md` file in `$DOCS_DIR` (excluding `README.md`):
   - Read its `## Entry points` section and collect all file paths mentioned.
   - Check if any of the merged-PR changed files match (partial path match is fine — e.g. `src/auth.py` matches `auth` in the entry points).
5. If any feature docs have matching entry points, say:
   > "⚠ The following feature docs may be stale after this merge:
   > - `[feature-name]` (`$DOCS_DIR/<slug>.md`) — entry points overlap with changed files
   > Run `/refresh-feature-doc <name>` to re-verify."
   Do not block the rest of /post-merge — this is advisory only.
6. If no overlap: skip silently.

---

## Session naming step

After the housekeeping commit (step 7), derive a session name suggestion using the
same logic as `/session-name`. The merged PR number is always known here, which
makes this the most reliable naming signal in the system. Do **not** apply it
automatically — present it for the user to confirm or tweak.

### Step 1 — Find this session's UUID and tentative name

Read `$RIG_DIR/rules/session-naming.md` completely first. Its session-local
evidence rules are authoritative for this suggestion.

```bash
REPO=$(git rev-parse --show-toplevel 2>/dev/null)
SESSION_JSON=$("$REPO/bin/rig" session resolve --json) || {
  echo "Unable to resolve this session unambiguously; stop before writing session state."
  exit 1
}
SESSION_FILE=$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
SESSION_UUID=$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")')
TENTATIVE_NAME=$(SESSION_F="$SESSION_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); print(d.get("names",{}).get("tentative") or d.get("tentative_name") or "")')
```

### Step 2 — Collect this session's work

**Conversation context first** — enumerate PRs, tasks, and work you know about.
The merged PR number is always known at this point. File signals are cross-reference:

```bash
grep "^## .*<!-- sid:${SESSION_UUID} -->" "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null || true
```

**Every `## ` entry header written to PROGRESS.md must include `<!-- sid:UUID -->`
at the end of the line.** Read UUID from the resolver output above.

If tentative_name is set, use it as the base (refine based on actual outcome).
Never use `CONTEXT_SNAPSHOT.md`, legacy markers, unrelated session files,
other-session UUID entries, or general project history as naming evidence. An
unresolved raw launch fails closed before any name is proposed or written.

### Step 3 — Build the name

Use the **tiered format** from `/session-name` (same logic — see that command for full detail):

- **≤5 units:** `type short-desc #N | type short-desc #N | ...`
- **6–15 units:** `type(area, area) | type(area) x3 | type x2`
- **16+ units:** `sprint: N issues · feat/X fix/Y chore/Z · #A–#B`

Keep under ~100 characters.

### Step 4 — Present and confirm

> **Suggested session name:**
> `feat user-auth magic-link flow #91`

> To apply: say "use that name" or "lgtm".

### Step 5 — After confirmation: write to session file, move to done/

Use the shared atomic writer, passing the confirmed name as one opaque argument.

```bash
# Acknowledge only the pending merge SHA while this exact active record remains
# resolvable. A changed SHA fails closed and leaves the reminder visible.
PENDING_MERGE_SHA=$(sed -n 's/^merge_sha=//p' "$RIG_DIR/memory/.post-merge-pending" 2>/dev/null | head -1)
[[ -n "$PENDING_MERGE_SHA" ]] && \
  "$REPO/bin/rig" session obligation clear --kind post-merge --merge-sha "$PENDING_MERGE_SHA" --json
"$REPO/bin/rig" session-name set --final --complete "$CONFIRMED_NAME"
```

**Do NOT write Session name to CONTEXT_SNAPSHOT.md.** Session names live in session files.

If no meaningful work shipped (pure exploration, no merges), skip this step silently.

---

## Flag cleanup

After step 8 ("What's next?"), run all cleanups:

```bash
# Release the concurrent session lock
rm -f "$RIG_DIR/memory/.snapshot-write-in-progress" 2>/dev/null || true

# The exact merge acknowledgement was recorded in Step 5 before the session
# record moved to done/.
```

The `.post-merge-pending` flag is written by `.husky/post-merge` after every merge
with the triggering merge SHA and timestamp, then detected by freshness hooks.
Saying “skip for current task” leaves the reminder and its merge metadata intact;
the exact-session acknowledgement confirms `/post-merge` ran successfully for
that merge SHA. A mismatch leaves the reminder intact. The
`.snapshot-write-in-progress` lock is cleared to unblock any
concurrent `/wrap` or `/post-merge` waiting to run.

---

## Notes

- `CONTEXT_SNAPSHOT.md` is the most important output — it's what orients the next
  session. A stale or missing snapshot means the next session loads PROGRESS.md in
  full instead, which is slower and less precise.
- If `.rig/tasks/active/` is empty when `/post-merge` runs (task was already moved),
  Claude will note it and skip the move step.
- **Housekeeping commit convention** is controlled by `## Git workflow convention` in
  the project `CLAUDE.md`. Default is `direct-push` (no branch, no PR). Change to
  `pr-required` for repos that require PRs for all changes to main.
