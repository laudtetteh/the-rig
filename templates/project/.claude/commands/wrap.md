# Command: /wrap

Trigger this command before ending a session or when approaching a context limit.

## What this does

Performs the session-end housekeeping that prevents state loss between sessions:

1. Writes (overwrites) `.rig/memory/CONTEXT_SNAPSHOT.md` with full current project state
2. Ensures `.rig/memory/PROGRESS.md` is up to date — expands any auto-stubbed entries
3. **Trims `.rig/memory/PROGRESS.md`** if it has grown beyond 20 entries (see Trim step below)
4. **Prunes stale session-end markers** from `PROGRESS.md` (see Marker prune step below)
5. Checks `.rig/memory/ERRORS.md` — prompts you to log anything unexpected; **checks archive before logging** to prevent duplicate entries (see ERRORS.md logging step below)
6. **Self-improvement check** — scans for Rig workflow gaps and logs them to `.rig/memory/RIG_GAPS.md`
7. **Trims `.rig/memory/ERRORS.md`** if it has grown beyond 30 entries (see Trim step below)
8. Reports what's in `.rig/tasks/active/` so you know what's in flight
9. **Suggests a session name** — derives a name from this session's work via `/session-name` logic (see Session naming step below)
10. Surfaces the next priority from `.rig/tasks/backlog/` and asks: "What's next?"
11. **Cleans up housekeeping flags** — deletes `.rig/memory/.wrap-needed` if present

## Usage

```
/wrap
```

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

## Concurrent session guard — run before anything else

Check for a `.wrap-in-progress` sentinel that would indicate another session is
already running `/wrap`:

```bash
WRAP_LOCK="$RIG_DIR/memory/.wrap-in-progress"
if [[ -f "$WRAP_LOCK" ]]; then
  echo "⚠️  Another /wrap is already running (or a previous run crashed)."
  echo "   Lock file: $WRAP_LOCK"
  echo "   If no other session is active, delete it and retry:"
  echo "   rm '$WRAP_LOCK'"
  exit 1
fi
touch "$WRAP_LOCK"
```

Create the sentinel immediately. Delete it at the very end of `/wrap` (step 11,
after flag cleanup). If `/wrap` fails mid-run, the sentinel will persist — the
user must delete it manually. This is intentional: a stale lock is safer than
silent corruption.

The sentinel file is gitignored alongside other `.rig/memory/` runtime files.

---

## Git state check — run first, before anything else

Before writing any files, run:

```bash
git branch --show-current
git status --short
git log --oneline -3
```

Report the results briefly:

> "Branch: `feat/my-feature` | 2 uncommitted changes | Last commit: `abc1234 feat: add thing`"

**If there are uncommitted changes to non-Rig files:** surface them explicitly.
The user may have forgotten to commit something before ending the session. Ask:
> "There are uncommitted changes to `[files]`. Should I include them in a commit
> before wrapping, or proceed with wrap as-is?"
Wait for the answer before continuing.

**If the repo is clean:** note it and proceed directly.

Run this:
- Before closing Claude Code for the day
- When the conversation is getting long and you want a clean handoff point
- Before switching to a different task or project
- Any time you want to ensure a future session can pick up exactly where you left off

## Trim step — PROGRESS.md

After updating `.rig/memory/PROGRESS.md`, count the number of `## ` entry headers in the file.

**If the count is 20 or fewer:** nothing to do.

**If the count exceeds 20:** tell the user:

> "`.rig/memory/PROGRESS.md` has [N] entries. I'll move the oldest [N-20] to
> `.rig/memory/PROGRESS_archive.md` to keep session startup lean. The archive is
> gitignored — history is preserved locally but won't be loaded at session start.
> Trim now?"

