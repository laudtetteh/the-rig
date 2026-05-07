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

---

## Step 2 — Update PROGRESS.md

Add an entry at the **top** of `.rig/memory/PROGRESS.md` (below the header):

```markdown
## [YYYY-MM-DD] — [PR title or one-line summary]

- [bullet: what was built]
- [bullet: what was verified]
- PR #N merged — branch: type/description
```

---

## Step 3 — Move the task file

1. Move the completed task file: `.rig/tasks/active/TASK_[name].md` → `.rig/tasks/done/TASK_[name].md`
2. Update its `**Status**` field to `done`
3. Verify `.rig/tasks/active/` is clean — only `.gitkeep` should re[BASE_BRANCH] if all tasks are done

---

## Step 4 — Overwrite CONTEXT_SNAPSHOT.md

Rewrite `.rig/memory/CONTEXT_SNAPSHOT.md` with the current state of the project.
**Never delete this file — always overwrite it.**

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

## Step 5 — Check ERRORS.md and RIG_GAPS.md

If anything unexpected happened during the task or the merge process, log it in
`.rig/memory/ERRORS.md` now. Do not defer — the detail is freshest immediately
after the work.

If anything about The Rig's workflow felt wrong, was missing, or slowed you down
during this task, log it in `.rig/memory/RIG_GAPS.md`. Use `/rig-gaps` to compile
and submit those entries to The Rig dev session.

---

## Step 6 — Housekeeping commit

If `.rig/memory/PROGRESS.md` updates and the task file move were not already committed
as part of the PR, commit them now.

**First, read the `## Git workflow convention` field from the project `CLAUDE.md`.**
It will be one of:

- `housekeeping: direct-push` — commit and push directly to `[BASE_BRANCH]` (default)
- `housekeeping: pr-required` — create a short-lived branch and open a PR

### If `direct-push` (default)

```bash
git add .rig/memory/PROGRESS.md .rig/tasks/done/TASK_[name].md
git commit -m "chore: post-merge housekeeping for PR #N"
git push origin [BASE_BRANCH]
```

No branch, no PR. Done.

### If `pr-required`

```bash
git checkout -b chore/post-merge-[N]
git add .rig/memory/PROGRESS.md .rig/tasks/done/TASK_[name].md
git commit -m "chore: post-merge housekeeping for PR #N"
git push -u origin chore/post-merge-[N]
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

1. **Look for `<!-- session-end -->` markers in `.rig/memory/PROGRESS.md`.**
   Entries between the most recent marker and the top of the file belong to this session.
2. If no markers exist, read the `**Last updated:**` line from `.rig/memory/CONTEXT_SNAPSHOT.md`
   and collect entries added since that date.

### Check for an existing session name

Read the `**Session name:**` field from `.rig/memory/CONTEXT_SNAPSHOT.md`.

- **If blank / absent:** suggest a fresh name covering this session's work.
- **If already set:** suggest **appending** the merged PR to the existing name rather
  than replacing it:

  > **Session already named:** `feat dashboard ui #49`
  > **Merged this run:** PR #51 (fix null user on profile fetch)
  > **Updated suggestion:** `feat dashboard ui #49 | fix null user profile fetch #51`

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

After the user confirms, **update the `**Session name:**` field in
`.rig/memory/CONTEXT_SNAPSHOT.md`** to match.

If no meaningful work shipped (pure housekeeping, no PRs), skip this step silently.

---

## Step 8 — Surface what's next

Read the updated `.rig/memory/CONTEXT_SNAPSHOT.md` and state the next priority.
Ask the user: **"What's next?"**

Do not begin the next task until the user confirms.
