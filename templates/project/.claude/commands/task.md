# Command: /task

> **Work-mode adapter:** Follow `.rig/processes/WORK_MODES.md` as the canonical
> lifecycle and state contract. This command supplies task-mode intake only;
> execution uses the same task card and requires its own approved launch.

Trigger this command to start any unit of work — a ticket, a feature, a bug fix, a
maintenance task, or a support request. It opens an intake wizard that captures what
you want built *and* how you want the agent to behave while building it.

The wizard output is written into the task file. Every future session that loads that
file will inherit the same operating mode — no need to re-configure.

> **RIG_DIR resolution (stealth mode):** Before creating any task file, resolve where
> `.rig/` actually lives. If `.rigpath` exists at the project root, read it — it
> contains the absolute path to the external `.rig/` directory. Substitute that path
> for `.rig/` in every step below.
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

## Intake wizard

Work through the three parts in sequence. Do not skip ahead. Do not write any code
until Part 3 is confirmed.

---

### Part 1 — The Order

Ask the user the following. Collect all answers before moving to Part 2.

1. **What's the task?** One sentence — what does done look like?
2. **New or existing project?** If existing, briefly describe the relevant area of
   the codebase (what service, module, or directory will this touch?).
3. **Hard constraints?** Any deadline, off-limits paths, technology restrictions, or
   things that must not change?
4. **Issue/ticket?** Read `issue-tracking:` and `issue-creator:` from `CLAUDE.md` first.
5. **Tests required?** Should this task include tests?
   - **yes** — tests are required before this task can ship
   - **no** — tests are explicitly out of scope (state why, e.g. "pure config change")
   - **optional** — write tests if the logic warrants it; no hard gate
   Record the answer in the task file under `## Testing`. The `/ship` pre-commit step
   reads this field — if `yes`, tests must exist before the commit is allowed.

   - **`issue-tracking: github`** (or field absent — default):
     - Also read `issue-creator:` (default: `user`).
     - **`issue-creator: user`**: A GitHub issue is required. If the user already provided a number (e.g. `#42`), note it and continue. If none exists yet, stop and say exactly:
       > "Every task needs a GitHub issue before we start. Create one now and share the number — I'll wait. It goes in the task file and every commit."
       Do not proceed to Part 2 until a real issue number is provided.
     - **`issue-creator: agent`**: Create the GitHub issue now using the task description from question 1. Run:
       ```bash
       gh issue create --title "[task title]" --body "[one-line context]"
       ```
       Note the number, tell the user: "Created issue #[N]. Proceeding." If the user already provided a number, use that instead — skip creation.

   - **`issue-tracking: linear`**: Ask for the existing Linear ticket ID (e.g. `ENG-123`). Note in the task file: `**Issue**: ENG-123`. Agent never creates Linear tickets. If no ticket exists, stop and ask the user to create one.

   - **`issue-tracking: trello`**: Ask for the existing Trello card ID or short URL. Note in the task file: `**Issue**: trello:CARD-ID`. Agent never creates Trello cards.

   - **`issue-tracking: gus`**: Ask for the existing GUS work item ID (e.g. `W-1234567`). Note in the task file: `**Issue**: W-1234567`. Agent never creates GUS items.

   - **`issue-tracking: none`**: Skip the issue requirement. Note in the task file: `**Issue**: N/A (issue-tracking: none)`. Continue to Part 2 immediately.

After collecting all answers, confirm back:

> "Got it. You want to [restate task in one sentence], working in [area], with
> [constraints or 'no hard constraints']. Issue: [ref]. Tests: [yes/no/optional].
> Let's configure how I'll operate."

---

### Part 2 — How You Want It Cooked

Present the three settings as a menu. The user can pick by number, emoji, or name.
If they skip a setting, default to the middle option.

---

#### Autonomy

How much should the agent decide independently?

| # | Level | Behaviour |
|---|---|---|
| 1 | 🌶 **Low (Guided)** | Propose a plan and wait for step-by-step approval. Pause before every file write. No surprises. |
| 2 | 🌶🌶 **Medium (Supervised)** | Propose a plan, wait for go-ahead, then execute the full plan autonomously. Surface blockers and unexpected findings — but no micro-approvals. |
| 3 | 🌶🌶🌶 **High (Autonomous)** | Execute from plan to ship with minimal interruptions. Only pause for irreversible actions (DB migrations, force pushes, deleting files). |

Default: **2 — Medium (Supervised)**

---

#### Check-ins

How much narration do you want while work is in progress?

| # | Level | Behaviour |
|---|---|---|
| 1 | **Verbose** | Narrate each step. Show what's about to change and why before writing. Explain every non-obvious decision. |
| 2 | **Normal** | Summarize progress at natural milestones: plan approved → implementation done → PR-ready. |
| 3 | **Quiet** | Status line only. Surface blockers and decisions that need input — nothing else. |

Default: **2 — Normal**

---

#### Risk tolerance

How conservatively should the agent treat scope, dependencies, and side effects?

| # | Level | Behaviour |
|---|---|---|
| 1 | **Conservative** | No new dependencies without approval. No refactoring outside the task boundary. No schema changes without explicit sign-off. Flag anything touching > 3 files. |
| 2 | **Balanced** | Use judgment. Flag anything with blast radius > 5 files. Propose rather than decide on architectural choices. |
| 3 | **Aggressive** | Move fast. Make the call on ambiguous decisions. Note what was decided, but don't stop for confirmation unless the action is irreversible. |

Default: **2 — Balanced**

---

### Part 3 — Confirmation

