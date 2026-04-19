# Command: /task

Trigger this command to start any unit of work — a ticket, a feature, a bug fix, a
maintenance task, or a support request. It opens an intake wizard that captures what
you want built *and* how you want the agent to behave while building it.

The wizard output is written into the task file. Every future session that loads that
file will inherit the same operating mode — no need to re-configure.

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

After collecting answers, confirm back:

> "Got it. You want to [restate task in one sentence], working in [area], with
> [constraints or 'no hard constraints']. Let's configure how I'll operate."

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

1. Create a task file in `.rig/tasks/backlog/` using the task template.
2. Fill in `## Goal`, `## Context`, and `## Operating mode` from the wizard answers.
3. Move the task file to `.rig/tasks/active/`.
4. Follow `.rig/processes/NEW_TASK_WORKFLOW.md` from Step 0 (GitHub issue first).
5. Execute according to the configured autonomy level.

### Autonomy level execution guide

**Low (Guided)**
- Present the implementation plan and wait for explicit approval.
- Before each file write, state what you're about to do and why. Wait for "ok" or "go".
- After each file write, show a summary of what changed.

**Medium (Supervised)**
- Present the implementation plan and wait for explicit approval.
- Execute the full plan without pausing for individual file writes.
- Narrate progress at milestones (plan → implementation → tests → PR-ready).
- Pause if: an unexpected file needs changing, a dependency must be added, a decision
  branches into two reasonable approaches.

**High (Autonomous)**
- Present the implementation plan; wait for approval (one pause only).
- Execute end-to-end without interruption.
- Only pause for irreversible actions: DB migrations, deleting files, force pushes,
  publishing to external services.
- Log all decisions in `## Prompt history` of the task file.

### Governance always applies

Regardless of autonomy level:
- Pre-tool hooks still run. Governance files (listed in `pre-tool.sh`) are still protected.
- Changes to The Rig's own `.rig/processes/`, `.rig/rules/`, hooks, or CLAUDE.md still require `/propose`.
- Secrets and credentials are never written to files.
- The pre-ship checklist (`/ship`) still runs before any PR is opened.

---

## Notes

- If a task file already exists in `.rig/tasks/active/`, check before creating a new one —
  offer to resume it instead.
- The `## Operating mode` block in the task file is the source of truth for this task's
  configuration. Never change it mid-task without asking the user first.
- If the user adjusts the autonomy level mid-task, update `## Operating mode` in the
  task file and note the change under `## Prompt history`.
