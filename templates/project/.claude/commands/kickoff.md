# Command: /kickoff

> **Work-mode adapter:** Follow `.rig/processes/WORK_MODES.md` as the canonical
> lifecycle and state contract. This command supplies project-mode intake and
> outputs only; the shared contract governs approvals, transitions, and resume.

> **Run once, at project creation.** After `/kickoff` completes, this command has no further use — you can delete `.claude/commands/kickoff.md` from your project.

Trigger this command to bootstrap a brand new project from scratch.

`/kickoff` is the greenfield entry point. It reads your `PROJECT_BRIEF.md`, confirms
it understands what's being built, resolves open questions, then scaffolds everything
needed to start shipping: a filled-in `CLAUDE.md`, an initial task backlog, and
tracker items for the first milestone in the tracker named by `issue-tracking:` in
`CLAUDE.md` (GitHub issues for `github` or an absent field, opened by the agent
only when `issue-creator: agent`; no tracker items for `none`).

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

First, read the configured issue tracker and issue creator from `CLAUDE.md`. An
absent `issue-tracking:` field means `github`; an absent `issue-creator:` field
means `user`. The marker comments are used by the focused tracker tests; keep the
commands between them executable:

```bash
# kickoff-tracker-probe-start
REPO=$(git rev-parse --show-toplevel)
TRACKING=$(grep "^issue-tracking:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
CREATOR=$(grep "^issue-creator:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
printf 'tracking=%s creator=%s\n' "${TRACKING:-github}" "${CREATOR:-user}"
# kickoff-tracker-probe-end
```

Pick the tracker mode from the printed values:
- `tracking=github creator=agent` → mode `github-agent`
- `tracking=github` with any other creator value → mode `github-user`
  (`issue-creator: user` is the default, and any creator other than `agent`
  falls back to `user`, as in `/task`)
- `tracking=linear`, `tracking=trello`, `tracking=gus`, or `tracking=none` → mode
  `linear`, `trello`, `gus`, or `none` (`issue-creator:` only applies to GitHub)

If `tracking=` is anything else, stop and tell the user:
"`issue-tracking: [value]` in `CLAUDE.md` is not a supported tracker. Set it to
`github`, `linear`, `trello`, `gus`, or `none`, then run `/kickoff` again." Do not
scaffold until the value is supported.

**GitHub preflight — mode `github-agent` only.** Before presenting the plan, check
that the agent can actually open issues in this repository. Run:

```bash
# kickoff-github-preflight-start
REPO=$(git rev-parse --show-toplevel)
github_ready=1
if [[ -z "$(git -C "$REPO" remote 2>/dev/null)" ]]; then
  printf 'preflight: no git remote is configured\n'
  github_ready=0
elif ! command -v gh >/dev/null 2>&1; then
  printf 'preflight: the gh CLI is not installed\n'
  github_ready=0
elif ! gh auth status >/dev/null 2>&1; then
  printf 'preflight: gh is not authenticated (run gh auth login)\n'
  github_ready=0
elif ! (cd "$REPO" && gh repo view --json nameWithOwner -q .nameWithOwner >/dev/null 2>&1); then
  printf 'preflight: the git remote is not a GitHub repository gh can reach\n'
  github_ready=0
fi
type_feat_label=unknown
if (( github_ready == 1 )); then
  if (cd "$REPO" && gh label list --limit 200 --json name -q '.[].name' 2>/dev/null) \
    | /usr/bin/grep -qx 'type: feat'; then
    type_feat_label=present
  else
    type_feat_label=missing
  fi
fi
printf 'github_ready=%s type_feat_label=%s\n' "$github_ready" "$type_feat_label"
# kickoff-github-preflight-end
```

- If `github_ready=1`, keep mode `github-agent`. If `type_feat_label=missing`, item
  3 of the plan must also say that Step 5c will create the `type: feat` label
  first. Also note which existing labels whose names start with `area:` fit the
  tasks. Use only labels that already exist; never invent an area label.
- If `github_ready=0`, switch to mode `github-deferred`. Show each `preflight:` line
  to the user in the plan, and offer to continue with task files only. The user
  can also fix the cause and run `/kickoff` again before saying **go**.

Choose item 3's wording for the tracker mode from this table:

| Tracker mode | Item 3 of the plan |
|---|---|
| `github-agent` | **3. Open GitHub issues** — I open one issue per task, labelled `type: feat` plus an existing `area:` label when one fits |
| `github-user` | **3. Link GitHub issues** — you create one GitHub issue per task and give me each number (`issue-creator: user`); I record them in the task files |
| `github-deferred` | **3. GitHub issues deferred** — preflight failed ([each `preflight:` line]); task files get `**GitHub issue**: TBD` and each one needs an issue before work starts |
| `linear` | **3. Link Linear tickets** — you create one Linear ticket per task and give me each ticket ID (e.g. `ENG-123`); I record them in the task files |
| `trello` | **3. Link Trello cards** — you create one Trello card per task and give me each card ID or short URL; I record them in the task files |
| `gus` | **3. Link GUS work items** — you create one GUS work item per task and give me each item ID (e.g. `W-1234567`); I record them in the task files |
| `none` | **3. No tracker items** — `issue-tracking: none` is set, so the local task files are the backlog |

