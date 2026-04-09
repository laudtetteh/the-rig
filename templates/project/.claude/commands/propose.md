# Command: /propose

Use this command when you believe a change to The Rig's governance files would
improve the system. Governance files — `processes/`, `rules/`, `.husky/`, `CLAUDE.md`,
and `.claude/hooks/` — are protected from direct writes by `pre-tool.sh`.

This command is the approved path for proposing changes to them.

---

## What this does

Instead of modifying a governance file directly, the agent:

1. Writes the proposed change to `/tmp/rig-proposal-[name].md`
2. Shows you the full before/after diff in the proposal document
3. Explains why the change is warranted (symptom, pattern, or lesson)
4. Waits for your explicit approval before anything is touched
5. On approval: applies the change and logs it in `memory/ERRORS.md` or
   `memory/PROGRESS.md` as appropriate

---

## Usage

```
/propose
```

Claude will ask:
- Which file needs changing?
- What is the proposed change? (show the exact diff)
- Why is this change warranted? (what failure or pattern prompted it?)

Then it writes the proposal to `/tmp/rig-proposal-[name].md` and presents it
for your review. **No governance file is touched until you say "apply it".**

---

## When to use it

Use `/propose` when you've noticed:
- A step in a workflow that consistently gets skipped or causes confusion
- A rule that's either too strict or not strict enough for this project
- A hook behaviour that needs adjustment
- A pattern in `memory/ERRORS.md` that should be codified as a rule

---

## When NOT to use it

Do not use `/propose` for:
- Application code changes — edit those directly
- Memory files (`PROGRESS.md`, `ERRORS.md`, `CONTEXT_SNAPSHOT.md`) — update those directly
- Task files — manage those directly
- Project documentation (`docs/`, `README.md`) — edit those directly

Only governance files require the proposal gate.

---

## Notes

This is how The Rig improves itself: not silently, not unilaterally, but through
a deliberate proposal → review → apply cycle that keeps the human in the loop on
any change to how the system functions.
