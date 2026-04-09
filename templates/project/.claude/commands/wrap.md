# Command: /wrap

Trigger this command before ending a session or when approaching a context limit.

## What this does

Performs the session-end housekeeping that prevents state loss between sessions:

1. Writes (overwrites) `memory/CONTEXT_SNAPSHOT.md` with full current project state
2. Ensures `memory/PROGRESS.md` is up to date — expands any auto-stubbed entries
3. Checks `memory/ERRORS.md` — prompts you to log anything unexpected from this session
4. Reports what's in `tasks/active/` so you know what's in flight
5. Surfaces the next priority from `tasks/backlog/` and asks: "What's next?"

## Usage

```
/wrap
```

Run this:
- Before closing Claude Code for the day
- When the conversation is getting long and you want a clean handoff point
- Before switching to a different task or project
- Any time you want to ensure a future session can pick up exactly where you left off

## Notes

- `CONTEXT_SNAPSHOT.md` is gitignored — it lives on disk only, never committed
- Always **overwrite** the snapshot, never append to it; it represents current state, not history
- History belongs in `PROGRESS.md`; the snapshot is purely for session continuity
- If a task is in progress but not done, note its exact state in the snapshot so the next session can resume without re-reading the whole conversation
