# Command: /rig-propose

Use this command when you believe a change to The Rig's governance files would
improve the system. Governance files — `.rig/processes/`, `.rig/rules/`, `.husky/`,
`CLAUDE.md`, and `.claude/hooks/` — are protected from direct writes by `pre-tool.sh`.

This command is the approved path for proposing changes to them.

Project conventions are different. Current, explicitly approved operating rules
and preferences belong in `.rig/memory/PROJECT_CONVENTIONS.md`, which is
agent-writable. They still require explicit user approval before the agent adds,
removes, or materially changes one. This command does not create a bypass for
governance files and does not apply governance proposals.

---

## What this does

Instead of modifying a governance file directly, the agent:

1. Writes the proposed change to `/tmp/rig-proposal-[name].md`
2. Shows you the full before/after diff in the proposal document
3. Explains why the change is warranted (symptom, pattern, or lesson)
4. Waits for your explicit approval before anything is touched
5. On approval: provides the exact change to apply — **but you apply it**

**Why the agent can't apply it directly:** `pre-tool.sh` blocks writes to all
governance files unconditionally — including during an approved proposal. This is
intentional. The governance system protects itself. The human is always the one who
applies governance changes.

**How to apply after approval:**

Option A — paste in editor:
> Copy the diff from the proposal file and apply it manually in your editor.

Option B — the agent generates a ready-to-paste block:
> After you approve, say "show me the apply block". The agent will output the
> complete file content (not a diff) so you can paste it directly into the file.

After applying: tell the agent it's done. It will log the change in
`.rig/memory/PROGRESS.md` and clean up `/tmp/rig-proposal-[name].md`.

There is no approved-apply helper. Approval does not make a protected path
agent-writable; `pre-tool.sh` continues to block governance writes unconditionally.

---

## Usage

```
/rig-propose
```

Claude will ask:
- Which file needs changing?
- What is the proposed change? (show the exact diff)
- Why is this change warranted? (what failure or pattern prompted it?)

Then it writes the proposal to `/tmp/rig-proposal-[name].md` and presents it
for your review. **No governance file is touched until you say "apply it".**

---

## When to use it

Use `/rig-propose` when you've noticed:
- A step in a workflow that consistently gets skipped or causes confusion
- A rule that's either too strict or not strict enough for this project
- A hook behaviour that needs adjustment
- A pattern in `.rig/memory/ERRORS.md` that should be codified as a rule

---

## When NOT to use it

Do not use `/rig-propose` for:
- Application code changes — edit those directly
- Completed work, failures, session state, or Rig feedback — use `PROGRESS.md`,
  `ERRORS.md`, `CONTEXT_SNAPSHOT.md`, or `RIG_GAPS.md` as appropriate
- A durable project operating rule or preference that the user explicitly
  approves — record the current convention in `PROJECT_CONVENTIONS.md`
- Task files — manage those directly
- Project documentation (`docs/`, `README.md`) — edit those directly

Only governance files require the proposal gate.

Before writing `PROJECT_CONVENTIONS.md`, confirm all of the following:

- The user explicitly approved the exact convention; observed behavior, a
  one-off request, or an agent suggestion is not approval.
- It is a durable current rule or preference, not transient project/session state.
- It contains no secret or sensitive value.
- It does not copy or paraphrase governance policy.
- It states only the current convention. Consequential rationale, alternatives,
  and consequences belong in `DECISIONS.md`.

If any check fails, do not write the convention. Ask for approval when that is
the only missing requirement; otherwise route the content to the correct file.

---

## Notes

This is how The Rig improves itself: not silently, not unilaterally, but through
a deliberate proposal → review → apply cycle that keeps the human in the loop on
any change to how the system functions.
