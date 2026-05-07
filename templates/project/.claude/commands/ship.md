# Command: /ship

Trigger this command when you are ready to commit and close out a task.

This is a **sequential hard gate** — each step must be completed and confirmed
before the next one executes. Do not skip steps, combine steps, or proceed past
a failure without surfacing it.

---

## Step 1 — Identify the task

Read `.rig/tasks/active/`. If there is exactly one task file, confirm it.
If there are multiple, ask the user which task is being shipped. If there are
none, stop and say: "No active task found. Move a task to `.rig/tasks/active/`
before shipping."

State clearly:
> "Shipping: **[task name]** — [one-line goal from the task file]"

Wait for the user to confirm this is the right task before continuing.

---

## Step 2 — Confirm the GitHub issue

Read the task file's `**GitHub issue**:` field.

- If it contains a real issue number (e.g. `#12`): state it and proceed.
- If it is empty or still a placeholder: **stop.**
  Say: "No GitHub issue linked. Per SHIP_WORKFLOW Step 0, the issue must exist
  before committing. Create the issue first, then update the task file."

If you need to create an issue now, check for issue templates first:

```bash
ls .github/ISSUE_TEMPLATE/ 2>/dev/null
```

If templates exist, select the appropriate one (`feature.md`, `bug.md`, etc.),
strip the YAML frontmatter (lines starting with `---`, `name:`, `about:`, `title:`,
`labels:`, `assignees:`), and use the remaining content as the issue body. **Never
use a freeform issue body when an issue template exists.**

Do not proceed to Step 3 until a valid issue number is confirmed.

---

## Step 3 — Verify labels

Run:
```bash
gh label list --repo $(gh repo view --json nameWithOwner -q .nameWithOwner)
```

Display the available labels. Determine which `type:` label matches this
commit type (`feat`, `fix`, `chore`, `refactor`, `docs`, `devops`, etc.) and
which `area:` labels apply.

If the required labels do not exist, offer to create them before continuing:
```bash
gh label create "type: feat" --color "#0e8a16" --description "New functionality"
```

State which labels will be applied to the PR. Wait for confirmation before
continuing.

---

## Step 3.5 — Branch check

Verify the repo is in a clean state before committing.

```bash
git branch --show-current
git status --short
```

**If on `main` or `master`:** stop — you cannot commit directly here. Ask:
> "You're on `main`. Which branch should this go on? I can create `[type/slug]` off `[BASE]`."
Wait for the user's answer. Before creating the branch, run the stale-main check below.

**Read the configured base branch:**
```bash
BASE=$(grep "^base-branch:" CLAUDE.md 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
BASE="${BASE:-main}"
```

**Stale-main check — run before creating a new branch or opening a PR:**
```bash
git fetch origin "$BASE" --quiet 2>/dev/null || true
AHEAD=$(git rev-list HEAD..origin/"$BASE" --count 2>/dev/null || echo 0)
```

If `AHEAD > 0`, the base branch has new commits your branch doesn't have:

- **Low/Medium autonomy:**
  > "`origin/$BASE` is $AHEAD commit(s) ahead. Rebase before opening the PR? [yes / no]"
  If yes: `git rebase origin/"$BASE"`. Fix any conflicts before proceeding.

- **High autonomy:** auto-rebase silently:
  ```bash
  git rebase origin/"$BASE"
  ```
  Note the rebase in your next message.

If `git fetch` fails (no network, no remote configured): skip and note it.

**Branch creation — Low/Medium autonomy only:**
If creating a new branch right now, confirm the base before running `git checkout -b`:
> "I'll create `[branch-name]` off `$BASE`. Is that the right base?"
Wait for confirmation. High autonomy: state the base and proceed immediately.

---

## Step 4 — Pre-ship checklist

Work through the following. Report the result of each check:

- [ ] All acceptance criteria in the task file are met
- [ ] No `console.log`, `print()`, or other debug statements left in code
- [ ] No commented-out code
- [ ] No hardcoded secrets, tokens, or credentials
- [ ] Error cases handled — not just the happy path
- [ ] If `Dockerfile`, `requirements.txt`, `package.json`, or service layer was
      touched: in-container verification has been run per `.rig/rules/verification.md`
- [ ] `git status --short` checked for untracked files from Docker volume mounts

If any item cannot be confirmed, stop and resolve it before continuing.

---

## Step 5 — Pause for local testing

**Stop here.** Do not commit yet.

Say to the user:
> "Ready to commit. Test the changes locally, then say **'commit approved'**
> (or 'ship it', 'lgtm', 'go') and I'll proceed."

Wait for one of those explicit trigger phrases (or equivalent clear confirmation).
Do not proceed if the response is ambiguous. This step cannot be skipped
regardless of autonomy level.

---

## Step 6 — Show the commit message and wait for go-ahead