If the user confirms:
1. Identify the oldest entries (bottom of the file, since entries are newest-first)
2. Prepend them to `.rig/memory/PROGRESS_archive.md` (create if absent)
3. Remove them from `.rig/memory/PROGRESS.md`, leaving the 20 most recent entries
4. **Append a trim stub** at the bottom of the trimmed `PROGRESS.md`:
   ```
   <!-- archived YYYY-MM-DD: [N] entries moved to PROGRESS_archive.md. Topics: [3–6 word comma-separated summary of what was archived, e.g. "CI setup, manifest tracking, stealth mode, command rename"] -->
   ```
   This lets future sessions know what history exists in the archive without loading it.
5. Confirm: "`.rig/memory/PROGRESS.md` trimmed to 20 entries. Archive: `.rig/memory/PROGRESS_archive.md`"

Never trim without confirmation. Never delete entries — only move them.

---

## Marker prune step — PROGRESS.md session-end markers

`stop.sh` appends `<!-- session-end YYYY-MM-DD HH:MM -->` after every agent turn.
Over time these accumulate in PROGRESS.md without bound — they are not covered by
the `## ` header trim above.

After the PROGRESS.md trim step, remove all but the **most recent** session-end
marker from PROGRESS.md:

1. Find all lines matching `<!-- session-end`
2. Keep the last one (most recent)
3. Delete all earlier ones in-place
4. Log: "Pruned [N] stale session-end markers from PROGRESS.md" — only if N > 0

This is automatic — no user confirmation needed (these are housekeeping comments,
not content).

---

## Feature doc freshness check

After updating PROGRESS.md, run a lightweight check to detect if any commits this
session touched files covered by documented features.

**How:**

1. Resolve `$RIG_DIR` and `$DOCS_DIR` (see RIG_DIR resolution block above).
2. If `$DOCS_DIR` doesn't exist or has no `.md` files (other than `README.md`): skip silently.
3. Get commits from this session — use the same session boundary logic as the Session naming step (session-end markers or snapshot date).
4. Collect all files changed across those commits:
   ```bash
   git log --name-only --format="" <boundary>..HEAD | sort -u
   ```
5. For each feature doc, check if any changed file path overlaps with the paths in its `## Entry points` section.
6. If overlap found, note:
   > "Feature docs that may need a refresh after this session's changes:
   > - `[feature name]` — run `/refresh-feature-doc <name>`"
   Advisory only — do not block the rest of /wrap.
7. If no overlap or no docs: skip silently.

---

## Self-improvement check

After the feature doc freshness check, run a brief Rig retrospective:

**Scan ERRORS.md** for entries that describe friction with The Rig's own workflow
(not project bugs). Ask: did anything about The Rig slow you down, produce wrong
output, or feel missing or broken this session?

For each Rig-related friction point — whether from ERRORS.md or from this session —
that is **not already in** `.rig/memory/RIG_GAPS.md`:

1. Append a new entry to `.rig/memory/RIG_GAPS.md` using this format:
   ```
   ## [YYYY-MM-DD] — [short title]

   **Category**: bug | friction | missing-feature | improvement
   **Severity**: blocking | annoying | nice-to-have
   **Workflow**: [which command/process/hook triggered this]
   **Observation**: [what happened or what was missing]
   **Suggested fix**: [concrete suggestion, or "unclear"]
   ```
2. Note in your wrap-up summary: "Logged [N] new gap(s) to `.rig/memory/RIG_GAPS.md`."

If there is nothing to log, skip silently — do not mention this step.

> **Why this matters:** The Rig improves by collecting friction signals from real use.
> Logging gaps during `/wrap` ensures they don't get lost. Use `/rig-gaps` to compile
> and submit them to The Rig dev session.

---

## ERRORS.md logging step

Ask: "Did anything unexpected, buggy, or footgun-worthy happen this session that isn't
already documented?"

If yes, **before creating a new entry**:

1. Search the active `.rig/memory/ERRORS.md` for a similar entry (keyword match is enough).
2. If `ERRORS_archive.md` exists, do a quick search there too:
   ```bash
   grep -i "[keyword]" "$RIG_DIR/memory/ERRORS_archive.md" 2>/dev/null | head -5
   ```
