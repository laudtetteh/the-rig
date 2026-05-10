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

**Read `issue-tracking:` from `CLAUDE.md` before proceeding.**

| `issue-tracking` value | Required before Step 1 |
|---|---|
| `github` (or absent) | GitHub issue `#N`; read `issue-creator:` to decide who creates it |
| `linear` | Linear ticket ID (e.g. `ENG-123`); user always provides |
| `trello` | Trello card ID; user always provides |
| `gus` | GUS work item ID (e.g. `W-1234567`); user always provides |
| `none` | No ticket required — skip this step |

**If `issue-tracking: github`** (or absent):

Also read `issue-creator:` (default: `user`).
- `issue-creator: user`: block until the user provides `#N`. Do not proceed without it.
- `issue-creator: agent`: create the issue now with `gh issue create`, note the `#N`, proceed.
  If the user already provided a number, use that instead — skip creation.

**Ticket validation — required before Step 1.** Open the task file and find the
`**Issue**: [ref]` field. Apply these rules:
- If the field is empty, `N/A`, `TBD`, or absent: **stop. Do not proceed to Step 1.**
  Either run `/task` to create a proper intake, or add the ticket reference manually.
- If the field contains a valid reference for the configured tracker: proceed.

This check applies whether the task was opened via `/task`, picked from the backlog,
or resumed from `.rig/tasks/active/`.

The ticket reference belongs in:
- The task file's `**Issue**: [ref]` field
- Every commit message on this branch (format per tracker):
  - GitHub: `feat(scope): description [#N]`
  - Linear: `feat(scope): description [ENG-123]`
  - Trello: `feat(scope): description [trello:CARD-ID]`
  - GUS: `feat(scope): description [W-1234567]`

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

Before creating a new branch for this task, verify main hasn't advanced since your last pull:

```bash
BASE=$(grep "^base-branch:" CLAUDE.md 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
BASE="${BASE:-main}"
git fetch origin "$BASE" --quiet 2>/dev/null || true
AHEAD=$(git rev-list HEAD..origin/"$BASE" --count 2>/dev/null || echo 0)
```

**If AHEAD > 0:** main has new commits. Pull before branching — otherwise the new branch
diverges from current main and may re-introduce already-merged code.

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
   - Do NOT rewrite `## Approach` (it's the historical plan); add deviations to `## Done notes`

2. **Update the task file:**
   - Change `**Status**` to `done`
   - Fill in `## Done notes` with substance — not a restatement of the plan:
     - **What was built:** actual implementation, specific files and behaviours
     - **Deviations from plan:** where scope or approach changed and why
     - **Actual files touched:** anything not in `## Files likely affected`
     - **Follow-ups opened:** any new task files or issues created
   - Update `**Updated**` date

3. Move the task file from `.rig/tasks/active/` → `.rig/tasks/done/`

4. Update `.rig/memory/PROGRESS.md` with a one-line summary of what was built

5. Log any new pitfalls or surprises in `.rig/memory/ERRORS.md`

6. Log any Rig workflow gaps or friction points in `.rig/memory/RIG_GAPS.md`
   *(Was there anything about The Rig itself that slowed you down, was missing, or felt wrong?
   Log it here — see `/rig-gaps` for the submission workflow.)*

7. Commit with a conventional commit message referencing the task name and issue number

8. Follow `SHIP_WORKFLOW.md` to open the PR

> **Staging note:** Stage the task file **only after** it has been moved to `.rig/tasks/done/`.
> Never commit a task file from `.rig/tasks/active/` — it creates a confusing history where
> the "in-progress" and "completed" states both appear in the same PR.
