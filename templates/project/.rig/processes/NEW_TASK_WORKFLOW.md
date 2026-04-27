# NEW_TASK_WORKFLOW

> Follow this process every time you start a new task. No exceptions.
> The discipline of planning before coding is the whole point.

---

## When to follow this workflow

- When the user says "start a task", "let's work on X", or "pick up the next task"
- When pulling a task from `.rig/tasks/backlog/`
- When resuming an interrupted task from `.rig/tasks/active/`

---

## Step 0 — GitHub issue first

Before any code is written, a GitHub issue must exist and be linked in the task file.
The `/task` wizard enforces this: it will not proceed to Part 2 without an issue number.
If you are running this workflow without going through `/task`, stop and create the issue now.

The issue number belongs in:
- The task file's `**GitHub issue**: #[N]` field
- Every commit message on this branch: `feat(scope): description [#N]`

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

---

## Step 1 — Orient

Read these files before anything else, in this order:

1. `.rig/memory/CONTEXT_SNAPSHOT.md` — current state, decisions in flight, known footguns
2. `.rig/memory/PROGRESS.md` — what has shipped and when
3. `.rig/memory/ERRORS.md` — pitfalls to avoid
4. The task file in `.rig/tasks/active/` or `.rig/tasks/backlog/`

**If no task file exists:** stop and ask the user to create one before proceeding.
Do not invent a task file unilaterally.

---

## Step 2 — Confirm understanding

Before writing a plan, state back to the user in 2–3 sentences:

- What the task is asking for
- Which files you expect to touch
- Any risks, ambiguities, or open questions you see

**Wait for the user's confirmation** before proceeding to Step 3.

If you have a clarifying question, ask exactly one. Do not stack questions.

---

## Step 3 — Plan

Write a numbered implementation plan into the task file under `## Approach`.

Requirements for a valid plan:
- File-level granularity — not just "update the service", but "edit `services/llm/base.py` to add X"
- Explicit about what is NOT changing (reduces scope creep)
- Any dependency ordering called out (step A must complete before step B)

**Wait for the user's approval on the plan** before writing any code.

---

## Step 4 — Implement

Work through the plan one step at a time.

- After each meaningful step, briefly confirm what was done before moving to the next
- If you hit something unexpected, **surface it** — do not silently work around it
- Do not refactor unrelated code while implementing
- Do not fix unrelated bugs — log them in `.rig/memory/ERRORS.md` and move on

---

## Step 5 — Verify

Before declaring done:

- Run available tests; fix failures before proceeding
- Walk through each acceptance criterion in the task file and confirm it is met
- Do a quick self-review: does the output do what was asked and **nothing more**?

---

## Step 6 — Wrap up

In this order:

1. Update the task file: change `**Status**` to `done`, fill in `## Done notes`
2. Move the task file from `.rig/tasks/active/` → `.rig/tasks/done/`
3. Update `.rig/memory/PROGRESS.md` with a one-line summary of what was built
4. Log any new pitfalls or surprises in `.rig/memory/ERRORS.md`
5. Commit with a conventional commit message referencing the task name and issue number
6. Follow `SHIP_WORKFLOW.md` to open the PR

> **Staging note:** Stage the task file **only after** it has been moved to `.rig/tasks/done/`.
> Never commit a task file from `.rig/tasks/active/` — it creates a confusing history where
> the "in-progress" and "completed" states both appear in the same PR.