Use this tracker mode for item 3 of the plan below and for Steps 5c, 5d, and 6.

Present the full scaffolding plan before touching any files:

> "Here's what I'm about to scaffold:
>
> **1. Fill in `CLAUDE.md`** — project description, stack table, conventions, run commands
> **2. Create initial task backlog** — [N] tasks in `.rig/tasks/backlog/` covering the MVP features:
>    - `[task-slug]` — [one-line description]
>    - [...]
> **3. [item 3 wording for the tracker mode, from the tracker-mode table in this step]**
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

Do not leave any `[PLACEHOLDER]` lines in the final file. Keep the existing
`issue-tracking:` and `issue-creator:` values unchanged unless the user explicitly
asks to change them; Steps 5c, 5d, and 6 use the tracker mode chosen in Step 4.

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

#### 5c. Record tracker items

Use the tracker mode chosen in Step 4. The agent opens issues only in mode
`github-agent`. It never creates GitHub issues in mode `github-user`, and the
agent never creates Linear tickets, Trello cards, or GUS work items.

**`github-agent`:** The user's **go** in Step 4 authorizes these issues and any
missing `type: feat` label. If the Step 4 preflight printed
`type_feat_label=missing`, create the label first, with the same name, color, and
description that `.rig/processes/SHIP_WORKFLOW.md` uses:

```bash
gh label create "type: feat" --color "#0075ca" --description "New feature"
```

Then, for each task file in dependency order, open a GitHub issue:
- Title: matches the task goal
- Body: copy the `## Goal`, `## Context`, and `## Acceptance criteria` from the task file
- Labels: `type: feat`, plus one existing `area:` label when one fits. If none
  fits, use `type: feat` alone; never invent a label.
- Run `gh issue create --title "[task goal]" --body-file [file holding the body] --label "type: feat"`,
  adding `--label "[existing area label]"` only when one fits
- Set the task file's `**GitHub issue**:` field to the issue number, e.g. `#42`

If `gh label create` or any `gh issue create` fails, show the exact error and stop
creating issues. Set `**GitHub issue**: TBD` in every task file that does not yet
have a number. Tell the user which issue numbers were already created (with their
task slugs) and which task files still need an issue. Then continue to Step 5d and
Step 6 and report the same split there. Do not report issues as opened until each
one has a real number.

**`github-user`, `linear`, `trello`, or `gus`:** List every task file with its title,
goal, and acceptance criteria so the user can create one item per task in their
tracker. Then say exactly:

> "Create one [GitHub issue / Linear ticket / Trello card / GUS work item] per task
> listed above and share each reference next to its task slug — I'll wait. The
> references go in the task files and every commit."

Wait for the references. Record them in each task file in the tracker's format:
- `github-user`: keep the `**GitHub issue**:` line and set it, e.g. `**GitHub issue**: #42`
- `linear`: replace the `**GitHub issue**: #[N]` line with `**Issue**: ENG-123`
- `trello`: replace the `**GitHub issue**: #[N]` line with `**Issue**: trello:CARD-ID`
- `gus`: replace the `**GitHub issue**: #[N]` line with `**Issue**: W-1234567`

If the user cannot provide a reference for a task yet, set that task's line to
`TBD` (`**GitHub issue**: TBD` for `github-user`, `**Issue**: TBD` otherwise) and
list it in Step 6 as needing a ticket before work starts.

**`github-deferred`:** Do not run `gh`. Set `**GitHub issue**: TBD` in every task
file and list every task in Step 6 as needing an issue before work starts.

**`none`:** Do not create or request tracker items. For each task file, replace the
`**GitHub issue**: #[N]` line with `**Issue**: N/A (issue-tracking: none)`.

#### 5d. Update .rig/memory/PROGRESS.md

Append a dated entry:

```
## [YYYY-MM-DD] — Project kickoff

- Ran /kickoff from PROJECT_BRIEF.md
- Filled in CLAUDE.md with real project content
- Generated [N] tasks in .rig/tasks/backlog/
- [Tracker line for the tracker mode chosen in Step 4: `github-agent` → "Opened GitHub issues #[X]–#[Y]", plus any task files left at `TBD` after a failure; `github-user` → "Linked GitHub issues #[X]–#[Y]", plus any `TBD`; `github-deferred` → "GitHub issues deferred (preflight failed); all task files at TBD"; `linear` / `trello` / `gus` → "Linked [tracker] items [references]", plus any `TBD`; `none` → "No tracker items (issue-tracking: none)"]
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
> - [Tracker line for the tracker mode chosen in Step 4: `github-agent` → "GitHub issues #[X]–#[Y] are open and labelled", plus the task files still at `TBD` if creation failed partway; `github-user` → "GitHub issues #[X]–#[Y] are recorded in the task files", plus any still at `TBD`; `github-deferred` → "GitHub issues were not opened ([preflight reason]); every task file is at `TBD` and needs an issue before work starts"; `linear` / `trello` / `gus` → "[Tracker] items [references] are recorded in the task files", plus any still at `TBD`; `none` → "No tracker items — `issue-tracking: none` keeps the backlog in local task files"]
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
