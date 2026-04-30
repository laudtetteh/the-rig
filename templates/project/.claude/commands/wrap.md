# Command: /wrap

Trigger this command before ending a session or when approaching a context limit.

## What this does

Performs the session-end housekeeping that prevents state loss between sessions:

1. Writes (overwrites) `.rig/memory/CONTEXT_SNAPSHOT.md` with full current project state
2. Ensures `.rig/memory/PROGRESS.md` is up to date — expands any auto-stubbed entries
3. **Trims `.rig/memory/PROGRESS.md`** if it has grown beyond 20 entries (see Trim step below)
4. Checks `.rig/memory/ERRORS.md` — prompts you to log anything unexpected from this session
5. **Self-improvement check** — scans for Rig workflow gaps and logs them to `.rig/memory/RIG_GAPS.md`
6. **Trims `.rig/memory/ERRORS.md`** if it has grown beyond 30 entries (see Trim step below)
7. Reports what's in `.rig/tasks/active/` so you know what's in flight
8. **Suggests a session name** — derives a `/rename` command from this session's work (see Session naming step below)
9. Surfaces the next priority from `.rig/tasks/backlog/` and asks: "What's next?"

## Usage

```
/wrap
```

Run this:
- Before closing Claude Code for the day
- When the conversation is getting long and you want a clean handoff point
- Before switching to a different task or project
- Any time you want to ensure a future session can pick up exactly where you left off

## Trim step — PROGRESS.md

After updating `.rig/memory/PROGRESS.md`, count the number of `## ` entry headers in the file.

**If the count is 20 or fewer:** nothing to do.

**If the count exceeds 20:** tell the user:

> "`.rig/memory/PROGRESS.md` has [N] entries. I'll move the oldest [N-20] to
> `.rig/memory/PROGRESS_archive.md` to keep session startup lean. The archive is
> gitignored — history is preserved locally but won't be loaded at session start.
> Trim now?"

If the user confirms:
1. Identify the oldest entries (bottom of the file, since entries are newest-first)
2. Prepend them to `.rig/memory/PROGRESS_archive.md` (create if absent)
3. Remove them from `.rig/memory/PROGRESS.md`, leaving the 20 most recent entries
4. Confirm: "`.rig/memory/PROGRESS.md` trimmed to 20 entries. Archive: `.rig/memory/PROGRESS_archive.md`"

Never trim without confirmation. Never delete entries — only move them.

---

## Self-improvement check

After logging new ERRORS.md entries, run a brief Rig retrospective:

**Scan ERRORS.md** for entries that describe friction with The Rig's own workflow
(not project bugs). Ask: did anything about The Rig slow you down, produce wrong
output, or feel missing or broken this session?

For each Rig-related friction point — whether from ERRORS.md or from this session —
that is **not already in** `.rig/memory/RIG_GAPS.md`:

1. Append a new entry to `.rig/memory/RIG_GAPS.md` using this format:
   ```
   ## [YYYY-MM-DD] — [short title]

   **Category**: bug | friction | missing-feature | improvement
   **Severity**: blocking | annoying | nice-to-have
   **Workflow**: [which command/process/hook triggered this]
   **Observation**: [what happened or what was missing]
   **Suggested fix**: [concrete suggestion, or "unclear"]
   ```
2. Note in your wrap-up summary: "Logged [N] new gap(s) to `.rig/memory/RIG_GAPS.md`."

If there is nothing to log, skip silently — do not mention this step.

> **Why this matters:** The Rig improves by collecting friction signals from real use.
> Logging gaps during `/wrap` ensures they don't get lost. Use `/rig-gaps` to compile
> and submit them to The Rig dev session.

---

## Trim step — ERRORS.md

After checking `.rig/memory/ERRORS.md`, count the number of `## ` entry headers in the file.

**If the count is 30 or fewer:** nothing to do.

**If the count exceeds 30:** tell the user:

> "`.rig/memory/ERRORS.md` has [N] entries. I'll move the oldest [N-30] to
> `.rig/memory/ERRORS_archive.md` to keep session startup lean. The archive is
> gitignored — pitfall history is preserved locally but won't load at session start.
> Trim now?"

