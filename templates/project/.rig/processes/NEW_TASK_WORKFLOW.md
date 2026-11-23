# NEW_TASK_WORKFLOW

> Follow this process every time you start a new task. No exceptions.
> The discipline of planning before coding is the whole point.

---

## When to follow this workflow

- When the user says "start a task", "let's work on X", or "pick up the next task"
- When pulling a task from `.rig/tasks/backlog/`
- When resuming an interrupted task from `.rig/tasks/active/`

---

## Step 0 — Issue/ticket first

**Run `python3 bin/rig-tracker-config.py show CLAUDE.md` before proceeding.**
Use its normalized `tracker`, `pattern`, and `example` values. Stop if the
configuration is invalid.

| `issue-tracking` value | Required before Step 1 |
|---|---|
| `github` (or absent) | GitHub issue `#N`; read `issue-creator:` to decide who creates it |
| Any other name | Existing tracker reference; user always provides. `linear`, `trello`, and `gus` have preset patterns/examples |
| `none` | No ticket required — skip this step |

**If `issue-tracking: github`** (or absent):

Also read `issue-creator:` (default: `user`).
- `issue-creator: user`: block until the user provides `#N`. Do not proceed without it.
- `issue-creator: agent`: draft the issue title, complete body, labels, and target
  repository. Show that exact proposed action and ask for the user's explicit
  approval immediately before `gh issue create`; the setting, task launch, or
  plan approval is not permission to file it. If the draft changes, show the
  revised action and ask again. If approval is declined, wait for an existing
  `#N` or later approval. After approval, create the issue, note its `#N`, and
  proceed. If the user already provided a number, skip creation.

**Ticket validation — required before Step 1.** Open the task file and find the
tracker-specific field; for GitHub projects this is `**GitHub issue**: [ref]`.
Apply these rules:
- If the field is empty, `N/A`, `TBD`, or absent: **stop. Do not proceed to Step 1.**
  Either run `/task` to create a proper intake, or add the ticket reference manually.
- Run `python3 bin/rig-tracker-config.py validate-ref CLAUDE.md "REF"`
  with the field's reference replacing `REF`. Proceed only on exit 0.
  For a multi-issue field, validate every reference separately.

This check applies whether the task was opened via `/task`, picked from the backlog,
or resumed from `.rig/tasks/active/`.

The ticket reference belongs in:
- The task file's tracker field, for GitHub projects `**GitHub issue**: [ref]`
- Every commit message on this branch (format per tracker):
  - GitHub: `feat(scope): description [#N]`
  - Any other tracker: `feat(scope): description [REF]`, where `REF`
    follows `issue-ref-pattern:` when configured

### 0a — Multi-issue task intake

A task may intentionally cover multiple tracker issues only when the user names
that batch explicitly. In that case, record every issue in the same tracker field
used by the shipped task template, for GitHub projects `**GitHub issue**: #N, #M`,
and add a `## Batch ledger` section with one row per issue or issue/PR
relationship. Do not collapse unrelated issues into one task merely because they
will touch nearby files.

Use `.rig/processes/SPRINT_WORKFLOW.md` for the batch ledger format and keep the
ledger current as commits and PRs land.

---

## Step 1 — Confirm your working directory

Before touching any file, identify the main repo root and confirm all edits will target it.

> **Why this matters:** Claude Code runs sessions inside hidden git worktrees at paths like
> `.claude/worktrees/<session-name>/`. File edits written there are **invisible** to the
> user's git client (Sourcetree, GitKraken, Tower, etc.). This has caused entire sessions
> worth of work to be silently discarded. Always work in the main repo.

```bash
# Identify the main repo root
git rev-parse --show-toplevel
```

- All `Write` and `Edit` tool calls must use **absolute paths** under the main repo root
- All `git` commands must target the main repo: `git -C <repo-root> <command>`
- Never create branches, commits, or files inside the `.claude/worktrees/` path

### 1a — Stale-main pre-check (before creating any branch)

Before creating a new branch for this task, verify the configured base branch
(`base-branch:` in `CLAUDE.md`, default `main`) hasn't advanced since your last pull:

```bash
BASE=$(grep "^base-branch:" CLAUDE.md 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
BASE="${BASE:-main}"
git fetch origin "$BASE" --quiet 2>/dev/null || true
AHEAD=$(git rev-list HEAD..origin/"$BASE" --count 2>/dev/null || echo 0)
```

**If AHEAD > 0:** `$BASE` has new commits. Pull before branching — otherwise the new branch
diverges from the current base and may re-introduce already-merged code.

For the full protocol (what to do at each autonomy level), see `SHIP_WORKFLOW.md` Step 3b.

---

### 1b — Create the branch

