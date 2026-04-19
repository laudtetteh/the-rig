# Command: /wrap

Trigger this command before ending a session or when approaching a context limit.

## What this does

Performs the session-end housekeeping that prevents state loss between sessions:

1. Writes (overwrites) `.rig/memory/CONTEXT_SNAPSHOT.md` with full current project state
2. Ensures `.rig/memory/PROGRESS.md` is up to date — expands any auto-stubbed entries
3. **Trims `.rig/memory/PROGRESS.md`** if it has grown beyond 20 entries (see Trim step below)
4. Checks `.rig/memory/ERRORS.md` — prompts you to log anything unexpected from this session
5. Reports what's in `.rig/tasks/active/` so you know what's in flight
6. Surfaces the next priority from `.rig/tasks/backlog/` and asks: "What's next?"

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

## Notes

- `.rig/memory/CONTEXT_SNAPSHOT.md` is gitignored — it lives on disk only, never committed
- `.rig/memory/PROGRESS_archive.md` is also gitignored — full history on disk, not in the repo
- Always **overwrite** the snapshot, never append to it; it represents current state, not history
- History belongs in `.rig/memory/PROGRESS.md` (recent) and `.rig/memory/PROGRESS_archive.md` (older); the snapshot is for session continuity only
- If a task is in progress but not done, note its exact state in the snapshot so the next session can resume without re-reading the whole conversation
