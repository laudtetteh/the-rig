# Skill: code-review

> Triggered by: "review this"
> Installed at: `~/.claude/skills/code-review.md`

When asked to review code, follow this process.

---

## Steps

1. **Read the full diff or file** — don't skim. Understand the intent before evaluating.
2. **Categorize findings by severity** before reporting:
   - **Blocker**: correctness bug, security issue, data loss risk, broken contract
   - **Warning**: performance problem, bad pattern, missing error handling, tech debt
   - **Suggestion**: naming, style, minor improvement (optional to address)
3. **Report blockers first**, always. Never bury them under suggestions.
4. **For each finding**, cite the specific line(s) and explain *why it matters* —
   not just what it is.
5. **If the code is good, say so explicitly.** Don't manufacture feedback.

---

## Rules

- Don't suggest rewrites for stylistic preference alone.
- Don't flag things the linter or formatter already catches — assume they run in CI.
- Do flag anything that will cause problems at scale, under failure conditions,
  or when requirements change.
- If a pattern is repeated across the diff, flag it once with a note that it
  appears multiple times — don't repeat the finding for each occurrence.

---

## Output format

```
### Blockers
- [file:line] Description of issue and why it's critical

### Warnings
- [file:line] Description and suggested fix

### Suggestions
- [file:line] Optional improvement

### Overall
One sentence verdict.
```

If there are no blockers, say so at the top before listing warnings.