**Do this before writing a single file.** No `Write`, `Edit`, or `Bash` tool calls
that modify project files until this step is complete.

Derive a branch name from the task type and slug:

```
feat/short-description    fix/short-description    chore/short-description
```

Create and switch to it:

```bash
git checkout -b <branch-name>
```

**Autonomy notes:**
- **Low / Medium:** confirm the branch name with the user before running `git checkout -b`.
- **High:** state the name you're creating ("Creating `feat/my-feature` off `main`"), then
  branch immediately — no wait.

**If already on a non-base branch:** verify it belongs to this task. If not, ask the user
before proceeding — you may be on a leftover branch from a prior task.

> This step has no exception. Even a one-line fix needs a branch. Hard Rule #3.

---

## Step 2 — Orient

Read these files before anything else, in this order:

1. `.rig/memory/CONTEXT_SNAPSHOT.md` — current state, decisions in flight, known footguns
2. `.rig/memory/PROGRESS.md` — what has shipped and when
3. `.rig/memory/ERRORS.md` — pitfalls to avoid
4. The task file in `.rig/tasks/active/` or `.rig/tasks/backlog/`

**If no task file exists:** stop and ask the user to create one before proceeding.
Do not invent a task file unilaterally.

---

## Step 3 — Confirm understanding

Before writing a plan, state back to the user in 2–3 sentences:

- What the task is asking for
- Which files you expect to touch
- Any risks, ambiguities, or open questions you see

**Wait for the user's confirmation** before proceeding to Step 3.

If you have a clarifying question, ask exactly one. Do not stack questions.

---

## Step 4 — Plan

Write a numbered implementation plan into the task file under `## Approach`.

Requirements for a valid plan:
- File-level granularity — not just "update the service", but "edit `services/llm/base.py` to add X"
- Explicit about what is NOT changing (reduces scope creep)
- Any dependency ordering called out (step A must complete before step B)

**Wait for the user's approval on the plan** before writing any code.

---

## Step 5 — Implement

Work through the plan one step at a time.

- After each meaningful step, briefly confirm what was done before moving to the next
- If you hit something unexpected, **surface it** — do not silently work around it
- Do not refactor unrelated code while implementing
- Do not fix unrelated bugs — log them in `.rig/memory/ERRORS.md` and move on

---

## Step 6 — Verify

Before declaring done:

- Run available tests; fix failures before proceeding
- Walk through each acceptance criterion in the task file and confirm it is met
- Do a quick self-review: does the output do what was asked and **nothing more**?

---

## Step 7 — Wrap up

In this order:

1. **Audit plan vs. reality** before touching anything:
   - Compare `## Approach` with what was actually implemented
   - If scope changed, approach deviated, or unexpected files were touched — note it
   - Do NOT rewrite `## Approach` (it's the historical plan); record deviations
     in the active task's pre-merge checkpoint for `/post-merge` to carry into
     final `## Done notes` after the PR merges

2. **Update the active task file** with a pre-merge checkpoint. Leave its status
   `active` and its location under `tasks/active/` until the PR merges. Record:
   - What was built and validated, with exact commit and PR references
   - Any deviations from the plan and why
   - Actual files touched and follow-ups opened

   After the PR merges, `/post-merge` owns the final `**Status**: done`, the
   active-to-done move, and substantive `## Done notes`, including:
     - **What was built:** actual implementation, specific files and behaviours
     - **Deviations from plan:** where scope or approach changed and why
     - **Actual files touched:** anything not in `## Files likely affected`
     - **Follow-ups opened:** any new task files or issues created
     - **Updated date:** set `**Updated**` to the merge closeout date

3. Keep the task in `.rig/tasks/active/` while `/ship` opens the PR. Do not
   move it to done before merge; `/post-merge` performs that move once.

4. Record an implementation checkpoint in `.rig/memory/PROGRESS.md`; the
   completion entry is recorded by `/post-merge` after merge.

5. Log any new pitfalls or surprises in `.rig/memory/ERRORS.md`

6. Log any Rig workflow gaps or friction points in `.rig/memory/RIG_GAPS.md`
   *(Was there anything about The Rig itself that slowed you down, was missing, or felt wrong?
   Log it here — see `/rig-gaps` for the submission workflow.)*

7. **If the task has a `## Batches` section:** verify all batch rows have a commit
   hash filled in before moving to done. Leave any pending rows blank — do not
   fabricate hashes.

8. Commit with a conventional commit message referencing the task name and issue number

9. Follow `SHIP_WORKFLOW.md` to open the PR

> **Staging note:** Keep the active task file uncommitted while the PR is open.
> `/post-merge` stages the final done path only after the merge, when it is
> stageable in this repository.
