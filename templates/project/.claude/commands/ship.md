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
> "Ready to commit. Have you tested the changes locally and confirmed they work
> as expected?"

Wait for explicit confirmation ("yes", "looks good", "go ahead", etc.).
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

Write the approved commit message to `/tmp/ship-commit-msg.txt` and commit:

```bash
cat > /tmp/ship-commit-msg.txt << 'EOF'
[approved commit message]
EOF
git commit -F /tmp/ship-commit-msg.txt
```

Report the commit hash on success.

---

## Step 8 — Post-commit housekeeping

In this order:

1. Move the task file: `.rig/tasks/active/TASK_[name].md` → `.rig/tasks/done/`
2. Update `.rig/memory/PROGRESS.md` — add a full entry at the top (not a stub)
3. Overwrite `.rig/memory/CONTEXT_SNAPSHOT.md` with current project state

---

## Step 9 — Open the PR

Use the project's PR template if one exists at `.github/pull_request_template.md`.
Read it, fill in every section, then:

```bash
cat > /tmp/ship-pr-body.md << 'EOF'
[filled-in PR template]
EOF
gh pr create \
  --title "type(scope): description" \
  --body-file /tmp/ship-pr-body.md \
  --base main \
  --label "type: [type]" \
  --label "area: [area]"
```

Report the PR URL.

---

## Notes

- Steps 1–6 are **gates** — any failure stops the sequence entirely.
- The GitHub issue (Step 2) must exist before `/ship` is run, not after.
- Labels (Step 3) must be verified against the actual repo — never assumed.
- The local testing pause (Step 5) is non-negotiable regardless of autonomy level.
- If the task has multiple commits, summarise all changes in the PR body.
- The task file is moved to `.rig/tasks/done/` only after a successful commit.
