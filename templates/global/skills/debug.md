# Skill: debug

> Triggered by: "why is this broken"
> Installed at: `~/.claude/skills/debug.md`

When asked why something is broken, follow this process exactly.
Do not skip steps. Do not fix before understanding.

---

## Steps

1. **Read the error in full** before forming any hypothesis. Don't skim.
2. **State your hypothesis explicitly** — what do you think is wrong and why?
   Do this before looking at any code.
3. **Identify the smallest reproduction case.** Can you isolate the failure
   to a single function, input, or condition?
4. **Read the relevant code.** Check what inputs are actually arriving
   vs. what you assumed. Verify your hypothesis against the actual code.
5. **Make the smallest possible fix.** Do not refactor while fixing.
6. **Verify** the fix resolves the original symptom without introducing regressions.
7. **Log it** in `memory/ERRORS.md` using the standard format.

---

## Rules

- Never guess and patch. Diagnose first, fix second.
- If you cannot reproduce the bug, say so — don't invent a fix for a phantom.
- If the fix requires a larger refactor, apply a minimal patch first, then open
  a separate task for the refactor.
- Never fix more than one bug per task unless they share the same root cause.

---

## ERRORS.md entry format

```markdown
## [YYYY-MM-DD] — [Short title]

**Symptom**: What was observed / what broke
**Root cause**: What was actually wrong
**Fix**: What change resolved it
**Watch for**: Related areas that could have the same issue
```
