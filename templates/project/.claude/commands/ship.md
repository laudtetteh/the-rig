# Command: /ship

Trigger this command when you are ready to commit and close out a task.

This is a **sequential hard gate** — each step must be completed and confirmed
before the next one executes. Do not skip steps, combine steps, or proceed past
a failure without surfacing it.

> **RIG_DIR resolution (stealth mode):** Before reading or writing any `.rig/` path,
> resolve where `.rig/` actually lives. If `.rigpath` exists at the project root, read
> it — it contains the absolute path to the external `.rig/` directory.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> if [[ -f "$REPO/.rigpath" ]]; then
>   RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
> else
>   RIG_DIR="$REPO/.rig"
> fi
> ```
>
> Substitute `$RIG_DIR` for `.rig/` in every step below.

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

First, read `issue-tracking:` from `CLAUDE.md`.

**If `issue-tracking: none`:** skip this step entirely — proceed to Step 3.

**If `issue-tracking: github`** (or field absent — default):

Read the task file's `**GitHub issue**:` field.

- If it contains a real issue number (e.g. `#12`): state it and proceed.
- If it is `N/A (issue-tracking: none)`: proceed — the project setting was already applied.
- If it is empty or a placeholder: **stop.**
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

Do not proceed to Step 3 until a valid issue number is confirmed (or `issue-tracking: none` is set).

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

If the branch needs renaming, use this helper. It detects a case-only change using
both a bytewise comparison and an ASCII case-folded comparison. Only that special
case goes through a collision-checked temporary ref; all other renames use Git's
normal conflict handling.

```bash
# branch-case-rename:start
rename_branch_case_safe() {
  local desired_branch="$1"
  local current_branch current_folded desired_folded slug temp_base temp_branch suffix rename_status

  current_branch=$(git branch --show-current) || return
  if [[ -z "$current_branch" ]]; then
    echo "Cannot rename a detached HEAD." >&2
    return 1
  fi

  current_folded=$(printf '%s' "$current_branch" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  desired_folded=$(printf '%s' "$desired_branch" | LC_ALL=C tr '[:upper:]' '[:lower:]')

  if [[ "$current_branch" != "$desired_branch" && "$current_folded" == "$desired_folded" ]]; then
    slug=$(printf '%s' "$current_branch" | LC_ALL=C tr -c '[:alnum:]._- ' '-' | tr ' ' '-')
    temp_base="tmp/${slug}-rename"
    temp_branch="$temp_base"
    suffix=0
    while git show-ref --verify --quiet "refs/heads/$temp_branch"; do
      suffix=$((suffix + 1))
      temp_branch="${temp_base}-${suffix}"
    done

    git branch -m "$temp_branch" || return
    rename_status=0
    git branch -m "$desired_branch" || rename_status=$?
    if [[ "$rename_status" -ne 0 ]]; then
      if git branch -m "$current_branch"; then
        echo "Rename to '$desired_branch' failed; restored '$current_branch'." >&2
      else
        echo "Rename to '$desired_branch' failed and rollback failed; branch remains '$temp_branch'." >&2
      fi
      return "$rename_status"
    fi
    return 0
  fi

  git branch -m "$desired_branch"
}
# branch-case-rename:end

rename_branch_case_safe "[desired-branch-name]"
```

If it fails, stop and surface the error. Do not remove a reported temporary ref;
it is retained only when rollback failed and protects the user's branch contents.

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

## Step 3.8 — Pre-commit cleanup

Before presenting the checklist, actively clean up the diff. Do not ask permission —
this cleanup is always required.

**3.8a — Remove debug statements.** Scan staged and unstaged changes for:
- `console.log`, `console.debug`, `console.warn`, `console.error` (JavaScript/TypeScript)
- `print(`, `pprint(`, `logging.debug(` used as one-off debug output (Python)
- `debugger;` statements
- `# DEBUG`, `# TEMP`, `// DEBUG`, `// TEMP` inline comments
- `dd(`, `dump(`, `ray(` (PHP debug helpers)
- Any other obvious debug instrumentation added during development

For each one found: remove it, stage the change, note it in your next message.
If unsure whether a statement is intentional debug output or production logging,
leave it and flag it in Step 4 for the user to decide.

**3.8b — Run the linter** (if one is configured for this project):
```bash
# Read test-command from CLAUDE.md, or try common linters:
# npm run lint / eslint . / ruff check . / flake8 / shellcheck
```
If the linter fails: fix the issues before continuing. Do not proceed to Step 4
with failing lint. If no linter is configured, note it and skip.

