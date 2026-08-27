# Command: /kickoff

> **Work-mode adapter:** Follow `.rig/processes/WORK_MODES.md` as the canonical
> lifecycle and state contract. This command supplies project-mode intake and
> outputs only; the shared contract governs approvals, transitions, and resume.

> **Run once, at project creation.** After `/kickoff` completes, this command has no further use — you can delete `.claude/commands/kickoff.md` from your project.

Trigger this command to bootstrap a brand new project from scratch.

`/kickoff` is the greenfield entry point. It reads your `PROJECT_BRIEF.md`, confirms
it understands what's being built, resolves open questions, then scaffolds everything
needed to start shipping: a filled-in `CLAUDE.md`, an initial task backlog, and GitHub
issues for the first milestone.

Use `/task` for day-to-day work on an established project. Use `/kickoff` once, at
the start, before there's anything to `/task` on.

> **RIG_DIR resolution (stealth mode):** Before creating any task or memory files,
> resolve where `.rig/` actually lives. If `.rigpath` exists at the project root, read
> it — it contains the absolute path to the external `.rig/` directory. Substitute
> `$RIG_DIR` for `.rig/` in every step below.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> if [[ -f "$REPO/.rigpath" ]]; then
>   RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
> else
>   RIG_DIR="$REPO/.rig"
> fi
> ```

---

## Before running /kickoff

`PROJECT_BRIEF.md` must exist and be filled in. The agent needs a real brief to work
from — it cannot scaffold a project from a blank template.

If `PROJECT_BRIEF.md` doesn't exist yet, run `/kickoff` anyway. The agent will create
it from the template and ask you to fill it in, then stop and wait.

---

## Kickoff flow

### Step 0 — Guard against running in an established repository

Before reading or creating `PROJECT_BRIEF.md`, inspect several independent maturity
signals. Run this probe from anywhere inside the repository (the marker comments are
used by the focused guard tests; keep the commands between them executable):

```bash
# kickoff-maturity-probe-start
REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

