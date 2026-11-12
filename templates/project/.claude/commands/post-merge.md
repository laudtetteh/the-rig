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

If the session includes a batch of related merged PRs, process them as a
batch ledger without weakening per-PR hygiene: verify each PR number, merge SHA,
closed issue set, and task row separately, then print one batch summary.

---

## What this does

Follows `.rig/processes/POST_MERGE_WORKFLOW.md`:

1. Pulls latest `main` and confirms the expected commit is at HEAD
2. Adds an entry at the top of `.rig/memory/PROGRESS.md` for the merged PR
3. When task lifecycle is installed, moves the task file from `$RIG_DIR/tasks/active/` → `$RIG_DIR/tasks/done/` and marks `**Status**` as `done`
4. Refreshes `.rig/memory/CONTEXT_SNAPSHOT.md` without replacing task handoffs
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

> **RIG_DIR resolution:** After the Git state check, before reading or writing
> any `.rig/` path, use the inventory helper's resolved `rig_dir`. It handles
> in-repo, external, and relative `.rigpath` values without changing spaces.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> TASK_INVENTORY_JSON=$("$REPO/bin/rig" task inventory --json) || {
>   printf '%s\n' "$TASK_INVENTORY_JSON" >&2
>   exit 1
> }
> RIG_DIR=$(printf '%s' "$TASK_INVENTORY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rig_dir"])')
> ```
>
> Substitute `$RIG_DIR` for `.rig/` in every step below.

After the Git state check, use the inventory result from the block above.
If it reports `state: omitted`, record "task lifecycle omitted", skip the task
move and task handoff retirement, and continue shared memory and PR cleanup.
If it reports `state: ambiguous` or `ok: false`, stop and report its `reason`
as a task inventory error.
An installed but missing directory is not an empty task list.
If shared memory files such as `$RIG_DIR/memory/PROGRESS.md` are missing,
report "shared memory component unavailable" and stop before memory writes.

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

Do not acquire the memory workflow lock while waiting for this answer.

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
   If the user names several merged PRs, collect each PR with its merge SHA and
   closed issue list.
2. **"This session" summary** — from conversation context: all PRs merged or opened, tasks completed, issues resolved this session. Conversation context is the primary signal; PROGRESS.md markers are cross-reference only.
3. **Task file** — when installed, which file in `$RIG_DIR/tasks/active/` maps to the merged PR; when omitted, record "task lifecycle omitted"
4. **ERRORS.md additions** — infer from session context whether any unexpected behaviors, footguns, or pitfalls should be added
5. **Feature doc overlaps** — files changed in the merged PR vs. documented feature entry points (see Feature doc freshness step below)
6. **Session name** — derive suggestion from session file and conversation context
7. **Session identity** — run `bin/rig session resolve --json` read-only. If it
   returns `ended_record` or `not_found` and a native session environment variable
   is present, note that exact continuation recovery is pending. After acquiring
   the workflow lock, run `bin/rig session retrofit --agent codex --from-env --source resume --json`
   or `bin/rig session retrofit --agent claude --from-env --source resume --json`
   before other memory writes. UserPromptSubmit may already have attached a
   resumed thread from the hook event ID. If it remains `not_found`, or ended-record
   retrofit cannot create an exact active continuation, continue in degraded mode
   and skip final session-file mutation.
   Stop on ambiguous, duplicate, cross-project, malformed, or unsafe session
   state.

### Report

Print a single structured report before executing POST_MERGE_WORKFLOW:

```
## Post-merge report — [BASE_BRANCH] — [date]

**Scope:** post-merge for [project name] only
**Cross-project work:** [none | other projects mentioned: project-a, project-b — not updated here]

