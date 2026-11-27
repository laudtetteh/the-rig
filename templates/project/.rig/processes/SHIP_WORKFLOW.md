# SHIP_WORKFLOW

> Follow this process before every commit that closes a task and before every PR.
> Skipping steps here is how bugs, secrets, and broken builds reach production.

---

## When to follow this workflow

- When you are ready to commit and close a task
- When opening a pull request

---

## Task inventory gate

Resolve `REPO=$(git rev-parse --show-toplevel)`, run
`"$REPO/bin/rig" task inventory --json`, and take its `rig_dir` field as
`RIG_DIR` before selecting a task. If the state
is `omitted`, stop with "Task lifecycle unavailable: this Rig install
intentionally omitted the task component. Install tasks before shipping."
If the state is `ambiguous` or `ok` is false, stop and report the inventory
`reason` as an error. Only an installed, usable task directory set can have a
valid empty active task list.

---

## Step 0 — Confirm the configured tracker reference

From the project root, run
`python3 bin/rig-tracker-config.py show CLAUDE.md` and use its normalized
`tracker`, `pattern`, and `example` values. Stop on a configuration error.

- **If `tracker` is `none`:** skip this entire step. No tracker reference is
  required in commit messages; continue to Step 1.
- **If `tracker` is neither `github` nor `none`:** read the task's existing
  `**Issue**:` reference; if absent, obtain it from the user before writing
  code. Validate it with
  `python3 bin/rig-tracker-config.py validate-ref CLAUDE.md "REF"`, substituting
  the supplied value for `REF`; ask for a corrected reference if validation
  fails. Record it in the task file and use `[REF]` in commit subjects. Do not
  create a GitHub issue for this mode. Continue to Step 1.
- **If `tracker` is `github`** (the default when absent): follow the GitHub
  issue flow below.

**Before writing any code, obtain the GitHub issue number.** If no issue exists
and the agent is configured to draft one, use the approval gate below.

The commit message must reference the issue number: `feat(scope): description [#N]`.
If you create the issue after the commit, you cannot reference it honestly — the
number belongs in the commit, not as a retroactive edit.

**Check for issue templates first:**

```bash
ls .github/ISSUE_TEMPLATE/ 2>/dev/null
```

If templates exist, choose the appropriate one based on the type of work
(`feature.md` for new features, `bug.md` for fixes, `chore.md` for maintenance).
Strip the YAML frontmatter (everything between the `---` delimiters at the top)
and use the template body as your issue body. **Never use a freeform issue body
when a project issue template exists.**

**First, verify the labels you need exist:**

```bash
gh label list --repo <owner>/<repo>
```

If `type: feat`, `type: fix`, `type: chore`, etc. are missing, draft the
needed label and target repository. **Exact tracker write approval:** show
the complete label name, color, description, and target, then wait for the
user's approval of each individual creation immediately before the command.
Do not treat approval for another label, issue, plan, or ship action as approval
here. If declined, leave the label absent and resolve the label requirement
before proceeding — `gh issue create` with an unknown label silently drops it
or errors:

```bash
gh label create "type: feat" --color "#0075ca" --description "New feature" --repo <owner>/<repo>
gh label create "type: fix"  --color "#d73a4a" --description "Bug fix" --repo <owner>/<repo>
gh label create "type: chore" --color "#e4e669" --description "Tooling and maintenance" --repo <owner>/<repo>
```

Then prepare the issue body and title. **Exact tracker write approval:** show
the target repository, title, complete body, and labels; wait for explicit
approval of this issue creation immediately before `gh issue create`. A
general task or ship approval does not count. If the draft changes, show the
revised action and ask again; if declined, do not file it:

```bash
cat > /tmp/issue-body.md << 'EOF'
[filled-in template body, or freeform if no template exists]
EOF
gh issue create --repo <owner>/<repo> --title "..." --body-file /tmp/issue-body.md --label "type: feat"
```

Note the issue number. It goes in every commit on this branch.

If the task file lists multiple GitHub issues, validate every issue number before
committing. The commit subject may reference the primary issue, but the commit
body and PR body must list all linked issues. The PR `Closes` section must use
GitHub closing keywords for every issue that should close when this PR merges.
If the task is split across several PRs, close only the issues completed by this
PR and leave partial rows open in the batch ledger.

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
      in-container verification has been run per `$RIG_DIR/rules/verification.md`
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

