# Command: /recon

Research how a feature, pattern, or system was built — and how it has evolved.

`/recon` sweeps three sources in one pass: merged PR history, commit messages, and
the live codebase. It synthesizes a timeline of decisions and the current state of
the code. Run it before starting work on anything non-trivial so you know what
you're walking into.

> **Tip:** `/recon` is a natural precursor to `/doc-feature`. Use `/recon` to
> understand what exists and how it got there, then `/doc-feature` to produce the
> canonical reference doc.

---

## Usage

```
/recon <keyword or topic>
/recon <keyword or topic> --depth shallow
/recon <keyword or topic> --depth full
```

Examples:
```
/recon auth
/recon stripe webhooks --depth full
/recon PDF export
/recon PROGRESS.md --depth shallow
```

If no argument is given, ask: **"What topic or feature should I research?"**

**Depth flag** (optional):
- `--depth shallow` *(default)* — commit messages, file list, and brief code skim
- `--depth full` — full diff content, complete file reads, and exhaustive synthesis

> ⚠️ `--depth full` on an active repo with many PRs can be slow and context-heavy.
> Use it when you need the full picture and have a narrowly scoped keyword.

---

## What this does

### Step 0 — Internal docs check (before any API calls)

Before hitting the GitHub API or git history, search local knowledge sources for
the keyword. This saves tokens and surfaces existing documentation immediately.

**0a — Feature docs:**
```bash
REPO=$(git rev-parse --show-toplevel)
DOCS_DIR="$REPO/docs/features"
ls "$DOCS_DIR/" 2>/dev/null | grep -i "<keyword>" || true
grep -ril "<keyword>" "$DOCS_DIR/" 2>/dev/null || true
```
If a matching feature doc exists, read its `## Summary` and `## Current state`
sections and display them. Tell the user:
> "Found an existing feature doc: `docs/features/<slug>.md` (last updated: [date]).
> Showing summary below. Continue with full PR/commit sweep? [yes / no]"
If no: skip Steps 1–3, jump to Step 4 (synthesize from the doc). If yes: continue.

**0b — DECISIONS.md:**
```bash
grep -i "<keyword>" "$RIG_DIR/memory/DECISIONS.md" 2>/dev/null | head -10 || true
```
If matches found, show the relevant decision entries.

**0c — ERRORS.md:**
```bash
grep -i "<keyword>" "$RIG_DIR/memory/ERRORS.md" 2>/dev/null | head -10 || true
```
If matches found, show the relevant error/gotcha entries. These are high-signal —
if the keyword has a known pitfall logged, surface it early.

**0d — PROGRESS.md:**
```bash
grep -i "<keyword>" "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null | head -5 || true
```
Show any matching progress entries (indicates recent work on this topic).

If **nothing was found** in any internal source: proceed silently to Step 1.
If **something was found**: display it, then ask whether to continue with the
external sweep. The user may already have enough context.

---

### Step 1 — Keyword sweep: merged PR history

Search merged PR titles and bodies for the keyword(s):

```bash
gh pr list --state merged --limit 200 --json number,title,body,mergedAt \
  | jq '.[] | select(.title + .body | ascii_downcase | contains("<keyword>"))'
```

For each matching PR, collect: PR number, title, merge date, and a one-line summary
of what changed.

> **Rate limit note:** GitHub API calls are subject to rate limits. If the search
> returns a rate-limit error, wait 60 seconds and retry. Report the delay to the user.

---

### Step 2 — Commit history sweep

Search commit messages on `main` (or the default branch) for the keyword:

```bash
git log --oneline --all | grep -i "<keyword>"
```

Collect matching commits: hash, date, message. Cross-reference against the PRs
found in Step 1 to identify commits not covered by any PR (direct-to-main commits
or commits on branches that didn't have a PR).

---

### Step 3 — Live codebase sweep

Search the current codebase for the keyword in file names and contents:

```bash
# File name matches
find . -name "*<keyword>*" -not -path "*/node_modules/*" -not -path "*/.git/*"

# Content matches (top files by hit count)
grep -rl --include="*.md" --include="*.ts" --include="*.js" \
  --include="*.py" --include="*.sh" "<keyword>" . \
  | grep -v "node_modules\|\.git"
```

At `--depth shallow`: read only the most relevant 3–5 files (highest hit count or
most directly named for the topic). At `--depth full`: read all matching files.

---

### Step 4 — Synthesize

Produce a structured report with three sections:

#### Evolution timeline
A chronological list of the meaningful changes: when they happened, what PR/commit
drove them, and what decision or shift each represents. Focus on *why* over *what* —
the diff shows what; the timeline should explain the thinking.

```
[YYYY-MM-DD] PR #N — [title]
  → [What changed and why — 1–2 sentences]

[YYYY-MM-DD] commit <hash>
  → [What changed and why]
```

#### Current state
A concise description of how the topic/feature works *right now*:
- Key files and their roles
- How it's triggered / entry points
- Any notable configuration or flags
- Known gotchas visible in the code

#### Open questions / gaps
Things the research surfaced but couldn't confirm. Flag anything that looks
inconsistent, undocumented, or potentially stale.

---

### Step 5 — Suggest next steps

Based on the synthesis, suggest one of:

- **`/doc-feature <topic>`** — if no feature doc exists yet and the feature is
  complex enough to warrant one
- **`/task`** — if the research surfaced a clear piece of work
- **Nothing** — if the research was purely informational and no action is needed

State the suggestion explicitly. Don't act on it — let the user decide.

---

## Notes

- `/recon` is read-only. It never writes to any file, creates commits, or opens issues.
- If the keyword is very broad (e.g. "auth", "user"), warn the user and ask if they
  want to narrow it before proceeding.
- If the repo has no merged PRs yet (fresh project), skip Step 1 and note it.
- The session log at `/tmp/the-rig-session-<project>.log` is not part of the recon scope —
  it's ephemeral and not meaningful for evolution research.
