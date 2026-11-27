# Git conventions

---

## Branch naming

The commit hook enforces `branch-prefixes:` when the project `CLAUDE.md` sets
it. The value is a comma-separated list such as
`feat/,fix/,chore/,refactor/,docs/,devops/`; base branches are exempt. Read
the effective value with `python3 bin/rig-config get CLAUDE.md branch-prefixes`.

```
feat/short-description        # new feature
fix/short-description         # bug fix
chore/short-description       # tooling, deps, config, maintenance
refactor/short-description    # code change with no behaviour change
docs/short-description        # documentation only
devops/short-description      # CI/CD, Docker, infra, release
```

Keep branch names lowercase, hyphen-separated, under 50 characters.

---

## Commit message format

Follows [Conventional Commits](https://www.conventionalcommits.org/).

```
type(scope): short description [#N]

Optional body explaining WHY, not what. The diff shows what.
```

**Default types:** `feat` | `fix` | `chore` | `refactor` | `docs` | `test` | `perf` | `devops` | `style`

The commit hook reads the accepted types from the project's `commit-types:`
setting through `bin/rig-config`. When `commit-subject-max-length:` is set,
the hook enforces that character limit. The new project scaffold sets it to 72;
missing settings retain the existing hook behavior. Use
`python3 bin/rig-config get CLAUDE.md KEY` to inspect an explicit value.

**Scope:** the area of the codebase affected (e.g. `auth`, `api`, `ui`, `db`, `hooks`)

**Issue reference:** `[#N]` at the end of the subject line. Required when a GitHub issue exists.

> **`[#N]` is a reference, not an auto-close trigger.** GitHub auto-closes the linked issue
> only when a commit containing `Closes #N`, `Fixes #N`, or `Resolves #N` in its **body**
> is merged to the default branch — or when those keywords appear in the **PR body** of a
> PR merging to the default branch. The `[#N]` subject-line format fulfils The Rig's
> commit-msg validation and creates a hyperlink in GitHub history, but does not auto-close.
> Always include `Closes #N` in the PR body (the `/rig-ship` PR template already does this).

### Examples

```
feat(auth): add invite token acceptance flow [#12]
fix(api): handle null user on profile fetch [#18]
chore(deps): upgrade next to 14.2.1
docs(readme): add quickstart section [#31]
devops(ci): add Docker build step to GitHub Actions [#7]
```

---

## Rules

- **Issue before commit.** Create the GitHub issue before writing code. The issue number must be in the commit message — not added retroactively.
- **Commit after each meaningful unit of work.** Not at end of day. Not after five unrelated changes.
- **Never commit directly to the configured base branch (`base-branch:` in `CLAUDE.md`), `main`, or `master`.** Always branch.
- **Never force-push to shared branches.**
- **Reference issue numbers in commits** when a GitHub issue exists: `feat(scope): description [#N]`
- Each commit must leave the repo in a working state (linting and tests pass).

---

## PR checklist

- [ ] Issue created before any code was written
- [ ] Tests added or updated (note if test framework not yet set up)
- [ ] `.rig/memory/PROGRESS.md` updated if completing a task
- [ ] No `console.log`, `print()`, or debug statements left in
- [ ] Self-reviewed diff before opening PR
- [ ] No secrets or credentials in staged files
- [ ] Labels applied at PR creation time