**3.8c — Run tests** (conditional):
Read the active task file's `## Testing` field.
- **`Required: yes`**: run the test suite now. If tests fail: fix them before
  continuing. Do not proceed to Step 4 with failing tests.
- **`Required: optional`**: run tests if the command is fast (< 60s); report results.
- **`Required: no`** or field absent: skip.

```bash
# Use the test command from CLAUDE.md or the project's standard:
# npm test / pytest / bats tests/ / etc.
```

Report what was cleaned, what linting found, and test results (pass/fail/skip)
in a single summary line before continuing.

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

## Step 4.5 — Code review (optional)

Ask the user:
> "Run the code-reviewer agent on this diff? [yes / skip]"

If they say yes (or "y"): invoke the `code-reviewer` agent with the staged diff
(`git diff --cached`). Report all **Blocking** findings and stop the ship flow
until they are resolved. **Advisory** findings are reported but do not block.

If they say skip: proceed to Step 4.8.

---

## Step 4.8 — Docs and memory freshness gate

**Check 1 — PROGRESS.md stubs (blocking)**

Run:
```bash
grep -c "Auto-logged by post-tool hook" "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null || echo 0
```

If the count is > 0: stop and say:
> "PROGRESS.md has unexpanded auto-stubs. Run `/wrap` to expand them before shipping."
Do not continue until the user resolves this.

**Check 2 — Feature doc overlap (advisory, only if feature docs are installed)**

Only run this check if `$DOCS_DIR/features/README.md` exists (where `$DOCS_DIR` is
`$RIG_DIR/docs` for stealth/external installs, `$REPO/docs` otherwise).

List the files changed in this PR (`git diff --name-only HEAD~1..HEAD 2>/dev/null || git diff --cached --name-only`).
Cross-reference against `$DOCS_DIR/features/README.md` — if any changed file's path
contains a slug listed in the feature doc index, report:
> "Advisory: changed files overlap with documented feature(s): [list]. Run
> `/refresh-feature-doc <feature>` after merging to keep docs current."

This is advisory only — it does not block the ship flow.

**Check 3 — docs/INDEX.md freshness (advisory, only if INDEX.md exists)**

If `$DOCS_DIR/INDEX.md` exists: check if any files in `$DOCS_DIR/` were added or
removed by this PR that are not reflected in the index. If so, report:
> "Advisory: docs/INDEX.md may need updating — new or removed files detected in docs/."

This is advisory only.

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

## Step 9 — Open or update the PR

**The PR body must describe what was actually built — not the original plan.**
If scope changed during implementation, note it explicitly. Reviewers read the PR
description to understand what landed, not what was intended.

**First: check if a PR already exists for this branch.**

```bash
CURRENT_BRANCH=$(git branch --show-current)
EXISTING_PR=$(gh pr list --head "$CURRENT_BRANCH" --json number,title,url --jq '.[0]' 2>/dev/null || echo "")
```

**If a PR already exists:**

Before presenting options, compare the branch commits against the existing PR description
to surface what may be missing:

```bash
PR_NUMBER=$(echo "$EXISTING_PR" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])" 2>/dev/null || echo "")
PR_BODY=$(gh pr view "$PR_NUMBER" --json body -q .body 2>/dev/null || echo "")
BASE=$(grep "^base-branch:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
BASE="${BASE:-main}"
COMMITS=$(git log "origin/${BASE}"..HEAD --format="%s" 2>/dev/null)
```

For each commit subject (skip housekeeping types: `chore(memory)`, `chore(post-merge)`,
`chore(release)`, `chore(rig)`), check case-insensitively whether it appears in the PR body.
Collect any that don't match.

Then display:

> "PR #[N] already exists for this branch: [title]
> [URL]
>
> [If stale commits found:]
> [N] commit(s) not reflected in the description:
>   - type(scope): commit subject
>   - ...
>
> Options:
> - **[u] Update** — revise title, body, and labels to reflect all work on this branch
> - **[k] Keep as-is** — the existing PR description is accurate"

If user chooses **[u]**:
1. Show the current PR title and body (run `gh pr view [N] --json title,body`)
2. Draft the updated title and body based on ALL work on this branch (not just the latest commit)
3. Show the proposed changes and ask for approval
4. Run:
   ```bash
   gh pr edit [N] --title "[updated title]" --body-file /tmp/ship-pr-body.md
   ```
5. Check labels: `gh pr view [N] --json labels` — add any missing labels for new work areas
6. Verify the `Closes #[issue]` line covers all linked issues for the full scope of work

If user chooses **[k]**: skip to Notes. Done.

**If no PR exists:** continue with template detection and PR creation below.

---

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