3. **If a matching entry exists** (in either file): update or append to it rather than
   creating a duplicate. Note the recurrence date. Duplicates dilute the pitfall log.
4. **If genuinely new**: add a new `## ` entry at the top of `ERRORS.md`.

> **Why check the archive?** Entries trimmed past the 30-entry limit move to
> `ERRORS_archive.md` and are never loaded at session start. Without this check,
> the same pitfall can be re-logged repeatedly across trims, losing the signal that
> this is a *recurring* problem rather than an isolated one.

---

## Trim step — ERRORS.md

After checking `.rig/memory/ERRORS.md`, count the number of `## ` entry headers in the file.

**If the count is 30 or fewer:** nothing to do.

**If the count exceeds 30:** tell the user:

> "`.rig/memory/ERRORS.md` has [N] entries. I'll move the oldest [N-30] to
> `.rig/memory/ERRORS_archive.md` to keep session startup lean. The archive is
> gitignored — pitfall history is preserved locally but won't load at session start.
> Trim now?"

If the user confirms:
1. Identify the oldest entries (bottom of the file, since entries are newest-first)
2. Prepend them to `.rig/memory/ERRORS_archive.md` (create if absent)
3. Remove them from `.rig/memory/ERRORS.md`, leaving the 30 most recent entries
4. **Append a trim stub** at the bottom of the trimmed `ERRORS.md`:
   ```
   <!-- archived YYYY-MM-DD: [N] entries moved to ERRORS_archive.md. Categories: [3–6 word comma-separated summary, e.g. "bats non-interactive, gitleaks path, Husky sh-e, worktree writes"] -->
   ```
   This lets the agent grep for a category keyword without loading the archive, and
   signals to the ERRORS.md logging step that the archive should be checked.
5. Confirm: "`.rig/memory/ERRORS.md` trimmed to 30 entries. Archive: `.rig/memory/ERRORS_archive.md`"

Never trim without confirmation. Never delete entries — only move them.

---

## Active tasks — in-flight state capture

After ERRORS.md cleanup and before session naming, read `.rig/tasks/active/`.

**If empty:** note "No tasks in flight" and continue.

**If non-empty:** for each active task file, write a `## Resuming from` section
into CONTEXT_SNAPSHOT.md that captures enough state for the next session to
resume without re-reading the conversation. The section must include:

```
## Resuming from: [task-slug]

**Task goal:** [one sentence from ## Goal]
**What's done:** [bullet list of completed sub-steps or commits in this session]
**What's pending:** [bullet list of remaining work to reach acceptance criteria]
**Decisions made this session:** [any non-obvious choices made during implementation]
**Files touched so far:** [list — use git diff HEAD --name-only or from memory]
**Next action:** [the very next concrete step the next session should take]
```

Do not write "see task file" or vague summaries. The next session must be able to
pick up exactly where you left off from this section alone.

If the task has a `## Batches` section, include which batches are complete and
which are pending.

This section is written into CONTEXT_SNAPSHOT.md alongside the rest of the
snapshot — overwrite the previous version.

---

## Session naming step

After reporting active tasks, derive a session name from this session's work and
output it as a suggestion. Do **not** apply it automatically — present it for
the user to confirm or tweak.

### How to determine "this session's work"

**Your conversation context is the primary signal.** Before reading any files,
enumerate directly what was done in this session: PRs merged or opened, tasks
completed, issues created, commands run, significant files changed. You were
here — this is the most accurate record of what the session name should reflect.

Do not use today's date as a boundary — it breaks for sessions that span midnight
or are resumed days later.

Use file signals as cross-reference only — to catch work that may have compacted
out of the context window, not to override what you already know:

1. **`<!-- session-end -->` markers in PROGRESS.md** (cross-reference)
   The `stop.sh` hook appends `<!-- session-end YYYY-MM-DD HH:MM -->` automatically.
   Entries above the most recent marker are candidates to correlate with your context.

