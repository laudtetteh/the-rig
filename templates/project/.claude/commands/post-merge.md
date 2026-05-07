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
5. Checks `.rig/memory/ERRORS.md` and `.rig/memory/RIG_GAPS.md` — prompts you to log anything unexpected or any workflow friction observed
6. Makes a housekeeping commit if memory updates weren't included in the PR
7. **Suggests a session name** based on the merged PR via `/session-name` logic (see below)
8. Surfaces the next priority and asks: **"What's next?"**

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

## Session naming step

After the housekeeping commit (step 6), derive a session name suggestion using the
same logic as `/session-name`. The merged PR number is always known here, which
makes this the most reliable naming signal in the system. Do **not** apply it
automatically — present it for the user to confirm or tweak.

### How to determine what belongs to this session

Use the same boundary logic as `/wrap`:

1. Look for `<!-- session-end -->` markers in `.rig/memory/PROGRESS.md`. Entries
   above the most recent marker belong to this session.
2. If no markers exist, use the `**Last updated:**` date from CONTEXT_SNAPSHOT as
   the boundary and collect entries added since that date.

### Check for an existing session name

Read the `**Session name:**` field from `.rig/memory/CONTEXT_SNAPSHOT.md`.

- **If blank / absent:** suggest a name based on the merged PR (and any other
  PRs or tasks completed this session).
- **If already set:** suggest **appending** the merged PR to the existing name:

  > **Session already named:** `feat dashboard ui #49`
  > **Merged this run:** PR #51 (fix null user on profile fetch)
  > **Updated suggestion:** `feat dashboard ui #49 | fix null user profile fetch #51`

### Format

```
type short-desc #N | type short-desc #N | ...
```

- `type` matches the git commit type (`fix`, `feat`, `chore`, `refactor`, `devops`, `docs`, `test`)
- `short-desc` is 3–6 words — enough to identify the work at a glance
- Keep the full string under ~100 characters

### Output

> **Suggested session name:**
> `feat user-auth magic-link flow #91`

Then invite the user to apply it:

> To apply: run `/session-name` or say "use that name".

After the user confirms, **update the `**Session name:**` field in
`.rig/memory/CONTEXT_SNAPSHOT.md`** to match. This lets subsequent /wrap or
/post-merge calls detect the existing name and suggest appends correctly.

If no meaningful work shipped (pure exploration, no merges), skip this step silently.

---

## Flag cleanup

After step 8 ("What's next?"), delete the `.post-merge-pending` flag file if it exists:

```bash
rm -f "$(git rev-parse --show-toplevel)/.rig/memory/.post-merge-pending" 2>/dev/null || true
```

(Resolve via `.rigpath` if present.) This flag is written by `.husky/post-merge` after
every merge and is detected at the next session start. Cleaning it up here confirms
that `/post-merge` ran successfully.

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
