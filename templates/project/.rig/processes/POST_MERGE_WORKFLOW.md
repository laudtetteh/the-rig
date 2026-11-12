# POST_MERGE_WORKFLOW

> Run this immediately after a PR is merged to [BASE_BRANCH].
> Takes about 5 minutes. Keeps the system clean for the next session.

---

## When to follow this workflow

- After the user says "merged" or confirms a PR has landed
- After any PR merges to [BASE_BRANCH], regardless of size

---

## Step 1 — Verify state and pull latest [BASE_BRANCH]

First, snapshot current state:

```bash
git branch --show-current
git status --short
```

If the working tree is not clean, surface the uncommitted changes and resolve them
before continuing (stash, commit, or discard — ask the user).

Then pull:

```bash
git checkout [BASE_BRANCH] && git pull origin [BASE_BRANCH]
```

Confirm the expected merge commit is at HEAD:

```bash
git log --oneline -3
```

State the HEAD commit. If it doesn't match the expected merge, stop and flag it.

Resolve `REPO=$(git rev-parse --show-toplevel)`, run
`"$REPO/bin/rig" task inventory --json`, and take its `rig_dir` field as
`RIG_DIR`. If the state is `omitted`, continue
shared memory and PR cleanup without a task move or handoff retirement. If the
state is `ambiguous` or `ok` is false, stop and report the inventory `reason`
as an error. An installed
missing directory is not an empty task list.

---

## Step 2 — Update PROGRESS.md

Add an entry at the **top** of `$RIG_DIR/memory/PROGRESS.md` (below the header):

```markdown
## [YYYY-MM-DD] — [PR title or one-line summary]

- [bullet: what was built]
- [bullet: what was verified]
- PR #N merged — branch: type/description
```

For a merged PR that closes multiple issues, include every closed issue in the
entry and note any related issues that remain open. For a batch of related
merged PRs, write one entry per PR unless the user explicitly asks for a combined
summary; a combined summary must still include each PR number and merge SHA.

---

## Step 3 — Move the task file

If the task inventory is `omitted`, skip this step and report "task lifecycle
omitted". Otherwise:

1. Move the completed task file: `$RIG_DIR/tasks/active/TASK_[name].md` → `$RIG_DIR/tasks/done/TASK_[name].md`
2. Update its `**Status**` field to `done`
3. Verify `$RIG_DIR/tasks/active/` is clean — only `.gitkeep` should remain if all tasks are done

If a task has a `## Batch ledger`, move it to done only when every row is
terminal. Rows for follow-up PRs or still-open issues keep the task active; update
the row for the merged PR with the merge SHA and leave the remaining rows pending.

---

## Step 4 — Refresh CONTEXT_SNAPSHOT.md

Write a draft containing the current shared project state, without any
`## Resuming from` task sections. Apply it with
`bin/rig memory write-snapshot --file "$DRAFT" --shared-only --json`.
The writer preserves existing task handoffs, including those owned by other
sessions. Reuse the inventory helper's `$RIG_DIR` and keep the draft
under `$RIG_DIR/memory/`. Remove the draft after a successful write. Never
edit or delete `CONTEXT_SNAPSHOT.md` directly.
For a task moved to `tasks/done/` in Step 3, inspect the snapshot for its
exact handoff slug and append `--retire-task SLUG --done-task-file FILE` to
the write command. The writer verifies the done file and saves a backup.

The snapshot must include:

- Where the project stands right now (one paragraph)
- Full list of merged PRs (add the just-merged PR)
- Any open PRs
- What comes next, in priority order
- Key decisions that must carry forward to the next session
- Known footguns and environment quirks
- Tech debt worth tracking

This file is **gitignored** — it lives on disk only, read at session start.

---

## Step 5 — Update ERRORS.md and RIG_GAPS.md

Based on this session's context — tool output, errors hit, unexpected behaviors, non-obvious
pitfalls — **infer** whether anything should be added to these files. Do not ask the user;
derive from what was observed.

**ERRORS.md:** For any inferred entry, check the archive first to avoid duplicates
(see ERRORS.md logging step in `/wrap` for the dedup protocol). Add new entries at the top.

**RIG_GAPS.md:** If anything about The Rig's workflow felt wrong, was missing, or slowed
work down during this task, log it now while the detail is fresh. Use `/rig-gaps` to
compile and submit these entries to The Rig dev session.

Include any additions in the Post-merge report (see report step in `/post-merge`).

---

## Step 6 — Housekeeping commit

If `$RIG_DIR/memory/PROGRESS.md` updates and the task file move were not already
committed as part of the PR, make a housekeeping commit only when those files
are stageable in this repository.

