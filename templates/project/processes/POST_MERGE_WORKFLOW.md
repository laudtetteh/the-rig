# POST_MERGE_WORKFLOW

> Run this immediately after a PR is merged to main.
> Takes about 5 minutes. Keeps the system clean for the next session.

---

## When to follow this workflow

- After the user says "merged" or confirms a PR has landed
- After any PR merges to main, regardless of size

---

## Step 1 — Pull latest main

```bash
git checkout main && git pull origin main
```

Confirm the expected commit is at HEAD before proceeding.

---

## Step 2 — Update PROGRESS.md

Add an entry at the **top** of `memory/PROGRESS.md` (below the header):

```markdown
## [YYYY-MM-DD] — [PR title or one-line summary]

- [bullet: what was built]
- [bullet: what was verified]
- PR #N merged — branch: type/description
```

---

## Step 3 — Move the task file

1. Move the completed task file: `tasks/active/TASK_[name].md` → `tasks/done/TASK_[name].md`
2. Update its `**Status**` field to `done`
3. Verify `tasks/active/` is clean — only `.gitkeep` should remain if all tasks are done

---

## Step 4 — Overwrite CONTEXT_SNAPSHOT.md

Rewrite `memory/CONTEXT_SNAPSHOT.md` with the current state of the project.
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

## Step 5 — Check ERRORS.md

If anything unexpected happened during the task or the merge process, log it now.
Do not defer — the detail is freshest immediately after the work.

---

## Step 6 — Housekeeping commit

If `PROGRESS.md` updates and the task file move were not already committed
as part of the PR:

```bash
git checkout -b chore/post-merge-[N]
git add memory/PROGRESS.md tasks/done/TASK_[name].md
git commit -m "chore: post-merge housekeeping for PR #N"
git push -u origin chore/post-merge-[N]
# Then open a small PR or push directly per your team's convention
```

---

## Step 7 — Surface what's next

Read the updated `CONTEXT_SNAPSHOT.md` and state the next priority.
Ask the user: **"What's next?"**

Do not begin the next task until the user confirms.