## Step 2.4 — Live validation plan and evidence

Derive 1–5 exact live validation steps from the acceptance criteria, diff, and
runtime surface. Keep lint, unit tests, type checks, and static analysis in their
own results; they do not count as live validation.

Every step must include **Setup**, an exact **Command/action**, the observable
**Expected** result, and **Cleanup** (or `None`). Run every safe local step,
record its actual result, fix failures, and rerun it. If a step is skipped or
unavailable, state why and record the residual risk. Docs-only changes still get
one minimal relevant step, such as checking changed links, rendering, or command
examples.

Destructive, production, paid, privileged, or externally visible validation
requires a separate warning describing the exact impact and separate explicit
approval before execution. If approval is declined, mark the step skipped with
its reason and residual risk.

Retain the steps and actual results for the PR **Test plan**.

---

## Step 2.5 — Commit gate: evidence block, validation card + commit pause

**Before presenting this prompt, confirm you have worked through the Step 1 checklist.**
Do not jump here from Step 0 or mid-implementation — the checklist is not optional.

If you skipped Step 1 for any reason: run through it now before continuing.

Then stop. Do not commit yet.

### Commit gate evidence block

Show this required evidence block immediately before the approval request. Keep
it to these bullets; link long output instead of pasting it. Fill every bullet
from results you actually observed in this session:

```text
Commit gate — <branch> · staged on <HEAD short SHA>   (post-commit review: <branch> @ <commit SHA>)
• Diff: <N> files, +<added>/−<deleted> — <one-line scope>
• Checks: <name> <passed>/<total> ✓ · <name> ✓   (or ✗ with the failing check name)
• Review: <independent diff review result> — pre-commit on staged diff   (or post-commit @ <SHA>, or not run + why)
• Live validation: <passed>/<total> PASS · <skipped> skipped (<reason>)
• Open risk: none   (or one line each, including every skipped check)
• Approving covers: this commit + push to <branch>
```

- **Heading:** before the commit, `HEAD` is the parent commit, so write
  `staged on <HEAD short SHA>`. Use `@ <commit SHA>` only when the review covered
  a commit that already exists.
- **Diff:** count every change, including new files. Run
  `git diff HEAD --shortstat` for tracked changes, then
  `git ls-files --others --exclude-standard` for untracked files, and add each
  untracked file to the file count and its lines to the added count.
- **Checks:** list the required checks (lint, unit, static) with pass counts. A
  check that did not run is listed as not run, never as passed.
- **Review:** label provenance. *Pre-commit* means the review covered the staged
  diff; *post-commit* means it covered a pushed commit, named by SHA. If the diff
  changed after the review, say so and re-run the review or disclose the gap.
- **Approving covers:** name exactly what the approval authorizes. It never
  covers a merge, tag, or release.

### Optional manual validation card

Then present the Step 2.4 live steps as a concise, copyable card; omit lint,
unit, and static checks, which belong in the commit gate evidence block:

```text
Optional manual validation (agent results: PASS / SKIPPED as noted)
1. Setup: <exact setup or None>
   Run: <exact command or action>
   Expect: <observable result>
   Agent result: <PASS / SKIPPED — actual observation, reason/risk if skipped>
   Cleanup: <exact cleanup or None>
```

Ask the user:
> "Pre-ship checklist and agent validation complete. The card above is optional
> to repeat. Say **'commit approved'** (or 'ship it', 'lgtm', 'go') to approve
> what the evidence block lists under 'Approving covers'.
> Approval does not claim you personally reviewed the diff or ran the card."

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

Read the configured base branch (`base-branch:` in `CLAUDE.md`, default `main`):

```bash
BASE=$(grep "^base-branch:" CLAUDE.md 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
BASE="${BASE:-main}"
```

**If you are on `$BASE`, `main`, or `master`:** do not commit. You need a feature
branch — see Step 3c below for how to create one safely.

**If there are untracked or modified files outside the task scope** (shown by `git status`):
surface them and ask whether to stage, stash, or ignore before continuing.

---

### 3a — Read the configured base branch

Read the `base-branch:` field from `CLAUDE.md` in the project root.
If absent, default to `main`.

```bash
BASE=$(grep "^base-branch:" CLAUDE.md 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
BASE="${BASE:-main}"
```

---

