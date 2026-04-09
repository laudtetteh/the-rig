# Skill: refactor

> Triggered by: "refactor this to…"
> Installed at: `~/.claude/skills/refactor.md`

When asked to refactor code, follow this process.

---

## Steps

1. **Read the target file(s) in full** before touching anything.
2. **Identify the specific problem**: duplication, complexity, naming, structure, or performance.
   If the problem isn't stated, ask — don't assume.
3. **State the refactor plan** in 2–3 bullet points before making changes.
   Wait for confirmation.
4. **Make changes incrementally** — one concern at a time.
5. **Preserve all existing behaviour** unless explicitly told otherwise.
6. **Confirm what changed and what didn't** after completing.

---

## Rules

- Do not change logic while refactoring. Separate concerns.
- Do not rename things unless naming is the stated problem.
- Do not extract abstractions unless the pattern appears 3+ times (rule of three).
- If the refactor reveals a deeper design issue, flag it — don't fix it silently.
- If a function works and is readable, leave it alone. "Could be cleaner" is not a reason.

---

## Output format

- Show the full new file or a clear before/after diff — not partial snippets.
- Include a one-line comment above each major change describing what it achieves.
