# Command: /post-merge

Trigger this command immediately after a PR is merged to main.

`/post-merge` runs the housekeeping that keeps the system clean between sessions:
pulls latest main, updates memory, moves the task file, and surfaces what's next.
It takes about 5 minutes and prevents the drift that accumulates when post-merge
hygiene is skipped.

**Always run this after a merge.** A `.husky/post-merge` git hook will remind you
when you pull a merge commit.

---

## What this does

Follows `.rig/processes/POST_MERGE_WORKFLOW.md`:

1. Pulls latest `main` and confirms the expected commit is at HEAD
2. Adds an entry at the top of `.rig/memory/PROGRESS.md` for the merged PR
3. Moves the task file from `.rig/tasks/active/` → `.rig/tasks/done/`; marks `**Status**` as `done`
4. Overwrites `.rig/memory/CONTEXT_SNAPSHOT.md` with the current project state
5. Checks `.rig/memory/ERRORS.md` — prompts you to log anything unexpected
6. Makes a housekeeping commit if memory updates weren't included in the PR
7. **Suggests a session name** based on the merged PR (see below)
8. Surfaces the next priority and asks: **"What's next?"**

---

## Usage

```
/post-merge
```

Run this immediately after you merge (or are told a PR merged). Claude will ask
which PR merged if it's not clear from context.

---

## Session naming step

After the housekeeping commit (step 6), derive a `/rename` suggestion from the
merged PR. Do **not** run it automatically — present it for the user to run or tweak.

### Format

```
type short-desc #N | type short-desc #N | ...
```

- One segment per PR merged (you always know the PR number at this point)
- If this session also included earlier commits or a prior PR, include those segments too
- `type` matches the git commit type (`fix`, `feat`, `chore`, `refactor`, `devops`, `docs`, `test`)
- `short-desc` is 3–6 words — enough to identify the work at a glance
- Keep the full string under ~100 characters

### Output

> **Suggested session name:**
> `/rename feat user-auth magic-link flow #91`

If no meaningful work shipped (pure exploration, no merges), skip this step silently.

---

## Notes

- `CONTEXT_SNAPSHOT.md` is the most important output — it's what orients the next
  session. A stale or missing snapshot means the next session loads PROGRESS.md in
  full instead, which is slower and less precise.
- If `.rig/tasks/active/` is empty when `/post-merge` runs (task was already moved),
  Claude will note it and skip the move step.
- The housekeeping commit is on a short-lived branch — open a small PR or push
  directly per your project's convention.
