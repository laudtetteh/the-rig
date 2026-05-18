# Command: /pre-release-review

Run this command before cutting a release. Performs a full stability review
across correctness, security, test coverage, documentation, and release
readiness. Intended for use before the version bump and changelog PR.

Work through each section completely. For every finding, note:
- **File** and **line number** (or range)
- **Severity**: `critical` | `high` | `medium` | `low`
- **What the problem is** and why it matters
- **Suggested fix** (or "needs discussion" if non-obvious)

---

## Step 0 — Orientation

Read `CLAUDE.md` fully. Identify and note:
- **Entry points** — the main files/modules where execution begins
- **Test command** — the exact command to run the test suite
- **Test count** — if documented, the expected number of passing tests
- **Version file** — where the current version string lives
- **Changelog file** — where release notes are maintained

Then identify all commits under review since the last tag:

```bash
git log --oneline $(git describe --tags --abbrev=0)..HEAD
```

If no tags exist: `git log --oneline`. These commits define the scope of the
review.

Read any files named in `CLAUDE.md`'s "Key services/modules" or "Common
gotchas" sections before proceeding. Do not summarise any of this back.

---

## Step 1 — Regression check

Focus on files and code paths changed since the last tag.

- For each changed file: are there any new code paths that can fail silently
  or leave the system in an unexpected state?
- Are inputs validated at all new boundaries (user input, external APIs,
  file reads)?
- Are errors handled explicitly — no silent swallows, no bare `catch`/`except`
  without logging?
- Do any changed functions now do more than one thing? If so, is that
  intentional?
- Are there any new global state mutations that weren't there before?
- Does the entry point still behave correctly for its primary use case? Trace
  the happy path through changed code.
- Do any changes affect startup/boot behaviour? If so, does the app still
  start cleanly?

---

## Step 2 — Test coverage

Run the test suite and report the exact result:

```bash
# Use the test command from CLAUDE.md
```

Report pass/fail count. For any failure, show the full error output.

Then check:
- For every new behaviour introduced since the last tag: is there a
  corresponding test? List any uncovered behaviour.
- Are there any tests that pass but give false confidence because the
  implementation changed under them?
- Are there any skipped or disabled tests without a linked issue or comment
  explaining why?
- Has the total test count dropped since the last release? If so, flag it.

---

## Step 3 — Security

Apply these checks to all changed files. Flag anything that wasn't present
before.

- **Injection**: any new use of `eval`, dynamic query construction, shell
  interpolation, or template rendering with unsanitised user input?
- **Auth**: are all new routes or endpoints protected appropriately? Any new
  code that trusts client-supplied identity without server-side verification?
- **Secrets**: are there any hardcoded credentials, tokens, or API keys in
  new or changed files?
- **Input validation**: is user-supplied data validated and sanitised at every
  new system boundary?
- **Exposure**: do any new error paths, logs, or API responses leak internal
  details (stack traces, DB schema, file paths)?
- **Dependencies**: were any new packages added? If so, are they from
  reputable sources and free of known CVEs?

---

## Step 4 — Documentation accuracy

- Does `README.md` accurately reflect the current feature set? Check any
  enumerated feature or command lists.
- Are there stale code examples or install instructions that no longer match
  current behaviour?
- If this project has feature docs (`docs/features/`): do any documented
  features have logic that changed in this release? If so, are the docs
  updated?
- Does the changelog cover all meaningful changes since the last release?
  List any merged PRs or notable commits that are missing.
- Are there any docs that still reference the old version number?

---

## Step 5 — Maintainability

- Any new functions longer than ~40 lines that should be split?
- Any duplicated logic in new code that should be extracted?
- Any new magic numbers or hardcoded strings that should be named constants?
- Any dead code (unreachable branches, unused variables, deleted-but-not-removed
  functions) left behind by recent changes?
- Any `TODO` or `FIXME` comments introduced in this release that aren't
  tracked in an issue?

---

## Step 6 — Edge cases and failure modes

- What happens with missing or empty input at the primary entry point?
- What happens if a required external dependency (DB, API, filesystem) is
  unavailable at startup?
- What happens if the process is interrupted mid-operation? Could new code
  leave data in a partial state?
- Are there any new file or network operations that don't handle failure
  (permissions error, timeout, not found)?
- Do any new configuration values have sensible defaults, or will the app
  break silently if they're missing?

---

## Step 7 — Version bump readiness

- What is the current version string, and where does it live?
- If there's a `--version` flag or `/version` endpoint: does it return the
  current version?
- Does the changelog have a section ready for the new version (or an
  `[Unreleased]` block)?
- Are all changes since the last tag represented in the changelog?
- Are there any open issues or known blockers that must be resolved before
  this release, not after?

---

## Output format

Produce the review as a single Markdown document with section headers
matching the steps above. End with:

```
## Summary scorecard

| Severity | Count |
|----------|-------|
| critical |       |
| high     |       |
| medium   |       |
| low      |       |

**Recommendation:** SHIP / HOLD / SHIP WITH FIXES
**Blockers (must fix before tag):** [list or "none"]
**Non-blockers (fix in patch):** [list or "none"]
```

Be direct. Flag real problems. Do not pad with non-issues.