**Merged:** PR #N — type(scope): description
**Batch ledger:** [single PR | PR #N sha abc123 closes #X | PR #M sha def456 closes #Y,#Z]

**This session:**
- PR #N merged: type(scope): description
- [other work items this session]
(omit if this is the only work item)

**ERRORS.md:** [N new entries: short-title-1 | no new entries]
**Feature docs:** [⚠ overlap — run /refresh-feature-doc X | no overlaps]
**Task file:** [TASK_N_slug.md → moving to done/ | no active task found | task lifecycle omitted]

**Session name:** [suggested: "type desc #N | type desc #N" | already set — appending: "..." | exact recovery pending | unresolved — no final session-file write performed | nothing meaningful shipped, skipped]
**Final session name:** [confirmed final: "..." | suggested final: "..." awaiting confirmation | unresolved — reliable name could not be set | nothing meaningful shipped, skipped]
```

If `/post-merge` is skipped, print instead:

```
## Post-merge report — skipped — [date]

**Reason:** [no merged PR | not on merge commit | working tree dirty | other concrete reason]
**Next action:** [merge a PR first | commit/stash changes | run /wrap only | other concrete action]
```

If the collection phase finds no applicable merged PR, print the skipped report
and stop before acquiring the workflow lock. Do the same when the dirty-tree
gate prevents execution.

### Execution

After printing the report, **execute POST_MERGE_WORKFLOW steps 1–8 automatically**:

- Pull latest [BASE_BRANCH] and confirm each expected merge SHA
- Update PROGRESS.md, one entry per PR or an explicit combined batch summary
- Move an installed task file to `$RIG_DIR/tasks/done/` only when its batch ledger rows are terminal; skip this step when task lifecycle was omitted
- Refresh the shared CONTEXT_SNAPSHOT.md header with `bin/rig memory write-snapshot --shared-only`
- Add inferred ERRORS.md entries (if any)
- Make a housekeeping commit only for stageable in-repo memory or task changes
- Apply session name — only if user says "use that" or equivalent

All steps execute automatically. The session name is the only action requiring explicit user input.

In degraded mode for `not_found` or `ended_record`, continue project-level
post-merge housekeeping and write `CONTEXT_SNAPSHOT.md`, but do not fabricate a
session UUID, do not move any session record to `sessions/done/`, and do not
clear exact-session obligations that require a resolvable active session.

Acquire the workflow lock after the report and skip gates, before the first
POST_MERGE_WORKFLOW step. If a later verification step stops execution, release
the exact token before returning.

---

## Concurrent session guard — acquire before housekeeping

Acquire the owner-recorded memory workflow lock before changing memory. Preserve
its token through the housekeeping commit. The snapshot writer separately locks its
short atomic update:

```bash
LOCK_OWNER=$("$REPO/bin/rig" session current --json 2>/dev/null | \
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")' 2>/dev/null || true)
LOCK_ARGS=(acquire --json)
[[ -n "$LOCK_OWNER" ]] && LOCK_ARGS+=(--owner-anchor "$LOCK_OWNER")
[[ "${RIG_SESSION_PID:-}" =~ ^[0-9]+$ ]] && LOCK_ARGS+=(--provider-pid "$RIG_SESSION_PID")
SNAP_LOCK_JSON=$("$REPO/bin/rig" memory workflow-lock "${LOCK_ARGS[@]}") || {
  echo "Unable to write Rig memory lock: $SNAP_LOCK_JSON" >&2
  echo "No further memory writes were attempted." >&2
  exit 1
}
SNAP_LOCK_TOKEN=$(printf '%s' "$SNAP_LOCK_JSON" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') || exit 1
printf 'Rig workflow lock acquired: %s\n' "$SNAP_LOCK_JSON"
```

The lock reports the owner anchor, PID, and age when another workflow is active.
A dead provider PID is archived and recovered on the next acquire. For a
tool-sourced lock older than 30 minutes, verify that its workflow has stopped,
then retry acquire with `--recover-stale`. Age alone does not take over the lock;
the stale record is archived on explicit recovery.
Keep the exact `token` from the acquire output in your
working context and reassign `SNAP_LOCK_TOKEN` from that value in later tool-call
shells; variables do not persist between tool calls. Never read a replacement
token from the current lock file. Never remove another session's lock manually.
If acquire fails with `Operation not permitted`, request scoped write approval for $RIG_DIR
before retrying. This commonly happens when Codex is running in
a project whose `.rigpath` points outside the workspace writable roots.
If any step fails after acquire, release the exact token before stopping. Keep
the snapshot draft and pending merge obligation for a retry.
If exact session retrofit was pending during report collection, perform it now,
before other memory writes. Update the resolved session identity or continue in
degraded mode if exact recovery is unavailable.

---

For the snapshot step, write the current shared project state to
`$RIG_DIR/memory/.snapshot-draft-${SNAP_LOCK_TOKEN}.md`. Keep every
`## Resuming from` section out of this draft. The writer retains existing task
handoffs, including those from other active sessions. If Step 3 moved a task to
`$RIG_DIR/tasks/done/`, inspect the existing snapshot for its exact
`## Resuming from: <task-slug>` heading. Add a matched `--retire-task <task-slug>
--done-task-file "$RIG_DIR/tasks/done/<filename>"` pair for that task only.
The writer verifies the done file, refuses a matching active file, and saves a
backup before removing the handoff. Leave every other section intact:

```bash
SNAP_DRAFT="$RIG_DIR/memory/.snapshot-draft-${SNAP_LOCK_TOKEN}.md"
SNAP_ARGS=(--file "$SNAP_DRAFT" --shared-only --json)
# Append matched --retire-task TASK --done-task-file FILE pairs for tasks
# verified as done in Step 3; leave SNAP_ARGS unchanged otherwise.
"$REPO/bin/rig" memory write-snapshot "${SNAP_ARGS[@]}" || {
  "$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json
  echo "Snapshot update failed; draft preserved at $SNAP_DRAFT" >&2
  exit 1
}
rm -f "$SNAP_DRAFT"
```

If the writer reports a malformed section, owner conflict or legacy lock,
preserve the draft and stop before clearing the merge obligation. Do not write
`CONTEXT_SNAPSHOT.md` directly.

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

Release the workflow lock after memory housekeeping and the housekeeping commit,
before presenting a session name for confirmation. Another session can then
start its own memory housekeeping while the user decides.

```bash
"$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json || exit 1
```

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
NAMING_EVIDENCE=$(SESSION_F="$SESSION_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); e=d.get("naming_evidence",{}).get("progress_titles",[]) if isinstance(d.get("naming_evidence",{}),dict) else []; print("\n".join(str(x) for x in e if str(x).strip()))' 2>/dev/null || true)
```

### Step 2 — Collect this session's work

**Conversation context first** — enumerate PRs, tasks, and work you know about.
The merged PR number is always known at this point. A tentative name and
`naming_evidence.progress_titles` in the exact active session file are
same-session pre-compaction anchors. File signals are cross-reference:

```bash
grep "^## .*<!-- sid:${SESSION_UUID} -->" "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null || true
```

**Every `## ` entry header written to PROGRESS.md must include `<!-- sid:UUID -->`
at the end of the line.** Read UUID from the resolver output above.

If tentative_name is set, use it as the base (refine based on actual outcome).
For compacted sessions, read only
`$RIG_DIR/memory/.compact-checkpoint-${SESSION_UUID}.md`, and use its
`Session naming evidence` only when that file's `Session anchor` equals
`SESSION_UUID`. Never use `CONTEXT_SNAPSHOT.md`, checkpoints for another anchor,
legacy markers, unrelated session files, other-session UUID entries, or general
project history as naming evidence. An unresolved raw launch fails closed before any name is proposed or written.

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
CURRENT_JSON=$("$REPO/bin/rig" session current --json) || {
  exit 1
}
CURRENT_UUID=$(printf '%s' "$CURRENT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")')
[[ -n "$SESSION_UUID" && "$CURRENT_UUID" == "$SESSION_UUID" ]] || {
  echo "Session identity changed; stop before clearing or completing it." >&2
  exit 1
}
PENDING_MERGE_SHA=$(sed -n 's/^merge_sha=//p' "$RIG_DIR/memory/.post-merge-pending" 2>/dev/null | head -1)
[[ -n "$PENDING_MERGE_SHA" ]] && \
  "$REPO/bin/rig" session obligation clear --kind post-merge --merge-sha "$PENDING_MERGE_SHA" --json
"$REPO/bin/rig" session-name set --final --complete "$CONFIRMED_NAME"
```

If this is a continuation after `/wrap`, name only the post-merge work in this
active record. Preserve the completed parent record and its final name.

**Do NOT write Session name to CONTEXT_SNAPSHOT.md.** Session names live in session files.

If no meaningful work shipped (pure exploration, no merges), skip this step silently.

---

## Flag cleanup

The exact merge acknowledgement is recorded in Step 5 before the session
record moves to done/. The workflow lock was released before session naming.

The `.post-merge-pending` flag is written by `.husky/post-merge` after every merge
with the triggering merge SHA and timestamp, then detected by freshness hooks.
Saying “skip for current task” leaves the reminder and its merge metadata intact;
the exact-session acknowledgement confirms `/post-merge` ran successfully for
that merge SHA. A mismatch leaves the reminder intact. The
owner-recorded workflow lock is released to unblock any
concurrent `/wrap` or `/post-merge` waiting to run.

---

## Notes

- `CONTEXT_SNAPSHOT.md` is the most important output — it's what orients the next
  session. A stale or missing snapshot means the next session loads PROGRESS.md in
  full instead, which is slower and less precise.
- If an installed `$RIG_DIR/tasks/active/` directory has no task files when
  `/post-merge` runs, note it and skip the move. An omitted task component is
  reported separately; a missing installed directory is an inventory error.
- **Housekeeping commit convention** is controlled by `## Git workflow convention` in
  the project `CLAUDE.md`. Default is `direct-push` (no branch, no PR). Change to
  `pr-required` for repos that require PRs for all changes to main.
- At the very end of the response, after every other report or chained command,
  repeat the session block: anchor, final or suggested name, and whether the
  record was completed or remains unresolved.