### 3b — Stale-main check (run before creating any new branch)

```bash
git fetch origin "$BASE" --quiet 2>/dev/null || true
AHEAD=$(git rev-list HEAD..origin/"$BASE" --count 2>/dev/null || echo 0)
```

**If AHEAD > 0:**

- **Low/Medium autonomy** — warn and pause:
  > "`origin/$BASE` is $AHEAD commit(s) ahead of your current position.
  > Rebase onto the latest before branching? [yes / no — branch anyway]"
  Wait for the user's answer. If yes: `git checkout "$BASE" && git pull`.

- **High autonomy** — auto-update and note it:
  ```bash
  git checkout "$BASE" && git pull
  ```
  > "Pulled latest $BASE ($AHEAD new commit(s)) before branching."

**If AHEAD == 0:** already up to date — proceed silently.

> If `git fetch` fails (no network, no remote): skip the check and proceed.
> Note: "Stale-main check skipped — fetch failed."

---

### 3c — Confirm base branch before creating a new branch

**Only applies when creating a new branch** (i.e., you are on `main` or creating a fresh branch
for this task). Skip this step if you are already on a suitable feature branch.

- **Low/Medium autonomy** — ask before branching:
  > "I'll create `[branch-name]` off `$BASE`. Is that the right base?
  > [yes / specify a different base]"
  Wait for confirmation. Do not run `git checkout -b` until confirmed.

- **High autonomy** — surface and proceed:
  > "Creating `[branch-name]` off `$BASE`."
  Run `git checkout -b [branch-name]` without waiting.

---

## Step 4 — Commit

Use conventional commit format. Replace `REF` in every commit example below,
including the later housekeeping commit, with the validated reference from
Step 0; for GitHub this is `#N`. Omit the bracketed reference when the tracker
is `none`:

```
type(scope): short description [REF]

Body: explain WHY, not what. The diff shows what.
```

Valid types: `feat` | `fix` | `refactor` | `test` | `docs` | `chore` | `style` | `perf` | `devops`

Write the approved commit message and create approval in the target worktree's
Rig directory. Do this before the separate `git commit` call:

```bash
cat > /tmp/commit-msg.txt << 'EOF'
feat(scope): description [REF]

Body explaining the why.
EOF
ROOT=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
TASK_INVENTORY_JSON=$("$ROOT/bin/rig" task inventory --json) || exit 1
RIG_DIR=$(printf '%s' "$TASK_INVENTORY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rig_dir"])')
touch "$RIG_DIR/memory/.rig-commit-ok"
```

```bash
RIG_COMMIT_POLICY=guarded git commit -F /tmp/commit-msg.txt
```

An active Rig `commit-msg` hook consumes approval for one attempt. Without it,
PreToolUse consumes approval before the visible command runs. Obtain fresh
approval before retrying a failed commit.

---

## Step 5 — Update memory

In this order:

1. **Checkpoint the active task file** with what was built, validation, commit,
   deviations, and PR status. Leave `**Status**: active` and the file under
   `$RIG_DIR/tasks/active/` until the PR merges. Keep `## Approach` as historical
   intent. `/post-merge` alone writes final Done notes and moves it to done.

2. Do not move the selected task file to done before the PR merges.

3. Update `$RIG_DIR/memory/PROGRESS.md` with an implementation and PR
   checkpoint, not a completed-task entry.

4. Write a draft containing the shared project state without task sections,
   then run `bin/rig memory write-snapshot --file "$DRAFT" --shared-only --json`.
   Reuse the inventory helper's `$RIG_DIR` and keep the draft under its `memory/`
   directory. Remove the draft after a successful write. Never edit or delete
   `CONTEXT_SNAPSHOT.md` directly; the writer preserves other sessions' task
   handoffs. Do not append `--retire-task` for the still-active task;
   `/post-merge` retires its handoff after the done move.

5. If anything surprised you, log it in `$RIG_DIR/memory/ERRORS.md`

6. If anything about The Rig's workflow was missing or felt wrong, log it in `$RIG_DIR/memory/RIG_GAPS.md`

