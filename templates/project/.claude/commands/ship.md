# Command: /ship

Trigger this command when you are ready to commit and close out a task.

This is a **sequential hard gate** — each step must be completed and confirmed
before the next one executes. Do not skip steps, combine steps, or proceed past
a failure without surfacing it.

> **RIG_DIR resolution:** Before reading or writing any `.rig/` path, use the
> inventory helper's resolved `rig_dir`. It handles in-repo, external, and
> relative `.rigpath` values without changing spaces in a path.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> TASK_INVENTORY_JSON=$("$REPO/bin/rig" task inventory --json) || {
>   printf '%s\n' "$TASK_INVENTORY_JSON" >&2
>   exit 1
> }
> RIG_DIR=$(printf '%s' "$TASK_INVENTORY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rig_dir"])')
> ```
>
> Substitute `$RIG_DIR` for `.rig/` in every step below.

---

## Step 1 — Identify the task

Use the inventory result above before listing tasks. If it reports
`state: omitted`, stop with: "Task lifecycle unavailable: this Rig install
intentionally omitted the task component. Install tasks before shipping."
If it reports `state: ambiguous` or `ok: false`, stop and report its `reason`
as an inventory error. This includes any missing installed task directory.
Do not interpret either state as an empty task list.

For `state: installed` with `ok: true`, read task files in
`$RIG_DIR/tasks/active/` (ignore `.gitkeep`). If there is exactly one task file,
confirm it.
If there are multiple, ask the user which task is being shipped. If there are
none, stop and say: "No active task found. Move a task to `$RIG_DIR/tasks/active/`
before shipping."

State clearly:
> "Shipping: **[task name]** — [one-line goal from the task file]"

Wait for the user to confirm this is the right task before continuing.

---

## Step 2 — Confirm the configured tracker reference

First, run `python3 bin/rig-tracker-config.py show CLAUDE.md` and use its
normalized `tracker`, `pattern`, and `example` values. Stop on a
configuration error.

**If `issue-tracking: none`:** skip this step entirely — proceed to Step 3.

**If `issue-tracking: github`** (or field absent — default):

Read the task file's `**GitHub issue**:` field.

- If it contains a real issue number (e.g. `#12`): state it and proceed.
- If it contains multiple issue numbers (e.g. `#12, #13`): state every issue and
  treat this as a multi-issue PR candidate. Verify the PR body later closes each
  intended issue on its own `Closes #N` line.
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

If the agent will file the issue, show the exact target repository, title,
complete body, and labels. **Exact tracker write approval:** ask the user to
approve this one issue creation immediately before it is submitted. A task
plan or ship approval does not count. If declined, wait for the user to
provide an existing issue number or approve a later exact draft.

**For any other tracker:** Read the task's `**Issue**:` field. Require an
existing nonempty reference. Run
`python3 bin/rig-tracker-config.py validate-ref CLAUDE.md "REF"` for each
reference, replacing `REF` with its actual value. Ask the user
to supply a missing reference and record it before continuing. The agent
does not create tickets through a non-GitHub tracker.

Do not proceed to Step 3 until the configured tracker's reference is confirmed
(or `issue-tracking: none` is set).

---

## Step 3 — Verify labels

Run:
```bash
gh label list --repo $(gh repo view --json nameWithOwner -q .nameWithOwner)
```

Display the available labels. Determine which `type:` label matches this
commit type (`feat`, `fix`, `chore`, `refactor`, `docs`, `devops`, etc.) and
which `area:` labels apply.