If the user confirms:
1. Identify the oldest entries (bottom of the file, since entries are newest-first)
2. Prepend them to `.rig/memory/ERRORS_archive.md` (create if absent)
3. Remove them from `.rig/memory/ERRORS.md`, leaving the 30 most recent entries
4. Confirm: "`.rig/memory/ERRORS.md` trimmed to 30 entries. Archive: `.rig/memory/ERRORS_archive.md`"

Never trim without confirmation. Never delete entries — only move them.

---

## Session naming step

After reporting active tasks, derive a session name from this session's work and
output it as a ready-to-run `/rename` command. Do **not** run it automatically —
present it for the user to run or tweak.

### How to determine "this session's work"

**Do not use today's date** — it breaks for sessions that span midnight or are
resumed days later. Use this priority order:

1. **`<!-- session-end -->` markers in PROGRESS.md** (most reliable)
   The `stop.sh` hook appends `<!-- session-end YYYY-MM-DD HH:MM -->` automatically
   when the agent finishes each response. Look for the most recent such marker:
   - Entries **above** the most recent marker belong to this session.
   - Entries **below** it belong to prior sessions.

2. **`Last updated:` field in the previous CONTEXT_SNAPSHOT** (fallback)
   If no session-end marker exists (e.g. stop.sh wasn't wired yet, or this is the
   first /wrap on a new install), read the `**Last updated:**` field from the snapshot
   you noted at session start (before step 1 overwrote it). Collect PROGRESS.md
   entries added since that date.

3. **Infer from PROGRESS.md ordering** (last resort)
   If neither signal exists, take the entries at the top of PROGRESS.md that are
   clearly from this session's conversation, and stop when you reach entries from
   a prior session.

### Check for an existing session name

Read the `**Session name:**` field from CONTEXT_SNAPSHOT.md (the previous
snapshot, before this /wrap rewrites it).

- **If blank / absent:** suggest a fresh `/rename` covering all this session's work.
- **If already set:** the session was named in a prior /wrap or by the user directly.
  Suggest **appending** new work to the existing name rather than replacing it:

  > **Session already named:** `fix step accordion layout #184`
  > **New work this wrap:** `feat custom-permissions #152`
  > **Updated suggestion:** `/rename fix step accordion layout #184 | feat custom-permissions #152`

### Build the name

For each meaningful unit of work (PR merged, task completed, significant fix shipped):
- **type** — git commit type: `fix`, `feat`, `chore`, `refactor`, `devops`, `docs`, `test`
- **short-desc** — 3–6 words that identify the work at a glance
- **#N** — PR or issue number; omit if none

Combine with ` | `. Keep under ~100 characters — truncate from the right by
dropping whole segments, never mid-word.

### Examples

```
fix step accordion layout #184 | fix h3.steps remaining partials #186
feat custom-permissions per-post levels #152 | fix picker regressions #150
devops cypress ci speedup #170 | devops ci cleanup #171
chore upgrade next to 14.2.1 | fix null user on profile fetch #88
```

### Output

> **Suggested session name:**
> `/rename fix step accordion layout #184 | fix h3.steps remaining partials #186`

After the user runs `/rename`, **update the `**Session name:**` field in
`.rig/memory/CONTEXT_SNAPSHOT.md`** to match. This is how future /wrap calls
detect an existing name and suggest appends instead of replacements.

If nothing meaningful shipped this session (pure exploration, no PRs, no
completions), skip this step silently.

---

## Notes

- `.rig/memory/CONTEXT_SNAPSHOT.md` is gitignored — it lives on disk only, never committed
- `.rig/memory/PROGRESS_archive.md` and `.rig/memory/ERRORS_archive.md` are gitignored — full history on disk, not in the repo
- Always **overwrite** the snapshot, never append to it; it represents current state, not history
- History belongs in `.rig/memory/PROGRESS.md` (recent) and `PROGRESS_archive.md` (older); same pattern for `ERRORS.md` / `ERRORS_archive.md`
- If a task is in progress but not done, note its exact state in the snapshot so the next session can resume without re-reading the whole conversation