7. **Post a progress comment on the GitHub Issue:** Show the exact issue
   number, target repository, and complete comment body. **Exact tracker
   write approval:** wait for the user's approval of this individual comment
   immediately before the command. A merge or ship approval does not cover
   it; repeat for each issue. If declined, record the comment as pending and
   continue local housekeeping without posting it.
   ```bash
   gh issue comment [N] --body "Implemented in PR #[M].

   Actual scope: [one sentence on what was actually built]
   Deviations: [any changes from the original issue description, or 'none']"
   ```
   This is especially important when scope changed — the issue description captures the original
   intent; the comment captures what was actually delivered.

   For a multi-issue PR, post the same actual-scope comment to every issue the
   PR closes. For issues partially delivered by this PR, post a progress comment
   instead and do not use a closing keyword.

---

## Step 6 — Open the PR

**The PR body must describe what was actually built — not the original plan.**
If scope changed during implementation, the PR body should note it explicitly. Reviewers
read the PR description to understand what landed, not what was intended.

**Template detection — this is a hard gate:**

```bash
# Check all common PR template paths
cat .github/pull_request_template.md 2>/dev/null || \
cat .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null || \
cat docs/pull_request_template.md 2>/dev/null || \
cat docs/PULL_REQUEST_TEMPLATE.md 2>/dev/null || \
cat pull_request_template.md 2>/dev/null || \
cat PULL_REQUEST_TEMPLATE.md 2>/dev/null
```

**If a template is found: you MUST use it. Never write a freeform PR body when a
project template exists.** Fill in every section — do not leave placeholders, skip
sections, or collapse multiple sections into one. If a section doesn't apply, write
"N/A" or delete it.

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

For multi-issue PRs, the `## Closes` section must list each issue on its own
line with a closing keyword:

```markdown
Closes #N
Closes #M
```

Do not write `Closes #N, #M`; GitHub does not reliably auto-close every issue in
that form across all repository settings and cross-repository references.

Push the committed branch first. Stop if the push fails; a local commit is not
a remote PR head:

```bash
BRANCH=$(git branch --show-current)
[[ -n "$BRANCH" && "$BRANCH" != "$BASE" ]] || exit 1
git push -u origin "$BRANCH" || exit 1
```

Then create the PR. The `--label` flags change external label assignments.
**Exact tracker write approval:** show the target repository, PR title, and
complete label list, and obtain the user's approval to apply those labels to
this PR immediately before the create command. A plan, commit, or earlier
label discussion does not count. If declined, keep the branch ready and
resolve required labels before opening the PR:

```bash
cat > /tmp/pr-body.md << 'EOF'
[filled-in template or fallback]
EOF
gh pr create --title "..." --body-file /tmp/pr-body.md --base [BASE_BRANCH] \
  --label "type: [type]" --label "area: [area]"
```

**Apply labels at creation time.** Never retroactively. Required labels:
- One `type:` label matching the commit type
- One or more `area:` labels for the layers touched

---

## Step 7 — Housekeeping commit (if needed)

If a pre-merge `PROGRESS.md` checkpoint was not included in the implementation
commit, make a follow-up housekeeping commit on the same branch only when that
file is stageable in this repository. Keep the task in `tasks/active/` until
`/post-merge` moves it to done after merge. Obtain fresh user approval for this
separate attempt. Create the one-use authorization only after staging succeeds
and immediately before the commit. For external or locally ignored Rig files,
skip this whole commit step and leave no approval sentinel behind.

```bash
ROOT=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
TASK_INVENTORY_JSON=$("$ROOT/bin/rig" task inventory --json) || exit 1
RIG_DIR=$(printf '%s' "$TASK_INVENTORY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rig_dir"])')
if [[ "$RIG_DIR" == "$ROOT/.rig" ]] && ! git -C "$ROOT" check-ignore -q .rig/memory/PROGRESS.md; then
  git -C "$ROOT" add .rig/memory/PROGRESS.md
  touch "$RIG_DIR/memory/.rig-commit-ok"
  RIG_COMMIT_POLICY=guarded git -C "$ROOT" commit -m "chore: post-task housekeeping [REF]"
else
  echo "Rig memory is external or locally ignored; no housekeeping commit is needed."
fi
```

When made, this commit goes on the same PR branch before the PR is merged.

---

## Step 8 — Review PR metadata at the merge boundary

