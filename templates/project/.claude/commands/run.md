# Command: /run

Trigger this command to start executing the task backlog.

`/run` surveys what's ready to work, proposes an execution order, and drives tasks
to completion. It reads the `## Operating mode` from each task file and behaves
accordingly — chaining tasks autonomously or pausing between them depending on the
configured autonomy level.

**Use `/run` when:** the backlog has tasks ready to execute and you want The Rig to
start working through them.

**Use `/task` when:** you need to create and configure a new task first.

**Use `/kickoff` when:** you're starting a greenfield project with no backlog yet.

---

## Usage

```
/run              # work through the full queue in priority order
/run [task-slug]  # run a specific task only (e.g. /run feat-user-auth)
```

---

## Execution flow

### Step 1 — Survey the backlog

Read all files in `.rig/tasks/backlog/` and `.rig/tasks/active/`. For each task, extract:
- Task slug (filename without `.md`)
- Status
- Priority (`P0`–`P3`)
- `## Depends on` (if present)
- `## Operating mode` autonomy level

Build a work queue: tasks ordered by priority (P0 first), with dependency-blocked
tasks excluded. A task is dependency-blocked if its `## Depends on` references a
task that is not yet in `.rig/tasks/done/`.

Present the queue:

> "Here's what's ready to run:
>
> | # | Task | Priority | Autonomy | Blocked by |
> |---|---|---|---|---|
> | 1 | `feat-user-auth` | P0 | 🌶🌶 Medium | — |
> | 2 | `feat-dashboard-ui` | P1 | 🌶🌶🌶 High | — |
> | 3 | `feat-export` | P2 | 🌶🌶 Medium | feat-dashboard-ui |
>
> **Not ready (blocked):**
> - `feat-notifications` — waiting on `feat-user-auth`
>
> I'll work through the queue in order. Say **go** to start, name a specific task
> to start there, or adjust the order."

Wait for confirmation before executing anything.

---

### Step 2 — Execute tasks in queue order

For each task in the confirmed queue:

1. **Load the task file.** Read `## Goal`, `## Approach`, `## Acceptance criteria`,
   and `## Operating mode`.

2. **Announce the task.** State:
   > "Starting: `[task-slug]` — [goal sentence] (Autonomy: [level], Check-ins: [level])"

3. **Execute according to autonomy level.** See the execution guide below.

4. **Complete the task.** When all acceptance criteria are met:
   - Fill in `## Done notes` in the task file
   - Move the task file from `.rig/tasks/active/` (or `.rig/tasks/backlog/`) to `.rig/tasks/done/`
   - Append an entry to `.rig/memory/PROGRESS.md`
   - Run the pre-ship checklist (`/ship`) before opening any PR

5. **Decide whether to continue.** See chaining rules below.

---

## Execution guide by autonomy level

### 🌶 Low (Guided)

- Move the task to `.rig/tasks/active/` and announce you're starting.
- Write the implementation plan into `## Approach` and wait for explicit approval.
- Before **each file write**: state what you're about to do and why. Wait for "ok".
- After each file write: summarize what changed.
- After completing the task: always pause before starting the next one.

### 🌶🌶 Medium (Supervised)

- Move the task to `.rig/tasks/active/` and announce you're starting.
- Write the implementation plan into `## Approach` and wait for explicit approval.
- Execute the full plan without pausing for individual file writes.
- Narrate progress at milestones: plan approved → implementation done → tests → PR-ready.
- Pause and surface to the user if:
  - An unexpected file outside the plan needs changing
  - A new dependency must be added
  - A decision branches into two reasonable approaches with meaningfully different tradeoffs
- After completing the task: pause and ask before starting the next one.

### 🌶🌶🌶 High (Autonomous)

- Move the task to `.rig/tasks/active/` and announce you're starting.
- Write the implementation plan into `## Approach` and wait for approval (one pause only).
- Execute end-to-end without interruption.
- Only pause for irreversible actions: DB migrations, deleting files, force pushes,
  publishing to external services. For each: state what you're about to do and wait
  for explicit confirmation.
- Log all non-obvious decisions in `## Prompt history` of the task file.
- After completing the task: immediately announce the next task and begin (no pause).

---

## Task chaining rules

The autonomy level that controls chaining is the level of the **task just completed**,
not the next task.

| Completed task autonomy | Behaviour after completion |
|---|---|
| 🌶 Low | Always pause. Ask: "Task done. Start `[next-task]` next?" |
| 🌶🌶 Medium | Always pause. Ask: "Task done. Start `[next-task]` next?" |
| 🌶🌶🌶 High | Announce completion and immediately begin next task in queue |

If the queue is exhausted, always surface to the user regardless of autonomy level:

> "Queue complete. All [N] tasks are done. `.rig/tasks/done/` has [list].
> Anything to add to the backlog, or is the milestone complete?"

---

## Running a specific task

```
/run feat-user-auth
```

1. Find `.rig/tasks/backlog/feat-user-auth.md` or `.rig/tasks/active/feat-user-auth.md`.
2. Check its `## Depends on` — if the dependency isn't done, say so and stop.
3. Execute that task only, using its configured operating mode.
4. After completion, return to the user. Do not automatically start another task.

---

## Governance

Regardless of autonomy level, all of the following always apply:

- Pre-tool hooks run on every file write. Governance files remain protected.
- Changes to The Rig's own processes, rules, hooks, or CLAUDE.md require `/propose`.
- The pre-ship checklist (`/ship`) must pass before any PR is opened.
- Secrets and credentials are never written to files.
- Irreversible actions always require explicit confirmation — even at High autonomy.

"High (Autonomous)" means the agent makes judgment calls and chains tasks without
hand-holding. It does not mean the agent bypasses safety checks or skips the PR
process.

---

## Notes

- If a task has no `## Operating mode` block, default to Medium / Normal / Balanced
  and note the assumption.
- If `.rig/tasks/active/` already has a task in it when `/run` is called, offer to resume
  it rather than starting a new one from the backlog.
- `/run` does not modify the queue mid-execution. If new tasks are added to the backlog
  while `/run` is active, they'll appear in the next run.
