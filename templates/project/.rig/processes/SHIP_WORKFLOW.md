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
- [ ] No debug statements left in code (`console.log`, `var_dump`, `pdb.set_trace`, etc.)
      *(the pre-commit hook will also catch these automatically — this is a manual pre-check)*
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

## Step 2.5 — Pause for local testing

**Stop. Do not commit yet.**

Ask the user:
> "Ready to commit. Test the changes locally, then say **'commit approved'**
> (or 'ship it', 'lgtm', 'go') and I'll proceed."

Wait for one of those trigger phrases (or equivalent clear confirmation).
This step is **non-negotiable** — it cannot be skipped regardless of autonomy
level or how confident the agent is in the changes.

---

## Step 3 — Branch safety check

Before committing, verify you are on a suitable branch:

```bash
git branch --show-current
git status --short
```

**If you are on `main` or `master`:** do not commit. Say:
> "You're on `main` — I can't commit directly here. Which branch should I use?
> I can create `feat/[slug]` off main, or use an existing branch."
Wait for the user's answer before proceeding.

**If you are on any other branch:** proceed. Briefly confirm: `"Branch: [name] — looks good."`

**If there are untracked or modified files outside the task scope** (shown by `git status`):
surface them and ask whether to stage, stash, or ignore before continuing.

---

## Step 4 — Commit

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

## Step 5 — Update memory

In this order:

1. **Verify the task file reflects reality** before moving it:
   - `## Done notes` must describe what was actually built — not a restatement of the plan
   - If scope or approach changed during execution, it must be captured here
   - `## Approach` stays as the original plan (historical intent); deviations belong in `## Done notes`

2. Move task file from `.rig/tasks/active/` → `.rig/tasks/done/`

3. Update `.rig/memory/PROGRESS.md` — add entry at top with what actually shipped
   (if scope changed from the plan, the PROGRESS entry reflects the actual outcome)

4. Overwrite `.rig/memory/CONTEXT_SNAPSHOT.md` — full current state, never delete

5. If anything surprised you, log it in `.rig/memory/ERRORS.md`

6. If anything about The Rig's workflow was missing or felt wrong, log it in `.rig/memory/RIG_GAPS.md`

7. **Post a closing comment on the GitHub Issue:**
   ```bash
   gh issue comment [N] --body "Implemented in PR #[M].

   Actual scope: [one sentence on what was actually built]
   Deviations: [any changes from the original issue description, or 'none']"
   ```
   This is especially important when scope changed — the issue description captures the original
   intent; the comment captures what was actually delivered.

---

## Step 6 — Open the PR

**The PR body must describe what was actually built — not the original plan.**
If scope changed during implementation, the PR body should note it explicitly. Reviewers
read the PR description to understand what landed, not what was intended.

**First, check for a PR template:**

```bash
cat .github/pull_request_template.md 2>/dev/null
```

If a template exists, fill in **every section** of it. Do not skip sections or
leave placeholders. If no template exists, use this default:

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
```

Then create the PR:

```bash
gh pr create --title "..." --body-file /tmp/pr-body.md --base main \
  --label "type: [type]" --label "area: [area]"
```

**Apply labels at creation time.** Never retroactively. Required labels:
- One `type:` label matching the commit type
- One or more `area:` labels for the layers touched

---

## Step 7 — Housekeeping commit (if needed)

If the memory updates and task file move were not included in the implementation commit,
make a follow-up housekeeping commit on the same branch:

```bash
git add .rig/memory/PROGRESS.md .rig/tasks/done/TASK_[name].md
git commit -m "chore: post-task housekeeping [#N]"
```

This commit goes on the same PR branch before the PR is merged.
