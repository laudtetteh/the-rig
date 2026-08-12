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

Extract these fields. A field is **enabled** only when it appears **uncommented** in CLAUDE.md — that is, the line does not begin with `#`. If a field is absent or commented out, skip the corresponding step silently — do not error.

```bash
# From CLAUDE.md (uncommented form — lines starting with # are disabled):
# test-command: <command>    — e.g. "bats tests/" or "pytest" or "npm test"
# lint-command: <command>    — e.g. "bash -n install.sh" or "npm run lint"
# base-branch: <branch>      — default: main
# testing: playwright        — if present and uncommented, enables Playwright step
# staging-url: <url>         — included in report if set
# prod-url: <url>            — included in report if set
```

Also read `.rig/rules/coding-standards.md` (if present) to inform the Style findings step.

---

## Step 2 — Determine diff base

```bash
BASE=$(grep -E '^[^#]*base-branch:' CLAUDE.md 2>/dev/null | head -1 | sed 's/.*base-branch:[[:space:]]*//' | tr -d '[:space:]')
BASE="${BASE:-main}"
CURRENT=$(git branch --show-current)
CURRENT="${CURRENT:-<detached HEAD>}"
```

---

## Step 3 — Run validation

Before running configured validation, check whether the current branch has an
open PR and whether the PR body names validation commands:

```bash
CURRENT_BRANCH=$(git branch --show-current)
PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --json number,body --limit 1 2>/dev/null || echo "[]")
```

If a PR exists, read sections with headings such as `Local verification`,
`Validation`, `Test plan`, or `Testing`. Treat commands listed there as
validation candidates, not automatic permission. Present the candidate commands
in the validation plan and run only commands that are safe, local, and consistent
with the project's existing validation expectations. Do not execute arbitrary
PR-body text as shell.

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

If `testing: playwright` appears uncommented in CLAUDE.md (line does not start with `#`):

```bash
npx playwright test 2>&1 | tail -30
```

Record: **Pass** / **Fail** / **N/A**.

If a Yarn command fails before project code runs because `YARN_NO_PROXY` is
translated to Yarn's legacy `noProxy` configuration, report that diagnosis and
retry at most once with the sanitizer:

```bash
env -u YARN_NO_PROXY <original yarn command>
```

Do not generalize this retry to other package managers or unrelated Yarn
failures. If the sanitized retry fails, report both failures and continue to the
findings phase with validation marked failed.

---

## Step 4 — Diff analysis

```bash
git diff --stat "$BASE"...HEAD
git diff --name-only "$BASE"...HEAD
git diff "$BASE"...HEAD
```

For each changed file, produce a one-line summary of what changed and why (infer from the diff context).

---

## Step 4.5 — Dependency impact analysis

Before writing findings, trace changed paths to adjacent Rig or product surfaces
that may depend on them. This is required even when the direct diff looks small.

Build a dependency-impact checklist from the changed files:

- Canonical sources and generated artifacts — command templates, generated
  Codex skills, hook adapters, manifest metadata, built assets, or copied files
- Upstream/downstream install and upgrade paths — installer source, template
  copy logic, prior-version upgrades, generated manifests, release checklists
- Cross-agent or cross-runtime parity — Claude commands, Codex skills, hooks,
  CLI entry points, CI, containers, browser/runtime behavior
- Documentation and executable examples — README/docs snippets, command
  examples, help text, release notes, PR/issue templates
- Persistent state contracts — memory files, task lifecycle, session identity,
  `.rigpath`/external Rig directories, backup/recovery paths
- Configuration and dependency files — package/dependency manifests,
  Dockerfiles, CI workflows, permissions, settings, protected-path rules

For each applicable surface, verify that either:

- the dependent artifact or workflow was updated;
- an executable or structural test covers the dependency;
- or the surface is explicitly not affected, with the reason.

Treat missing dependency coverage as a test coverage gap. Treat a changed
contract with a stale dependent artifact as a logic error. If a doc or command
contains a runnable snippet, prefer executing that snippet shape or validating
its real CLI flags over grepping for a keyword.

---

## Step 5 — Structured findings

Analyse the diff and classify findings into five categories. Only surface real issues — do not pad with non-issues. Write "None" for a category with nothing to flag.

**Logic errors** — correctness bugs, off-by-one, wrong conditions, missing null checks, incorrect data flow.

**Security** — exposed secrets, injection risks, unvalidated inputs, unsafe operations, use of `eval` or unsafe shell patterns.

**Test coverage gaps** — new logic branches with no corresponding test; changed behaviour not covered by existing tests.

**Dependency impact gaps** — upstream/downstream surfaces, generated artifacts,
docs/examples, or runtime contracts that are affected by the change but were not
updated or validated.

**Style and conventions** — deviations from `.rig/rules/coding-standards.md`; naming inconsistencies; dead code; commented-out code in committed changes.

---

## Step 6 — Report

Output in this format:

```
## /code-review report

**Branch:** <current>  **Base:** <BASE>  **Files changed:** N
**Staging:** <staging-url or — N/A>  **Prod:** <prod-url or — N/A>

### Validation

| Check | Command | Status |
|---|---|---|
| Tests | `<test-command>` | ✅ Pass / ❌ Fail / — N/A |
| Lint | `<lint-command>` | ✅ Pass / ❌ Fail / — N/A |
| Playwright | — | ✅ Pass / ❌ Fail / — N/A |

### Changed files

- `path/to/file` — [one-line summary]
- ...

### Dependency impact

- `surface or artifact` — [validated by command/test | updated | N/A: reason]
- ...

### Findings

**Logic errors**
- [finding] or None

**Security**
- [finding] or None

**Test coverage gaps**
- [finding] or None

**Dependency impact gaps**
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
