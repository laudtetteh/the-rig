# Git conventions

---

## Branch naming

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

**Types:** `feat` | `fix` | `chore` | `refactor` | `docs` | `test` | `perf` | `devops`

**Scope:** the area of the codebase affected (e.g. `auth`, `api`, `ui`, `db`, `hooks`)

**Issue reference:** `[#N]` at the end of the subject line. Required when a GitHub issue exists.

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
- **Never commit directly to `main` or `master`.** Always branch.
- **Never force-push to shared branches.**
- **Reference issue numbers in commits** when a GitHub issue exists: `feat(scope): description [#N]`
- Each commit must leave the repo in a working state (linting and tests pass).

---

## PR checklist

- [ ] Issue created before any code was written
- [ ] Tests added or updated (note if test framework not yet set up)
- [ ] `memory/PROGRESS.md` updated if completing a task
- [ ] No `console.log`, `print()`, or debug statements left in
- [ ] Self-reviewed diff before opening PR
- [ ] No secrets or credentials in staged files
- [ ] Labels applied at PR creation time
