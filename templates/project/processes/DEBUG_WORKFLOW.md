# DEBUG_WORKFLOW

> Follow this when something is broken and the cause is not obvious.
> The most common debugging mistake is fixing before understanding.
> This workflow forces understanding first.

---

## When to follow this workflow

- When a test fails and you don't immediately know why
- When runtime behavior doesn't match expectations
- When the user says "why is this broken" or "this isn't working"

---

## Step 1 — Reproduce first

**Do not touch any code until you can reproduce the bug reliably.**

If you cannot reproduce it:
- Describe what you tried to the user
- Ask for additional context (environment, steps, error output)
- Do not invent a fix for a phantom bug

A bug you can't reproduce is a hypothesis, not a bug.

---

## Step 2 — Isolate

Narrow down where the problem lives:

- Which layer: UI / API / service / database / external dependency?
- Which module or function?
- Does it happen always, or only under specific conditions?
- What changed recently that could have caused this?

**State your hypothesis explicitly before looking at code.**

Saying "I think X is happening because Y" commits you to a theory and makes it
easier to notice when the evidence contradicts it.

---

## Step 3 — Inspect, don't guess

Read the relevant code. Verify:

- What inputs are actually arriving (add temporary logging if needed, remove before committing)
- What the code is actually doing vs. what you assumed
- Whether the bug is in this code or in something it calls

Do not form a fix until you have confirmed the root cause by reading the code.

---

## Step 4 — Fix

Make the **smallest possible change** that resolves the confirmed root cause.

Rules:
- Do not refactor while fixing — one concern at a time
- Do not fix unrelated issues discovered during investigation — log them in `memory/ERRORS.md`
- If the proper fix requires a larger refactor, apply a minimal patch first, then open a
  separate task for the refactor

---

## Step 5 — Verify the fix

- Reproduce the original failure scenario — confirm the bug is gone
- Run related tests
- Check for regressions in adjacent functionality
- If you added temporary logging in Step 3, remove it now

---

## Step 6 — Log it

Add an entry to `memory/ERRORS.md`:

```markdown
## [YYYY-MM-DD] — [Short title]

**Symptom**: What was observed / what broke
**Root cause**: What was actually wrong
**Fix**: What change resolved it
**Watch for**: Related areas that could have the same issue
```

Every bug logged here is a bug that cannot bite twice.
