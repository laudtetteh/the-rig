# SHIP_WORKFLOW

> Follow this process before every commit that closes a task and before every PR.
> Skipping steps here is how bugs, secrets, and broken builds reach production.

---

## When to follow this workflow

- When you are ready to commit and close a task
- When opening a pull request

---

## Step 0 — Create the GitHub issue first

**Before writing any code, create the GitHub issue.**

The commit message must reference the issue number: `feat(scope): description [#N]`.
If you create the issue after the commit, you cannot reference it honestly — the
number belongs in the commit, not as a retroactive edit.

**First, verify the labels you need exist:**

```bash
gh label list --repo <owner>/<repo>
```

If `type: feat`, `type: fix`, `type: chore`, etc. are missing, create them before
proceeding — `gh issue create` with an unknown label silently drops it or errors:

```bash
gh label create "type: feat" --color "#0075ca" --description "New feature"
gh label create "type: fix"  --color "#d73a4a" --description "Bug fix"
gh label create "type: chore" --color "#e4e669" --description "Tooling and maintenance"
```

Then create the issue:

```bash
gh issue create --title "..." --body-file /tmp/issue-body.md --label "type: feat"
```

Note the issue number. It goes in every commit on this branch.

---

## Step 1 — Pre-ship checklist

Work through this list before staging anything:

- [ ] All acceptance criteria in the task file are met
- [ ] No `console.log`, `print()`, or other debug statements left in code
- [ ] No commented-out code (we have git history)
- [ ] No hardcoded secrets, tokens, or credentials
- [ ] Error cases handled — not just the happy path
- [ ] If the PR touches `Dockerfile`, `requirements.txt`, `package.json`, or the service layer:
      in-container verification has been run per `.rig/rules/verification.md`
- [ ] After any Docker verification step: `git status --short` checked — volume mounts
      can generate untracked files that must be committed or gitignored

---

## Step 2 — Self-review

Read the full diff. Ask:

- Does this do what the task asked and **nothing more**?
- Is there anything that could fail in production that didn't fail locally?
- Are there side effects on other features?
- Would a reviewer understand why each change was made?

If any answer gives you pause, fix it before committing.

---

## Step 3 — Commit

Use conventional commit format:

```
type(scope): short description [#N]

Body: explain WHY, not what. The diff shows what.
```

Valid types: `feat` | `fix` | `refactor` | `test` | `docs` | `chore` | `style` | `perf` | `devops`

Write the commit message to a temp file to avoid shell quoting issues:

```bash
cat > /tmp/commit-msg.txt << 'EOF'
feat(scope): description [#N]

Body explaining the why.
EOF
git commit -F /tmp/commit-msg.txt
```

---

## Step 4 — Update memory

In this order:

1. Move task file from `.rig/tasks/active/` → `.rig/tasks/done/`
2. Update `.rig/memory/PROGRESS.md` — add entry at top with what shipped
3. Overwrite `.rig/memory/CONTEXT_SNAPSHOT.md` — full current state, never delete
4. If anything surprised you during the task, log it in `.rig/memory/ERRORS.md`

---

## Step 5 — Open the PR

Use the PR template **exactly**. Five sections: Summary, Changes, Closes, Test plan, Notes.

```bash
cat > /tmp/pr-body.md << 'EOF'
## Summary

## Changes
-

## Closes
Closes #N

## Test plan

## Notes
EOF
gh pr create --title "..." --body-file /tmp/pr-body.md --base main --label "type: feat"
```

**Apply labels at creation time.** Never retroactively. Required labels:
- One `type:` label matching the commit type
- One or more `area:` labels for the layers touched

---

## Step 6 — Housekeeping commit (if needed)

If the memory updates and task file move were not included in the implementation commit,
make a follow-up housekeeping commit on the same branch:

```bash
git add .rig/memory/PROGRESS.md .rig/tasks/done/TASK_[name].md
git commit -m "chore: post-task housekeeping [#N]"
```

This commit goes on the same PR branch before the PR is merged.
