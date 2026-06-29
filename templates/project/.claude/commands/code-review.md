# Command: /code-review

Diff-focused review of the current branch: runs local validation first, then analyses the diff by category and produces a structured pass/fail report.

## Usage

```
/code-review
/code-review --fix    # apply suggested fixes after review
```

Lighter than `/pre-release-review` — scoped to the branch diff, not the full codebase.
Use `/pre-release-review` before cutting a release; use `/code-review` during development.

---

## Step 1 — Read config from CLAUDE.md

Extract these fields. If a field is absent, skip the corresponding step silently — do not error.

```bash
# From CLAUDE.md:
# test-command: <command>    — e.g. "bats tests/" or "pytest" or "npm test"
# lint-command: <command>    — e.g. "bash -n install.sh" or "npm run lint"
# base-branch: <branch>      — default: main
# testing: playwright        — if present, enables Playwright step
# staging-url: <url>         — included in report if set
# prod-url: <url>            — included in report if set
```

Also read `.rig/rules/coding-standards.md` (if present) to inform the Style findings step.

---

## Step 2 — Determine diff base

```bash
BASE=$(grep 'base-branch:' CLAUDE.md 2>/dev/null | head -1 | sed 's/.*base-branch:[[:space:]]*//' | tr -d '[:space:]')
BASE="${BASE:-main}"
CURRENT=$(git branch --show-current)
```

---

## Step 3 — Run validation

### Tests

If `test-command:` is set:

```bash
<test-command> 2>&1
```

Record: **Pass** / **Fail**. On fail, include the last 30 lines of output in the report.

### Lint

If `lint-command:` is set:

```bash
<lint-command> 2>&1
```

Record: **Pass** / **Fail**. On fail, include output.

### Playwright (opt-in)

If `testing: playwright` appears in CLAUDE.md:

```bash
npx playwright test 2>&1 | tail -30
```

Record: **Pass** / **Fail** / **N/A**.

---

## Step 4 — Diff analysis

```bash
git diff --stat "$BASE"...HEAD
git diff --name-only "$BASE"...HEAD
git diff "$BASE"...HEAD
```

For each changed file, produce a one-line summary of what changed and why (infer from the diff context).

---

## Step 5 — Structured findings

Analyse the diff and classify findings into four categories. Only surface real issues — do not pad with non-issues. Write "None" for a category with nothing to flag.

**Logic errors** — correctness bugs, off-by-one, wrong conditions, missing null checks, incorrect data flow.

**Security** — exposed secrets, injection risks, unvalidated inputs, unsafe operations, use of `eval` or unsafe shell patterns.

**Test coverage gaps** — new logic branches with no corresponding test; changed behaviour not covered by existing tests.

**Style and conventions** — deviations from `.rig/rules/coding-standards.md`; naming inconsistencies; dead code; commented-out code in committed changes.

---

## Step 6 — Report

Output in this format:

```
## /code-review report

**Branch:** <current>  **Base:** <BASE>  **Files changed:** N

### Validation

| Check | Command | Status |
|---|---|---|
| Tests | `<test-command>` | ✅ Pass / ❌ Fail / — N/A |
| Lint | `<lint-command>` | ✅ Pass / ❌ Fail / — N/A |
| Playwright | — | ✅ Pass / ❌ Fail / — N/A |

### Changed files

- `path/to/file` — [one-line summary]
- ...

### Findings

**Logic errors**
- [finding] or None

**Security**
- [finding] or None

**Test coverage gaps**
- [finding] or None

**Style**
- [finding] or None

### Verdict

✅ **LGTM** — no blocking issues
❌ **HOLD** — [N] blocking finding(s) listed above require attention before merge
```

---

## Step 7 — Fix mode (--fix only)

If `--fix` was passed: for each blocking finding in the report, propose a concrete fix and ask the user to confirm before applying. Apply one fix at a time. Re-run validation after all fixes are applied.

---

## Notes

- Validation failures are always blocking — the Verdict is HOLD if any validation step fails
- Security findings are always blocking
- Logic error findings are always blocking
- Test coverage and style findings: surface them but mark the Verdict as HOLD only if the project's coding standards treat them as required
- `/code-review` does not commit or push — it reviews and optionally fixes; use `/ship` to commit