If a required label does not exist, draft its exact name, color, description,
and target repository. **Exact tracker write approval:** show that proposal and
wait for the user's approval of this label creation immediately before running
it. Repeat for each missing label; approval of the ship plan or another label
does not count. If declined, leave the label absent and resolve the label
requirement with the user before continuing:
```bash
gh label create "type: feat" --color "#0e8a16" --description "New functionality" --repo "[owner/repo]"
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

**If on the configured base branch (`$BASE`, read below), `main`, or `master`:**
stop — you cannot commit directly here. Ask:
> "You're on `[current-branch]`. Which branch should this go on? I can create `[type/slug]` off `[BASE]`."
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
- [ ] Dependency impact checked — generated artifacts, downstream install/upgrade
      paths, docs/examples, runtime surfaces, and persistent state contracts are
      updated or explicitly N/A
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

## Step 4.6 — Dependency impact gate

This is a blocking gate. A focused test pass is not enough if the change affects
other Rig or product surfaces.

Build a dependency-impact matrix from the changed paths:

```bash
git diff --name-only HEAD~1..HEAD 2>/dev/null || git diff --cached --name-only
```

Check every applicable surface:

- **Generated artifacts:** If canonical sources changed, verify generated
  outputs or mirrors are updated or regenerated. Examples: `.claude/commands/*`
  -> `.agents/skills/*`, templates -> installed files, manifest metadata.
- **Downstream install/upgrade:** If `install.sh`, `templates/`, manifest logic,
  hooks, or command sources changed, validate the install/upgrade path that will
  ship the change to an existing project.
- **Cross-agent parity:** If a workflow is shared by Claude, Codex, hooks, or
  `bin/rig`, verify the corresponding surface still preserves the same contract.
- **Docs and examples:** If docs, command text, or README snippets changed, make
  runnable snippets match the actual CLI/API shape; execute safe snippets when
  practical.
- **Persistent state:** If memory, task, session, `.rigpath`, backup, or recovery
  behavior changed, validate the state transition and the failure/permission path.
- **Runtime/config dependencies:** If dependency manifests, Dockerfiles, CI,
  settings, or permissions changed, run the relevant runtime/config validation or
  record why it is unavailable.

Report the matrix before continuing:

```text
Dependency impact:
- Generated artifacts: PASS / N/A / HOLD — evidence
- Downstream install/upgrade: PASS / N/A / HOLD — evidence
- Cross-agent/runtime parity: PASS / N/A / HOLD — evidence
- Docs/examples: PASS / N/A / HOLD — evidence
- Persistent state: PASS / N/A / HOLD — evidence
- Runtime/config dependencies: PASS / N/A / HOLD — evidence
```

If any row is `HOLD`, stop and fix or validate it before continuing. Use `N/A`
only with a concrete reason tied to the changed paths.

Retain this matrix and reuse it in the pull request **Dependency impact** section.

---

## Step 4.8 — Docs and memory freshness gate

**Check 1 — PROGRESS.md stubs (blocking)**

Run:
```bash
grep -Ec "Auto-logged by (post-tool|post-commit) hook" "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null || echo 0
```

If the count is > 0: stop and say:
> "PROGRESS.md has unexpanded auto-stubs. Run `/wrap` to expand them before shipping."
Do not continue until the user resolves this.

**Check 2 — Feature doc overlap (advisory, only if feature docs are installed)**

Only run this check if `$DOCS_DIR/features/README.md` exists, with
`DOCS_DIR="$REPO/docs"` after resolving the project root.

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

## Step 4.9 — Live validation plan and evidence

Before asking for commit approval, derive **1–5 exact live validation steps** from
the task acceptance criteria, changed paths, and runtime surface. Keep lint,
unit tests, type checks, and static analysis in the Step 3 results; they are not
live validation.

If the branch has an open PR, read the PR body before finalizing the plan:

```bash
CURRENT_BRANCH=$(git branch --show-current)
PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --json number,body --limit 1 2>/dev/null || echo "[]")
```

Review headings such as `Local verification`, `Validation`, `Test plan`, or
`Testing`. Commands listed there are validation candidates, not automatic shell
input. Include safe, local, relevant candidates in the live validation plan and
state why any candidate is skipped. Never execute arbitrary PR-body commands
without presenting the plan and applying the same safety gates as any other
command.

If a Yarn validation command fails before project code runs because
`YARN_NO_PROXY` is translated to Yarn's legacy `noProxy` configuration, report
that diagnosis and retry at most once with:

```bash
env -u YARN_NO_PROXY <original yarn command>
```

Do not retry unrelated Yarn failures with this sanitizer.

Each live step must state:

- **Setup** — fixtures, throwaway repository, service state, or `None`
- **Command/action** — an exact copyable command or precise UI action
- **Expected** — the observable result and exit status where applicable
- **Cleanup** — an exact cleanup action, or `None`

Run every safe, local step yourself. Record the actual result, fix failures, and
rerun the affected step before continuing. For a skipped or unavailable step,
record the reason and residual risk. A docs-only diff still needs one minimal
relevant step, such as rendering or checking the changed links and examples.

Do not run a destructive, production, paid, privileged, or externally visible
step under this approval. Present it separately with the exact impact and ask
for explicit approval before running it. Declining that separate approval is a
skip: record the reason and residual risk.

Retain this validation plan and its actual results. Reuse them in the pull
request **Test plan** instead of replacing them with a generic test claim.

---

## Step 5 — Optional manual validation card and commit pause

**Stop here.** Do not commit yet.

Present a concise, copyable card containing the live steps from Step 4.9. Do not
include lint, unit, or static checks in the card.

```text
Optional manual validation (agent results: PASS / SKIPPED as noted)
1. Setup: <exact setup or None>
   Run: <exact command or action>
   Expect: <observable result>
   Agent result: <PASS / SKIPPED — actual observation, reason/risk if skipped>
   Cleanup: <exact cleanup or None>
```

Then say:
> "Ready to commit. The card above is optional to repeat. By saying
> **'commit approved'** (or 'ship it', 'lgtm', 'go'), you confirm that you
> reviewed the diff and reported evidence; it does not claim you personally
> ran the card."

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

For a multi-issue task, the subject may carry the primary issue, but the body
must list all linked issues. Example: `Refs #12, #13`; use PR closing keywords
only in the PR body unless this commit itself is the tracked closure mechanism.

Display it. Then ask:
> "Commit with this message? [yes / edit]"

If the user says "edit", accept the revised message. Do not commit until the
message is explicitly approved.

---

## Step 7 — Commit

The user reviewed the diff and reported validation evidence at Step 5, then
approved the commit message at Step 6. Do not claim that the user personally ran
the optional validation card.
That constitutes explicit go-ahead. Resolve the current worktree's Rig directory,
write the approved message, and create the commit sentinel. Run `git commit`
in a separate Bash tool call. An active Rig `commit-msg` hook checks the prepared
subject and branch, then consumes the sentinel for one attempt. Without that
hook, PreToolUse checks the visible command and consumes the sentinel before Git runs.

```bash
cat > /tmp/ship-commit-msg.txt << 'EOF'
[approved commit message]
EOF
ROOT=$(git rev-parse --show-toplevel)
TASK_INVENTORY_JSON=$("$ROOT/bin/rig" task inventory --json) || exit 1
RIG_DIR=$(printf '%s' "$TASK_INVENTORY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rig_dir"])')
touch "$RIG_DIR/memory/.rig-commit-ok"
```

```bash
RIG_COMMIT_POLICY=guarded git commit -F /tmp/ship-commit-msg.txt
```

The active guard consumes the sentinel for one attempt. If the commit fails,
ask for fresh approval before retrying.

Report the commit hash on success.

---

## Step 8 — Post-commit housekeeping

In this order:

1. **Verify the task file reflects reality** before moving it:
   - `## Done notes` must describe what was actually built — not a restatement of the plan
   - Required fields: **What was built** / **Deviations from plan** / **Actual files touched** / **Follow-ups opened**
   - If scope or approach changed during execution, capture it in `## Done notes`
   - `## Approach` stays as the original plan (historical intent); deviations belong in `## Done notes`
2. Move the task file: `$RIG_DIR/tasks/active/TASK_[name].md` → `$RIG_DIR/tasks/done/`
3. Update `.rig/memory/PROGRESS.md` — add a full entry at the top (not a stub); if scope changed, the entry reflects the actual outcome
4. Create a unique draft under `$RIG_DIR/memory/` with `mktemp`, write only the
   current shared project header to it, and in the same shell call
   `bin/rig memory write-snapshot --file "$DRAFT" --shared-only --json` with
   `DRAFT` set to that draft's path. If Step 2 moved a task to done, inspect
   the existing snapshot for its exact `## Resuming from: <task-slug>` heading
   and append `--retire-task <task-slug> --done-task-file "$RIG_DIR/tasks/done/<filename>"`
   for that task. The writer checks the done file and backs up the old view.
   Remove the draft after a successful write. Keep other sessions' active
   handoffs; do not edit `CONTEXT_SNAPSHOT.md` directly.
5. If anything surprised you, log it in `.rig/memory/ERRORS.md`
6. If anything about The Rig's workflow was missing or felt wrong, log it in `.rig/memory/RIG_GAPS.md`
7. **Post a closing comment on the GitHub Issue:** First show the exact issue
   number, target repository, and complete comment body below. **Exact tracker
   write approval:** wait for the user's approval of this one comment
   immediately before posting. A merge or ship approval does not cover it.
   Repeat for each issue. If declined, record the comment as pending and
   continue local housekeeping without posting it.
   ```bash
   gh issue comment [N] --body "Implemented in PR #[M].

   Actual scope: [one sentence on what was actually built]
   Deviations: [any changes from the original issue description, or 'none']"
   ```
   This is required when scope changed; recommended always.

   For multi-issue PRs, repeat the actual-scope comment for every issue closed by
   this PR. For partial delivery, post a progress comment and leave the issue open.

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
   If `gh pr edit` exits non-zero (for example a GraphQL error about Projects
   (classic) `projectCards`), write the same approved title and body through REST:
   ```bash
   python3 -c 'import json,sys; json.dump({"title": sys.argv[1], "body": open(sys.argv[2]).read()}, open(sys.argv[3], "w"))' \
     "[updated title]" /tmp/ship-pr-body.md /tmp/ship-pr-payload.json
   gh api repos/{owner}/{repo}/pulls/[N] --method PATCH --input /tmp/ship-pr-payload.json
   ```
   Then confirm with `gh pr view [N] --json title,body` that the edit landed.
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

## Dependency impact
- Generated artifacts:
- Downstream install/upgrade:
- Cross-agent/runtime parity:
- Docs/examples:
- Persistent state:
- Runtime/config dependencies:

## Closes
Closes #N

## Test plan

## Notes
```

For a multi-issue PR, render the `## Closes` section as one closing line per
issue:

```markdown
Closes #12
Closes #13
```

Do not combine issue numbers on one `Closes` line. If one issue is only partially
delivered, list it under `Notes` or a progress section instead of `Closes`.

Then create the PR. The `--label` flags change external label assignments.
**Exact tracker write approval:** show the target repository, PR title, and
complete label list, and obtain the user's approval to apply those labels to
this PR immediately before the create command. The earlier Step 3 label
discussion is not this approval. If approval is declined, keep the branch
ready and resolve the required labels before opening the PR:

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

## Step 9.5 — Final merge-boundary metadata review

Run this read-only review once, immediately before any merge command: after the
last commit is pushed and the user has asked to merge. Do not run it on every
prompt, and do not edit the PR as part of it.

Fetch the PR metadata and run the reviewer. Replace `[N]` with the PR number.
Add `--issue NUMBER` for every issue in the task's scope, `--not-closing NUMBER`
for every issue that is only partially delivered, and `--require-label "LABEL"`
for every `area:` label chosen in Step 3:

```bash
REPO=$(git rev-parse --show-toplevel)
PR_NUMBER=[N]
TRACKING=$(grep "^issue-tracking:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
TRACKING="${TRACKING:-github}"
REVIEW_DIR=$(mktemp -d)
gh pr view "$PR_NUMBER" --json number,state,isDraft,headRefOid,title,body,labels,commits > "$REVIEW_DIR/pr.json"
REVIEW_ARGS=(--pr "$REVIEW_DIR/pr.json" --issue-tracking "$TRACKING" --payload-out "$REVIEW_DIR/payload.json")
if [[ "$TRACKING" == github ]] && gh api graphql \
  -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){closingIssuesReferences(first:50){nodes{number}}}}}' \
  -F o='{owner}' -F r='{repo}' -F n="$PR_NUMBER" > "$REVIEW_DIR/closing.json"; then
  REVIEW_ARGS+=(--closing "$REVIEW_DIR/closing.json")
fi
"$REPO/bin/rig" pr review-metadata "${REVIEW_ARGS[@]}"
echo "review exit: $?"
```

If the GraphQL call fails, the reviewer falls back to closing keywords in the PR
body and says so in its `Closing links:` line. Report that fallback to the user.

Act on the exit code:

- **0 (CLEAN):** show the `Reviewed head:` SHA and the final-commit list. Confirm
  the body still describes what landed; if it does not, draft a replacement body
  and treat it like a proposed edit below. Then proceed to the merge.
- **3 (findings):** show every finding and the proposed edits exactly as printed.
  No edit has been made. Ask the user to approve or reject each proposed external
  write. Run only the approved commands the reviewer printed — they use the REST
  API (`gh api ... --method PATCH` / `--method POST`) because `gh pr edit` can fail
  on repositories affected by the GitHub Projects (classic) deprecation. For a
  finding without a proposed edit (for example an unexpected closing link or an
  empty body), draft the exact change, get approval, write it with
  `gh api repos/{owner}/{repo}/pulls/[N] --method PATCH --input FILE` where FILE
  holds `{"body": "..."}`, and never assume a write succeeded because the
  command was invoked. Re-run the fetch and review afterwards. Merge only when it
  is clean or the user explicitly accepts each remaining finding.
- **64 (bad input):** the metadata could not be read. Fix the fetch and re-run;
  never merge on unreviewed metadata.

Merge only the reviewed head, using the `Merge only the reviewed head:` command
the reviewer printed (`gh pr merge [N] --match-head-commit SHA`, plus the merge
method the project uses). If the head moved after the review, run Step 9.5 again.

---

## Step 10 — Merge verification and branch cleanup

When the user explicitly authorizes merge, remember that
`gh pr merge --delete-branch` can merge the PR on GitHub but exit non-zero during
local branch cleanup from a linked worktree. Prefer a merge command without
local branch deletion from linked worktrees, then clean up the remote branch
after the merge is verified.

After any merge command exits non-zero, do not assume the merge failed until you
verify PR state:

```bash
gh pr view "$PR_NUMBER" --json state,mergedAt
```

If `state` is `MERGED` and `mergedAt` is non-empty, report that the merge
succeeded and treat the non-zero exit as local cleanup failure. Do not run
destructive local branch cleanup; do not delete a local linked-worktree branch.
If remote branch deletion is still needed,
delete only the remote branch after confirming the PR is merged and the target
branch name is the PR head branch. If the PR is not merged, surface the original
merge error and stop.

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
- The optional-card commit pause (Step 5) is non-negotiable regardless of autonomy level.
- The branch check (Step 3.5) is also a gate — never commit directly to main.
- If the task has multiple commits, summarise all changes in the PR body.
- The task file is moved to `$RIG_DIR/tasks/done/` only after a successful commit (Step 8).
- The PR body (Step 9) must reflect what was actually built — not the original plan.