2. **`Last updated:` datetime in the previous CONTEXT_SNAPSHOT** (boundary fallback)
   If markers are absent or ambiguous, use the snapshot's `**Last updated:**` datetime
   as an approximate session-start boundary when scanning PROGRESS.md entries.

3. **PROGRESS.md ordering** (last resort for compacted context)
   If context window is short and you cannot recall specifics, take entries at the
   top of PROGRESS.md that plausibly match this session and stop at the prior boundary.

**If conversation context and file signals conflict, trust the conversation.**
Files may be stale, markers may be missing or duplicated across tabs. Your direct
knowledge of this session is authoritative.

### Check for an existing session name

Read the `**Session name:**` field from CONTEXT_SNAPSHOT.md (the previous
snapshot, before this /wrap rewrites it).

- **If blank / absent:** suggest a fresh session name covering all this session's work.
- **If already set:** the session was named in a prior /wrap or by the user directly.
  Suggest **appending** new work to the existing name rather than replacing it:

  > **Session already named:** `fix step accordion layout #184`
  > **New work this wrap:** `feat custom-permissions #152`
  > **Updated suggestion:** `fix step accordion layout #184 | feat custom-permissions #152`

### Build the name

Count one "unit" per merged PR, completed task, or significant fix. Use the
**tiered format** from `/session-name` (same logic — see that command for full detail):

- **≤5 units:** `type short-desc #N | type short-desc #N | ...`
- **6–15 units:** `type(area, area) | type(area) x3 | type x2`
- **16+ units:** `sprint: N issues · feat/X fix/Y chore/Z · #A–#B`

Keep under ~100 characters. Drop smallest groups if over.

### Examples

```
fix step accordion layout #184 | fix h3.steps remaining partials #186
feat(auth, dashboard) | fix(billing x4, ui) | chore x3
sprint: 23 issues · feat/4 fix/15 chore/4 · #130–#152
```

### Output

> **Suggested session name:**
> `fix step accordion layout #184 | fix h3.steps remaining partials #186`

Then invite the user to apply it:

> To apply this name, run `/session-name` or say "use that name".

After the user confirms, **update the `**Session name:**` field in
`.rig/memory/CONTEXT_SNAPSHOT.md`** to match. This is how future /wrap calls
detect an existing name and suggest appends instead of replacements.

If nothing meaningful shipped this session (pure exploration, no PRs, no
completions), skip this step silently.

---

## Flag cleanup (step 11)

After suggesting a session name and before asking "What's next?", run both cleanups:

```bash
# Clear the wrap-needed flag
rm -f "$RIG_DIR/memory/.wrap-needed" 2>/dev/null || true

# Release the concurrent session lock
rm -f "$RIG_DIR/memory/.wrap-in-progress" 2>/dev/null || true
```

Log: "`.wrap-needed` cleared. Concurrent session lock released."

`.wrap-needed` signals to `stop.sh` that `/wrap` has run and no flag should be
written until the next commit creates new unexpanded stubs.
`.wrap-in-progress` signals to concurrent sessions that this wrap is complete.

---

## Notes

- `.rig/memory/CONTEXT_SNAPSHOT.md` is gitignored — it lives on disk only, never committed
- `.rig/memory/PROGRESS_archive.md` and `.rig/memory/ERRORS_archive.md` are gitignored — full history on disk, not in the repo
- Always **overwrite** the snapshot, never append to it; it represents current state, not history
- History belongs in `.rig/memory/PROGRESS.md` (recent) and `PROGRESS_archive.md` (older); same pattern for `ERRORS.md` / `ERRORS_archive.md`
- If a task is in progress but not done, use the "Active tasks — in-flight state capture" step above to write a structured `## Resuming from` section into CONTEXT_SNAPSHOT. Vague notes are not sufficient — the next session must be able to resume from the snapshot alone.
