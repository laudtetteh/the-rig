# Command: /sprint

> **Work-mode adapter:** Follow `.rig/processes/WORK_MODES.md` as the canonical
> lifecycle and state contract. Sprint mode coordinates existing task cards;
> each embedded task retains its own operating mode, checkpoints, and ship gate.

Plan and execute a batch of tasks as a sprint, with conflict detection and
wave-based ordering to minimize merge friction.

**Use `/sprint` when:** you have several tasks to run in one session and want
conflict-aware ordering rather than simple sequential execution.

**Use `/run` when:** you just want to work through the queue in priority order
without conflict analysis.

---

## Usage

```
/sprint                  # analyze all backlog tasks and propose a sprint plan
/sprint [slug …]         # analyze only the named tasks (space-separated slugs)
/sprint --issues #N …    # resolve task slugs from GitHub issue numbers
```

> **RIG_DIR resolution (stealth mode):** Before reading any `.rig/` path, resolve
> where `.rig/` actually lives:
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

---

## Step 1 — Gather tasks

If task slugs are named explicitly, load those task files only.
Otherwise, load all files in `.rig/tasks/backlog/` and `.rig/tasks/active/`,
skipping `TASK_example.md`.

For each task, extract:
- Slug (filename without `.md`)
- Priority (`P0`–`P3`, default `P2` if absent)
- `## Files likely affected` — the list of paths this task will touch
- `## Depends on` — prerequisite tasks

---

## Step 2 — Conflict detection

Build a **conflict graph**:

1. For each task, normalise its `## Files likely affected` paths to a set of
   strings (one path per line, strip leading `-`, quotes, and inline notes).
2. Two tasks **conflict** if their path sets share at least one file.
3. Tasks with a `## Depends on` dependency on another task in this sprint also
   count as conflicting with that task (ordering constraint, not file overlap).

---

## Step 3 — Wave planning

Group tasks into **waves** using a greedy graph-colouring approach:

1. Start with the highest-priority un-assigned task.
2. Assign it to the current wave.
3. For each remaining un-assigned task (in priority order): assign to the current
   wave if it conflicts with **none** of the tasks already in the wave; otherwise
   defer to the next wave.
4. Repeat until all tasks are assigned.

Within a wave, order tasks by priority (P0 first). Dependency-blocked tasks
(where the prerequisite is not yet in `.rig/tasks/done/`) are excluded from the
plan entirely and listed as "blocked".

---

## Step 4 — Present the sprint plan

Show the proposed plan:

> "**Sprint plan — [N] tasks across [W] wave(s)**
>
> **Wave 1** (conflict-free):
> | Task | Priority | Files |
> |---|---|---|
> | `feat-user-auth` | P0 | `services/auth.py`, `routes/auth.py` |
> | `fix-email-typo` | P2 | `templates/email.html` |
>
> **Wave 2** (depends on Wave 1):
> | Task | Priority | Conflict with |
> |---|---|---|
> | `feat-dashboard` | P1 | — |
> | `feat-profile` | P2 | `feat-user-auth` (shared: `services/auth.py`) |
>
> **Blocked (not in this sprint):**
> - `feat-export` — waiting on `feat-dashboard` (not in done/)
>
> I'll run Wave 1 tasks in order, pause for review, then run Wave 2.
> Say **go** to start, or adjust the wave groupings."

Wait for the user's confirmation before executing anything.

---

## Step 5 — Execute wave by wave

For each wave in order:

1. **Announce the wave:**
   > "Starting Wave [N]: [task-slug-1], [task-slug-2], …"

2. **Execute each task in the wave** using the same execution guide as `/run`
   (autonomy level from the task file, governance rules always apply).

3. **After all tasks in the wave are complete**, pause and report:
   > "Wave [N] complete. [N] tasks done, [N] PRs opened.
   > Ready for Wave [N+1]? Say **go** to continue, or adjust before proceeding."

   Wait for confirmation before starting the next wave.

4. If a task in the current wave **fails or is blocked mid-execution**, stop
   the wave, surface the issue, and ask the user how to proceed. Do not
   automatically skip to the next task in the wave.

---

## Step 6 — Sprint complete

When all waves are done:

> "Sprint complete. [N] tasks shipped:
> - Wave 1: feat-user-auth (#12), fix-email-typo (#18)
> - Wave 2: feat-dashboard (#20), feat-profile (#21)
>
> `.rig/tasks/done/` updated. PROGRESS.md updated.
> Anything to add to the backlog for the next sprint?"

---

## Conflict detection notes

- **`## Files likely affected` is the source of truth.** If a task doesn't have
  this section, assume it could conflict with anything and place it in its own wave.
- **Paths are compared by prefix.** A task listing `services/` and another listing
  `services/auth.py` are considered conflicting.
- **Wildcard entries** (e.g. `**/*.py`) count as conflicting with every other task
  that lists any `.py` file.
- **Conflict detection is conservative.** When in doubt, wave-separate — a false
  positive (unnecessary sequencing) is safer than a false negative (real merge
  conflict during execution).

---

## Governance

All `/run` governance rules apply:

- Pre-tool hooks run on every file write.
- The pre-ship checklist (`/ship`) must pass before any PR is opened.
- Secrets and credentials are never written to files.
- Irreversible actions always require explicit confirmation.
- Changes to The Rig's own processes, rules, hooks, or CLAUDE.md require `/rig-propose`.