After the last commit is pushed and the user asks to merge, fetch the PR's
`number,state,isDraft,headRefOid,title,body,labels,commits` with
`gh pr view --json` into a temporary JSON file. Read the normalized tracker
from `python3 bin/rig-tracker-config.py show CLAUDE.md`. Stop on a config error.
Fetch the final changed-file list with `gh pr diff N --name-only` into a
separate temporary file. Run
`bin/rig pr review-metadata --pr FILE --files FILE --issue-tracking TRACKING --payload-out FILE`
with the normalized tracker value and changed-file list. Only for GitHub
tracking, fetch the PR's closing issue references with `gh api graphql`; if
that fetch fails, report that the reviewer will use closing keywords from the
body. Include `--closing FILE` when available,
`--issue NUMBER` for every scoped GitHub issue,
`--not-closing NUMBER` for partial GitHub issues, and `--require-label LABEL` for each
required `area:` label. This review is read-only.

Check every explicit path in the PR's Summary, Changes, Files changed, and Scope
sections against the final changed-file list. Resolve any reported path that is
missing from the diff by verifying the body claim and proposing a correction.
Also compare test and verification claims, including counts, with the focused
results and CI run for the reviewed head; the metadata command cannot validate
semantic claims or test counts. Ask for approval before changing PR metadata or
body text. For an approved body correction, use the GitHub REST API with
`gh api repos/{owner}/{repo}/pulls/N --method PATCH --input FILE`, then fetch the
body again to verify it. Do not use `gh pr edit`.

Exit 0 means the metadata is clean: show the reviewed head SHA and final commits,
then confirm the PR body still describes those commits and matches the changed
files and verification evidence, show the merge gate evidence block, and stop
for the user's explicit merge approval. On findings (exit 3),
show each proposed change and obtain explicit approval before any external PR
edit; rerun the review after an approved edit. On invalid input (exit 64), fix
the fetch and rerun. If the head changes, repeat the review.

### Merge gate evidence block

Before asking the user to approve the merge, show this required evidence block.
Keep it to these bullets and fill each one from observed results:

```text
Merge gate — PR #<N> @ <head SHA>
• CI: <passed>/<total> ✓ at this exact head (<run link>)   (or ✗ with the failing check name)
• Review: <result> — post-commit on PR @ <SHA>   (or pre-commit + head unchanged since)
• Metadata/body review: clean   (or the approved changes)
• Unresolved: none   (or one line each, including skipped checks and open risks)
• Approving covers: merge PR #<N> into <base> (no tag or release)
```

- **CI:** report the check results for the exact head SHA in the heading, not for
  an earlier push.
- **Review:** label provenance. If the head moved after the review, say so and
  re-run the review or disclose the gap; a stale review never counts as current.
- **Approving covers:** a merge approval never covers a tag, release, or push to
  the base branch.
- **Stop after the block.** This is a stop for the user's explicit merge approval.
  Show the block, then end your turn and wait for an
  explicit go-ahead in a new user message that approves this merge. An earlier
  request such as "merge it" is not that approval. Never show the block and run
  the merge command in the same turn.

Merge only after CI is green and the user has explicitly approved this specific
merge. Use `gh pr merge` with `--match-head-commit` set to the reviewed SHA. If
the merge command exits nonzero, check `gh pr view --json state,mergedAt` before
retrying: a merged PR with a nonempty `mergedAt` succeeded despite local cleanup
failure. Preserve any linked worktree branch; clean it up separately.

---

## Post-batch audit

Run this checklist after every group of related PRs merges — not after every single commit.
Trigger: the last PR in a batch of 2+ related changes lands on main, or any single PR
touched multiple systems (e.g. both install.sh and command files).

**Checklist:**

- [ ] **Tests pass** — all bats/unit/integration tests green on main after the merge
- [ ] **CLI help text accurate** — any new behavior is reflected in `--help` output and flag descriptions
- [ ] **Docs updated** — `README.md`, `docs/how-it-works.md`, and feature docs reflect new commands or changed behavior
- [ ] **CHANGELOG.md updated** — entries present for all PRs in the batch
- [ ] **Comments consistent** — inline code comments match what the code actually does (stale comments are technical debt)
- [ ] **CONTEXT_SNAPSHOT and PROGRESS current** — run `/wrap` to lock in the batch's state before starting the next group

**Log the result:** a brief line in `$RIG_DIR/memory/PROGRESS.md` is sufficient —
e.g. "Post-batch audit passed — batch: PRs #117, #122, #124, #126"

If anything fails the checklist, fix it before starting the next task group.