commit_count=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || printf '0')
release_tag_count=$(git -C "$REPO" tag -l 2>/dev/null \
  | { /usr/bin/grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
  | wc -l \
  | tr -d '[:space:]')
claude_filled=0
if [[ -s "$REPO/CLAUDE.md" ]] && ! /usr/bin/grep -q '\[' "$REPO/CLAUDE.md"; then
  claude_filled=1
fi
backlog_nonempty=0
if [[ -d "$RIG_DIR/tasks" ]] && find "$RIG_DIR/tasks" -type f -print -quit 2>/dev/null | /usr/bin/grep -q .; then
  backlog_nonempty=1
fi

maturity_signals=0
(( commit_count >= 2 )) && ((maturity_signals += 1))
(( release_tag_count >= 1 )) && ((maturity_signals += 1))
(( claude_filled == 1 )) && ((maturity_signals += 1))
(( backlog_nonempty == 1 )) && ((maturity_signals += 1))
printf 'commits=%s release_tags=%s claude_filled=%s backlog_nonempty=%s signals=%s\n' \
  "$commit_count" "$release_tag_count" "$claude_filled" "$backlog_nonempty" "$maturity_signals"
# kickoff-maturity-probe-end
```

The repository looks established only when **two or more** independent signals are
present. A lone signal is ambiguous (for example, a starter repository may already
have several commits), so do not interrupt the greenfield flow for one signal alone.

If `signals` is 2 or greater, show the evidence from the probe and warn:

> "This repository appears to be established. `/kickoff` can overwrite project
> guidance and create a duplicate backlog; `/task` is the safer next step. Reply
> **continue kickoff** to proceed anyway, or say **run task** and I'll hand off to
> `/task`."

Stop and wait. Continue only after the user gives the exact explicit confirmation
`continue kickoff`. If they choose `run task`, hand off directly to `/task`. Do not
interpret a general acknowledgement such as "okay" or "go ahead" as confirmation.

If fewer than two signals are present, continue without prompting.

### Step 1 — Check for PROJECT_BRIEF.md

Look for `PROJECT_BRIEF.md` in the repo root.

**If missing:** Create a blank `PROJECT_BRIEF.md` in the repo root using this template:

```markdown
# Project Brief

## Project name
[Name]

## One-liner
[What it does in one sentence]

## Problem / solution
[What problem does this solve? What's the solution?]

## Primary users
[Who will use this?]

## MVP features
- [Feature 1]
- [Feature 2]
- [Feature 3]

## Out of scope (v1)
- [What's explicitly NOT in the first version]

## Stack
- **Backend**: [e.g. FastAPI / Python 3.12]
- **Frontend**: [e.g. Next.js / TypeScript]
- **Database**: [e.g. PostgreSQL]
- **Infra**: [e.g. Docker + GitHub Actions]

## Constraints
- [Any deadlines, budget limits, must-use technologies, or hard requirements]

## Success metrics
- [How will you know the MVP succeeded?]

## Open questions
- [Anything still undecided]
```

Tell the user:

> "I've created `PROJECT_BRIEF.md` in the repo root. Fill it in and run `/kickoff`
> again when it's ready. The more specific you are, the better the scaffold."

Stop here. Do not proceed until the brief exists and has real content (not just
placeholder text).

**If it exists but still contains placeholder text** (look for `[` characters in
value positions): point out which sections are incomplete and ask the user to fill
them in before continuing.

---

### Step 2 — Read and reflect

Read `PROJECT_BRIEF.md` in full. Then state back to the user:

> "Here's what I understand about [Project Name]:
>
> **What it is:** [one sentence from the brief]
> **Who it's for:** [primary user]
> **MVP scope:** [bullet list of MVP features]
> **Stack:** [confirmed stack choices, or what you'll recommend for blanks]
> **Key constraints:** [timeline, must-integrates, must-nots — or 'none']
>
> **Open questions I'll need to resolve before scaffolding:**
> [List any unanswered questions from the brief, plus any the agent spots —
> e.g. ambiguous auth model, unclear data ownership, missing API dependencies]
>
> Does this match your intent? Any corrections before I proceed?"

Wait for confirmation or corrections. Incorporate any feedback before moving forward.

---

### Step 3 — Resolve open questions

For each open question (from the brief + any the agent identified):
- Offer a concrete recommendation with a one-sentence rationale
- Ask the user to confirm, override, or defer

Keep this tight. One question at a time. If the user defers a question, note it as
a future task — don't block scaffolding on it.

Record all decisions in `PROJECT_BRIEF.md` under the relevant section (or under
`## Open questions` with the answer noted inline).

---

### Step 4 — Confirm the build plan

Present the full scaffolding plan before touching any files:

> "Here's what I'm about to scaffold:
>
> **1. Fill in `CLAUDE.md`** — project description, stack table, conventions, run commands
> **2. Create initial task backlog** — [N] tasks in `.rig/tasks/backlog/` covering the MVP features:
>    - `[task-slug]` — [one-line description]
>    - [...]
> **3. Open GitHub issues** — one issue per task, labelled and ready to work from
> **4. Update `.rig/memory/PROGRESS.md`** — log the kickoff as the starting entry
>
> Say **go** to scaffold, or adjust the plan."

Wait for explicit go-ahead.

---

### Step 5 — Scaffold

Execute the build plan in order. For each item, confirm completion before moving to
the next.

#### 5.0. Scaffold command safety gate

Before running any scaffold generator or initializer (for example `npm create`,
`npx create-*`, `pnpm create`, `yarn create`, `rails new`, `django-admin
startproject`, `cargo new`, or a framework CLI that creates files), state the exact
command, target directory, and expected files or directories.

After each scaffold command returns:
- Capture and inspect the exit status, stdout, and stderr. Treat any non-zero exit
  or refusal wording (for example "refusing", "refused", "already exists", "not
  empty", or "non-empty directory") as a blocker, even when the command created
  some files.
- Verify every expected file or directory from the scaffold plan exists and has the
  expected type before marking that scaffold item complete. At minimum verify the
  project entry point, package or dependency manifest, configuration file, and source
  directory promised by the plan.
- If the generator refused, partially completed, or the expected files are missing,
  surface the exact failure and stop. Do not report kickoff or the scaffold item as
  complete. Ask whether to adapt the existing directory, choose an empty target, or
  run the generator with an explicit overwrite/current-directory option when that is
  supported.

#### 5a. Fill in CLAUDE.md

Replace every placeholder in `CLAUDE.md` with real content from the brief:
- Project name and description
- Stack table (all rows filled — no blanks)
- `## Project context for task mode` section (entry points, key services, gotchas)
- `## Key conventions` (at minimum: naming, where LLM/DB/auth calls live)
- `## How to run locally` (real commands, not `[command]`)
- `## Off-limits` (at minimum: `.husky/`, `.claude/worktrees/`, `.github/`)

Do not leave any `[PLACEHOLDER]` lines in the final file.

#### 5b. Generate task backlog

For each MVP feature in the brief, create a task file in `.rig/tasks/backlog/` using the
task template. Each task file must have:
- A meaningful slug (e.g. `feat-user-auth.md`, `feat-dashboard-ui.md`)
- `## Goal` — the user-facing outcome this task delivers
- `## Context` — how it fits into the MVP
- `## Acceptance criteria` — at least 3 specific, testable conditions
- `## Operating mode` — default to Medium / Normal / Balanced (dev can adjust via `/task`)
- `## Approach` — a preliminary implementation plan (can be light at this stage)

Order tasks by dependency: foundational work (auth, data layer, core models) before
features that build on them.

#### 5c. Open GitHub issues

For each task file, open a GitHub issue:
- Title: matches the task goal
- Body: copy the `## Goal`, `## Context`, and `## Acceptance criteria` from the task file
- Labels: `type: feat` + the most relevant area label
- Update the task file's `## GitHub issue` field with the issue number

#### 5d. Update .rig/memory/PROGRESS.md

Append a dated entry:

```
## [YYYY-MM-DD] — Project kickoff

- Ran /kickoff from PROJECT_BRIEF.md
- Filled in CLAUDE.md with real project content
- Generated [N] tasks in .rig/tasks/backlog/
- Opened GitHub issues #[X]–#[Y]
- Stack confirmed: [one-line summary]
- Open decisions deferred: [list, or 'none']
```

---

### Step 6 — Hand off

After scaffolding is complete:

> "Kickoff complete. Here's where things stand:
>
> - `CLAUDE.md` is filled in — The Rig is oriented on your project
> - [N] tasks are in `.rig/tasks/backlog/` — ordered by dependency
> - GitHub issues #[X]–#[Y] are open and labelled
>
> Suggested first move: run `/run [first-task-slug]` — that's the foundation
> everything else builds on.
>
> This command has no further use. You can delete `.claude/commands/kickoff.md` — it won't be needed again.
>
> Anything to adjust before you start?"

---

## Notes

- `/kickoff` is a one-time command. Running it again on an established project will
  likely overwrite things. If you want to re-scaffold after a major pivot, archive
  the existing `CLAUDE.md` and `.rig/tasks/` first.
- The task backlog generated here is a starting point, not a contract. Adjust
  priorities, split tasks, or add new ones freely as the project develops.
- All governance rules apply during scaffolding. Protected paths, the `/rig-propose`
  gate, and secret handling are all still active.
- `.rig/memory/RIG_GAPS.md` ships with the project scaffold. As you build, the agent
  logs workflow friction to it during `/wrap`. Use `/rig-gaps` to compile and submit
  those entries to The Rig dev session for future improvements.