Compose the commit message in conventional format:

```
type(scope): short description [#N]

Body: explain WHY, not what. The diff shows what.
```

Display it. Then ask:
> "Commit with this message? [yes / edit]"

If the user says "edit", accept the revised message. Do not commit until the
message is explicitly approved.

---

## Step 7 — Commit

The user confirmed local testing at Step 5 and approved the commit message at Step 6.
That constitutes explicit go-ahead — create the commit sentinel, then commit:

```bash
# Authorise the commit (pre-tool.sh requires this sentinel)
touch "$(git rev-parse --show-toplevel)/.rig/memory/.rig-commit-ok" 2>/dev/null || \
  touch "${RIG_DIR:-$(git rev-parse --show-toplevel)/.rig}/memory/.rig-commit-ok"

cat > /tmp/ship-commit-msg.txt << 'EOF'
[approved commit message]
EOF
git commit -F /tmp/ship-commit-msg.txt
```

post-tool.sh deletes the sentinel automatically after the commit lands.

Report the commit hash on success.

---

## Step 8 — Post-commit housekeeping

In this order:

1. **Verify the task file reflects reality** before moving it:
   - `## Done notes` must describe what was actually built — not a restatement of the plan
   - Required fields: **What was built** / **Deviations from plan** / **Actual files touched** / **Follow-ups opened**
   - If scope or approach changed during execution, capture it in `## Done notes`
   - `## Approach` stays as the original plan (historical intent); deviations belong in `## Done notes`
2. Move the task file: `.rig/tasks/active/TASK_[name].md` → `.rig/tasks/done/`
3. Update `.rig/memory/PROGRESS.md` — add a full entry at the top (not a stub); if scope changed, the entry reflects the actual outcome
4. Overwrite `.rig/memory/CONTEXT_SNAPSHOT.md` with current project state
5. If anything surprised you, log it in `.rig/memory/ERRORS.md`
6. If anything about The Rig's workflow was missing or felt wrong, log it in `.rig/memory/RIG_GAPS.md`
7. **Post a closing comment on the GitHub Issue:**
   ```bash
   gh issue comment [N] --body "Implemented in PR #[M].

   Actual scope: [one sentence on what was actually built]
   Deviations: [any changes from the original issue description, or 'none']"
   ```
   This is required when scope changed; recommended always.

---

## Step 9 — Open the PR

**The PR body must describe what was actually built — not the original plan.**
If scope changed during implementation, note it explicitly. Reviewers read the PR
description to understand what landed, not what was intended.

**Template detection — this is a hard gate:**

```bash
# Check both common paths (GitHub accepts both)
cat .github/pull_request_template.md 2>/dev/null || \
cat .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null || \
cat PULL_REQUEST_TEMPLATE.md 2>/dev/null || echo ""
```

**If a PR template is found: you MUST use it. Do not write a freeform PR body.**
Fill in every section of the template — do not leave placeholders, skip sections,
or collapse multiple sections into one. If a section does not apply, write "N/A"
or delete it. Never silently ignore the template.

If no template exists, use this fallback:
```
## Summary

## Changes
-

## Closes
Closes #N

## Test plan

## Notes
```

Then create the PR:

```bash
cat > /tmp/ship-pr-body.md << 'EOF'
[filled-in template or fallback]
EOF
gh pr create \
  --title "type(scope): description" \
  --body-file /tmp/ship-pr-body.md \
  --base [BASE_BRANCH] \
  --label "type: [type]" \
  --label "area: [area]"
```

Report the PR URL.

---

## Post-batch audit (after every group of related PRs)

After the last PR in a batch of 2+ related changes opens (or merges), run this checklist:

- [ ] Tests pass on main
- [ ] CLI help text matches new behavior
- [ ] `README.md` and `docs/how-it-works.md` reflect any new commands or behavior
- [ ] `CHANGELOG.md` has entries for all PRs in the batch
- [ ] Inline comments are consistent with what the code actually does
- [ ] Run `/wrap` to write `CONTEXT_SNAPSHOT.md` before starting the next group

This is not needed after every single commit — it's a batch-level checkpoint.
See `SHIP_WORKFLOW.md` Post-batch audit for full details.

---

## Notes

- Steps 1–6 are **gates** — any failure stops the sequence entirely.
- The GitHub issue (Step 2) must exist before `/ship` is run, not after.
- Labels (Step 3) must be verified against the actual repo — never assumed.
- The local testing pause (Step 5) is non-negotiable regardless of autonomy level.
- The branch check (Step 3.5) is also a gate — never commit directly to main.
- If the task has multiple commits, summarise all changes in the PR body.
- The task file is moved to `.rig/tasks/done/` only after a successful commit (Step 8).
- The PR body (Step 9) must reflect what was actually built — not the original plan.