When `$RIG_DIR` is outside the checkout, or `.rig/` is locally gitignored,
these files cannot be staged by Git; skip the housekeeping commit and report
the memory and task updates. For a stageable in-repo install, stage the
progress file and stage the done task file only if Step 3 actually moved one.
Apply the branch policy below only when there are files to commit.

For batch post-merge work, one housekeeping commit may cover several merged PRs
only after every PR has been verified at HEAD or in merge history and every
affected task row has exact merge evidence. The commit message must name the PR
range or list, for example `chore: post-merge housekeeping for PRs #10, #11`.

**First, read the `## Git workflow convention` field from the project `CLAUDE.md`.**
It will be one of:

- `housekeeping: direct-push` — commit and push directly to `[BASE_BRANCH]` (default)
- `housekeeping: pr-required` — create a short-lived branch and open a PR

The user's request to run post-merge authorizes its housekeeping commit. Create
one-use approval in the current worktree's Rig directory only after staging
succeeds, immediately before a commit. Skip both commit examples below when
the memory and task files are external or locally ignored. If Step 3 moved a
task in a tracked in-repo install, stage the new done path. Stage the removed
active path only when Git tracked it before the move; an untracked active path
makes `git add -A` on that exact old path fail.

For a stageable in-repo install where Step 3 moved a task, replace
`TASK_[name].md` with that exact filename and run this before either commit
example. Skip this block only when no task was moved:

```bash
ROOT=$(git rev-parse --show-toplevel)
git -C "$ROOT" add .rig/tasks/done/TASK_[name].md
if git -C "$ROOT" ls-files --error-unmatch -- .rig/tasks/active/TASK_[name].md >/dev/null 2>&1; then
  git -C "$ROOT" add -u -- .rig/tasks/active/TASK_[name].md
fi
```

### If `direct-push` (default)

```bash
ROOT=$(git rev-parse --show-toplevel)
git -C "$ROOT" add .rig/memory/PROGRESS.md
touch "$ROOT/.rig/memory/.rig-commit-ok"
RIG_COMMIT_POLICY=guarded git -C "$ROOT" commit -m "chore: post-merge housekeeping for PR #N"
git -C "$ROOT" push origin [BASE_BRANCH]
```

No branch, no PR. Done.

### If `pr-required`

```bash
ROOT=$(git rev-parse --show-toplevel)
git -C "$ROOT" checkout -b chore/post-merge-[N]
git -C "$ROOT" add .rig/memory/PROGRESS.md
touch "$ROOT/.rig/memory/.rig-commit-ok"
RIG_COMMIT_POLICY=guarded git -C "$ROOT" commit -m "chore: post-merge housekeeping for PR #N"
git -C "$ROOT" push -u origin chore/post-merge-[N]
gh pr create --title "chore: post-merge housekeeping for PR #N" \
  --body "Memory updates and task file move for merged PR #N." \
  --label "type: chore" --base [BASE_BRANCH]
```

### If no changes to commit

If PROGRESS.md and the task file were already part of the PR, skip this step entirely.

---

## Step 7 — Suggest a session name

After the housekeeping commit, derive a session name from this session's work using
the same logic as `/session-name`. Do **not** apply it automatically — present it
for the user to confirm or tweak.

### How to determine what belongs to this session

Read `$RIG_DIR/rules/session-naming.md` completely. Current conversation context is
authoritative. A tentative name from the resolver-selected current session file and
PROGRESS entries tagged with that same session UUID may cross-check it. Never use
`CONTEXT_SNAPSHOT.md`, legacy marker ranges, unrelated session files, other UUIDs,
or general project history as naming evidence. Write-capable workflows fail closed
when the current session cannot be resolved unambiguously.

### Format

```
type short-desc #N | type short-desc #N | ...
```

- `type` matches the git commit type (`fix`, `feat`, `chore`, `refactor`, `devops`, `docs`, `test`)
- `short-desc` — 3–6 words; enough to identify the work at a glance
- Keep the full string under ~100 characters

### Output

> **Suggested session name:**
> `feat user-auth magic-link flow #91`

Then invite the user to apply it:

> To apply: run `/session-name` or say "use that name".

After the user confirms, use `bin/rig session-name set --final --complete` with the
confirmed name as one opaque argument. Session names belong in session files; never
write them to `CONTEXT_SNAPSHOT.md`.

If no meaningful work shipped (pure housekeeping, no PRs), skip this step silently.

---

## Step 8 — Surface what's next

Read the updated `$RIG_DIR/memory/CONTEXT_SNAPSHOT.md` and state the next priority.
Ask the user: **"What's next?"**

Do not begin the next task until the user confirms.