Read back the full order before touching anything:

> "Here's what I'm working on and how I'll operate:
>
> **Task:** [one-sentence goal]
> **Area:** [relevant codebase area or 'new project']
> **Constraints:** [list or 'none']
>
> **Operating mode:**
> - Autonomy: [level name]
> - Check-ins: [level name]
> - Risk: [level name]
>
> [One sentence describing what this combination means in practice — e.g.
> 'I'll execute the full plan after approval and give you progress updates at
> milestones, but I'll flag any change that touches more than 5 files.']
>
> Say **go** to start, or adjust any setting."

Wait for explicit go-ahead before proceeding.

---

## After confirmation

### Branch-name normalization

When the requested branch name differs from the current branch only by letter case,
do not rely on a direct rename. Case-insensitive filesystems can make Git mistake the
current ref for an existing target. Use this helper for any requested rename; it keeps
ordinary rename conflicts visible and uses a temporary ref only for a case-only change.

```bash
# branch-case-rename:start
rename_branch_case_safe() {
  local desired_branch="$1"
  local current_branch current_folded desired_folded slug temp_base temp_branch suffix rename_status

  current_branch=$(git branch --show-current) || return
  if [[ -z "$current_branch" ]]; then
    echo "Cannot rename a detached HEAD." >&2
    return 1
  fi

  current_folded=$(printf '%s' "$current_branch" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  desired_folded=$(printf '%s' "$desired_branch" | LC_ALL=C tr '[:upper:]' '[:lower:]')

  if [[ "$current_branch" != "$desired_branch" && "$current_folded" == "$desired_folded" ]]; then
    slug=$(printf '%s' "$current_branch" | LC_ALL=C tr -c '[:alnum:]._- ' '-' | tr ' ' '-')
    temp_base="tmp/${slug}-rename"
    temp_branch="$temp_base"
    suffix=0
    while git show-ref --verify --quiet "refs/heads/$temp_branch"; do
      suffix=$((suffix + 1))
      temp_branch="${temp_base}-${suffix}"
    done

    git branch -m "$temp_branch" || return
    rename_status=0
    git branch -m "$desired_branch" || rename_status=$?
    if [[ "$rename_status" -ne 0 ]]; then
      if git branch -m "$current_branch"; then
        echo "Rename to '$desired_branch' failed; restored '$current_branch'." >&2
      else
        echo "Rename to '$desired_branch' failed and rollback failed; branch remains '$temp_branch'." >&2
      fi
      return "$rename_status"
    fi
    return 0
  fi

  git branch -m "$desired_branch"
}
# branch-case-rename:end

rename_branch_case_safe "[desired-branch-name]"
```

If the helper reports a failure, stop. Do not delete the temporary ref: the message
identifies it when rollback also fails, preserving the user's work for recovery.

1. Create a task file in `.rig/tasks/backlog/` using the task template.
2. Fill in `## Goal`, `## Context`, and `## Operating mode` from the wizard answers.
3. Move the task file to `.rig/tasks/active/`.
4. Follow `.rig/processes/NEW_TASK_WORKFLOW.md` from Step 0 (GitHub issue first).
5. Execute according to the configured autonomy level.

When this workflow records completion in `.rig/memory/PROGRESS.md`, insert the new
entry immediately after the `## Format` section, at the fixed top-insertion anchor.
Never anchor the insertion to the agent's own prior PROGRESS edit from the same
session.

### Autonomy level execution guide

**Low (Guided)**
- Present the implementation plan and wait for explicit approval.
- Before each file write, state what you're about to do and why. Wait for "ok" or "go".
- After each file write, show a summary of what changed.
- **Branch creation:** always confirm which base branch to branch off before running
  `git checkout -b`. Read `base-branch:` from `CLAUDE.md`; present it and wait for
  the user to confirm or specify a different base.

**Medium (Supervised)**
- Present the implementation plan and wait for explicit approval.
- Execute the full plan without pausing for individual file writes.
- Narrate progress at milestones (plan → implementation → tests → PR-ready).
- Pause if: an unexpected file needs changing, a dependency must be added, a decision
  branches into two reasonable approaches.
- **Branch creation:** confirm the base branch before running `git checkout -b`.

**High (Autonomous)**
- Present the implementation plan; wait for approval (one pause only).
- Execute end-to-end without interruption.
- Only pause for irreversible actions: DB migrations, deleting files, force pushes,
  publishing to external services.
- Log all decisions in `## Prompt history` of the task file.
- **Branch creation:** read `base-branch:` from `CLAUDE.md`, state the base you're
  using ("Creating `[branch-name]` off `[BASE]`"), then branch immediately — no wait.

### Governance always applies

Regardless of autonomy level:
- Pre-tool hooks still run. Governance files (listed in `pre-tool.sh`) are still protected.
- Changes to The Rig's own `.rig/processes/`, `.rig/rules/`, hooks, or CLAUDE.md still require `/rig-propose`.
- Secrets and credentials are never written to files.
- The pre-ship checklist (`/ship`) still runs before any PR is opened.
- At task completion, any Rig workflow friction or gaps observed must be logged to
  `.rig/memory/RIG_GAPS.md`. Use `/rig-gaps` to compile and submit them.

---

## Notes

- If a task file already exists in `.rig/tasks/active/`, check before creating a new one —
  offer to resume it instead.
- The `## Operating mode` block in the task file is the source of truth for this task's
  configuration. Never change it mid-task without asking the user first.
- If the user adjusts the autonomy level mid-task, update `## Operating mode` in the
  task file and note the change under `## Prompt history`.
