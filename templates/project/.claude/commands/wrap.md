# Command: /wrap

Trigger this command before ending a session or when approaching a context limit.

## What this does

Performs the session-end housekeeping that prevents state loss between sessions:

1. Writes (overwrites) `.rig/memory/CONTEXT_SNAPSHOT.md` with full current project state
2. Ensures `.rig/memory/PROGRESS.md` is up to date — expands any auto-stubbed entries
3. **Trims `.rig/memory/PROGRESS.md`** if it has grown beyond 20 entries (see Trim step below)
4. **Prunes stale session-end markers** from `PROGRESS.md` (see Marker prune step below)
5. Checks `.rig/memory/ERRORS.md` — prompts you to log anything unexpected; **checks archive before logging** to prevent duplicate entries (see ERRORS.md logging step below)
6. Checks for significant architectural, product, or process decisions made this session and logs new ones to `.rig/memory/DECISIONS.md` (see DECISIONS.md logging step below)
7. **Self-improvement check** — scans for Rig workflow gaps and logs them to `.rig/memory/RIG_GAPS.md`
8. **Trims `.rig/memory/ERRORS.md`** if it has grown beyond 30 entries (see Trim step below)
9. Reports what's in `.rig/tasks/active/` so you know what's in flight
10. **Suggests a session name** — derives a name from this session's work via `/session-name` logic (see Session naming step below)
11. Surfaces the next priority from `.rig/tasks/backlog/` and asks: "What's next?"
12. **Cleans up housekeeping flags** — deletes `.rig/memory/.wrap-needed` if present
13. **(opt-in) Auto-scans JSONL transcripts** for frequent Bash patterns and appends new `permissions.allow` entries to `.claude/settings.json` — enable with `touch $RIG_DIR/memory/.fewer-prompts-enabled`

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

Check for a `.snapshot-write-in-progress` sentinel that would indicate another session is
already running `/wrap` or `/post-merge`:

```bash
SNAP_LOCK="$RIG_DIR/memory/.snapshot-write-in-progress"
if [[ -f "$SNAP_LOCK" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$SNAP_LOCK" 2>/dev/null || stat -f %m "$SNAP_LOCK" 2>/dev/null || echo 0) ))
  if [[ "$LOCK_AGE" -gt 1800 ]]; then
    echo "⚠️  Stale lock detected (age: ${LOCK_AGE}s). Auto-removing and proceeding."
    rm -f "$SNAP_LOCK"
  else
    echo "⚠️  A snapshot write is already in progress (/wrap or /post-merge in another session, lock age: ${LOCK_AGE}s)."
    echo "   If the other session is no longer active: rm '$SNAP_LOCK'"
    exit 1
  fi
fi
if ! touch "$SNAP_LOCK"; then
  echo "Unable to write Rig memory lock: $SNAP_LOCK"
  echo "For Codex with an external .rigpath, request scoped write approval for $RIG_DIR and retry /wrap."
  echo "No memory files were changed."
  exit 1
fi
```

Create the sentinel immediately. Delete it at the very end of `/wrap` (step 12,
after flag cleanup). Locks older than 30 minutes are automatically expired on the
next run — they are from crashed sessions. Locks under 30 minutes block and require
the other session to finish (or the lock deleted manually if that session is gone).

If creating the sentinel fails with `Operation not permitted`, stop immediately.
This commonly means Codex is running in a project whose `.rigpath` points outside
the workspace writable roots. Request one scoped approval for the resolved
`$RIG_DIR` before retrying; do not continue with partial memory writes.

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

---

## Wrap report step

**Run this after the git state check and any uncommitted-changes gate, before writing anything.**
This report-first requirement applies equally to Claude `/wrap` and the generated
Codex `$wrap` skill. If you are adapting the workflow manually in Codex, print
the report before any memory writes; if session identity is unresolved, include
`Session: unresolved — no final session-file write performed` in the report and
do not silently perform a partial wrap.

### Collection phase

Gather all findings silently — no output yet:

1. **PROGRESS.md entry count** — note if trim is needed (count > 20) and how many would be archived
2. **Session-end markers** — count stale markers (all but the most recent)
3. **"This session" summary** — from conversation context: PRs merged or opened, tasks completed, issues resolved, significant changes made. Conversation context is the primary signal; PROGRESS.md markers are cross-reference only.
4. **ERRORS.md additions** — infer from session context whether any unexpected behaviors, footguns, or non-obvious pitfalls should be added (see ERRORS.md logging step below)
5. **DECISIONS.md additions** — infer whether the session produced any significant adopted architectural, product, or process decisions (see DECISIONS.md logging step below)
6. **Feature doc overlaps** — files changed this session vs. documented feature entry points (see Feature doc freshness step below)
7. **Active tasks** — read `.rig/tasks/active/`
8. **Session identity** — run `bin/rig session resolve --json`; extract its session file,
   `anchor`, and `tentative_name`. Stop on ambiguous identity.
9. **Skipped post-merge status** — if `/post-merge` was requested in the same turn but
   no merge is applicable, record the skip reason and next action.

### Report

Print a single structured report before executing anything:

```
## Wrap report — [branch] — [date]

**This session:**
- PR #N merged: type(scope): short description
- [other work items]
(omit this section if nothing meaningful shipped this session)

**PROGRESS.md:** [N entries → trimming X to archive (topics: CI setup, stealth mode, ...) | N entries, no trim needed]
**Session-end markers:** [pruned N stale markers | none to prune]
**ERRORS.md:** [N new entries: short-title-1, short-title-2 | no new entries]
**DECISIONS.md:** [N new entries: short-title-1, short-title-2 | no new entries]
**Feature docs:** [⚠ overlap detected — run /refresh-feature-doc X | no overlaps]
**Active tasks:** [task-slug | none]
**Post-merge:** [skipped — reason and next action | not requested]

**Session:** [anchor: UUID | tentative: "..." | suggested final: "type desc #N | type desc #N" | nothing meaningful shipped, skipped]
```

### Execution

After printing the report, **execute all automatic actions without further prompts**:

- Trim PROGRESS.md if count > 20
- Prune stale session-end markers
- Add inferred ERRORS.md entries (if any)
- Add inferred DECISIONS.md entries (if any)
- Trim ERRORS.md if count > 30
- Write CONTEXT_SNAPSHOT.md (project state only — no Session name field)
- Write final session name to session file and move to `sessions/done/` — only if user confirms the suggested name

The session name is the only action requiring explicit user input. Everything else executes immediately after the report is printed.

---

## Trim step — PROGRESS.md

After updating `.rig/memory/PROGRESS.md`, count the number of `## ` entry headers in the file.

**If the count is 20 or fewer:** nothing to do.

**If the count exceeds 20:** note in the Wrap report, then execute automatically after the report is printed:
1. Identify the oldest entries (bottom of the file, since entries are newest-first)
2. Prepend them to `.rig/memory/PROGRESS_archive.md` (create if absent)
3. Remove them from `.rig/memory/PROGRESS.md`, leaving the 20 most recent entries
4. **Append a trim stub** at the bottom of the trimmed `PROGRESS.md`:
   ```
   <!-- archived YYYY-MM-DD: [N] entries moved to PROGRESS_archive.md. Topics: [3–6 word comma-separated summary of what was archived, e.g. "CI setup, manifest tracking, stealth mode, command rename"] -->
   ```
   This lets future sessions know what history exists in the archive without loading it.

Never delete entries — only move them.

---

## Marker prune step — PROGRESS.md session-end markers

`stop.sh` appends `<!-- session-end YYYY-MM-DD HH:MM sid:UUID -->` after every agent turn
(where `UUID` is the session anchor returned by `bin/rig session resolve --json`;
omitted on pre-v1.21.0 installs that lack the UUID system).
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

## PR description freshness step

After the feature doc freshness check, verify that the open PR for this branch
reflects all commits that have landed since it was opened.

**How:**

1. Check for an open PR on the current branch:
   ```bash
   CURRENT_BRANCH=$(git branch --show-current)
   PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --json number,title,body,labels --limit 1 2>/dev/null || echo "[]")
   PR_NUMBER=$(echo "$PR_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['number'] if d else '')" 2>/dev/null || echo "")
   ```
   If `PR_NUMBER` is empty (no open PR or `gh` unavailable): skip silently.

2. Get the PR body:
   ```bash
   PR_BODY=$(echo "$PR_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['body'] if d else '')" 2>/dev/null || echo "")
   ```

3. Get commits on this branch not yet in base:
   ```bash
   BASE=$(grep "^base-branch:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
   BASE="${BASE:-main}"
   git log "origin/$BASE"..HEAD --format="%s" 2>/dev/null
   ```

4. For each commit subject, skip housekeeping types: `chore(memory)`, `chore(post-merge)`,
   `chore(release)`, `chore(rig)`. For the rest, do a case-insensitive substring check
   against the PR body.

5. **If any non-housekeeping commits are not reflected in the PR body**, surface in the
   wrap summary:
   > "PR #[N] description may be stale — [N] commit(s) not in description:
   >   - type(scope): commit subject
   >   - ...
   > Update PR description? [yes / no]"

   If the user says yes: append an `## Additional changes` section to the PR body
   listing the unrepresented commits. Show the proposed addition before editing:
   ```bash
   gh pr edit "$PR_NUMBER" --body-file /tmp/wrap-pr-body.md
   ```

6. If all commits are reflected, or this is a housekeeping-only session: skip silently.

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

Based on this session's context — tool output, errors observed, unexpected behaviors, non-obvious footguns encountered — **infer** whether anything happened that is not already documented in ERRORS.md. Do not ask the user; derive from what was observed during the session.

If there are entries to add, **before creating any new entry**:

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

## DECISIONS.md logging step

Based on this session's context, infer whether a **significant adopted** architectural,
product, or process decision was made. A decision is significant when it is non-obvious,
closes off meaningful alternatives, or would surprise a future reader. Discussion of an
option, a rejected proposal, routine implementation detail, or a choice not actually
adopted is not a decision to log.

For each significant adopted decision:

1. Search `.rig/memory/DECISIONS.md` for the title, chosen approach, and rejected
   alternatives. Treat semantically equivalent entries as duplicates even when wording
   differs.
2. If the decision is already recorded, do not add another entry. Update the existing
   entry only when this session materially changed its rationale or consequences.
3. If it is genuinely new, add an entry at the top of `DECISIONS.md`, below its
   introductory text and format example, using the file's standard format:
   ```markdown
   ## [YYYY-MM-DD] — [Short title]

   **Context**: Why this decision needed to be made
   **Decision**: What was chosen
   **Rejected**: What was considered and not chosen
   **Rationale**: Why
   **Consequences**: What this decision implies going forward
   ```
   When adding the first decision, remove the `No decisions logged yet` placeholder.
4. Include the resulting count and short titles in the Wrap report.

If no significant adopted decision occurred, report `no new entries` and make no change.
Do not ask for confirmation and do not turn decision logging into a required gate; it is
part of the automatic actions that follow the existing Wrap report.

---

## Trim step — ERRORS.md

After checking `.rig/memory/ERRORS.md`, count the number of `## ` entry headers in the file.

**If the count is 30 or fewer:** nothing to do.

**If the count exceeds 30:** note in the Wrap report, then execute automatically after the report is printed:
1. Identify the oldest entries (bottom of the file, since entries are newest-first)
2. Prepend them to `.rig/memory/ERRORS_archive.md` (create if absent)
3. Remove them from `.rig/memory/ERRORS.md`, leaving the 30 most recent entries
4. **Append a trim stub** at the bottom of the trimmed `ERRORS.md`:
   ```
   <!-- archived YYYY-MM-DD: [N] entries moved to ERRORS_archive.md. Categories: [3–6 word comma-separated summary, e.g. "bats non-interactive, gitleaks path, Husky sh-e, worktree writes"] — NEW ENTRIES GO ABOVE THIS LINE -->
   ```
   This lets the agent grep for a category keyword without loading the archive, and
   signals to the ERRORS.md logging step that the archive should be checked.
   The `NEW ENTRIES GO ABOVE THIS LINE` marker is load-bearing: it prevents future
   sessions from appending entries below the stub (which inverts newest-first order
   and breaks the next trim's direction detection).

Never delete entries — only move them. ERRORS.md is always newest-first: add new
`## ` entries at the **top**, never below the archived stub.

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

After reporting active tasks, derive a final session name from this session's work
and output it as a suggestion. Do **not** apply it automatically — present it for
the user to confirm or tweak.

### Step 1 — Find this session's UUID and tentative name

Read `$RIG_DIR/rules/session-naming.md` completely first. Its session-local
evidence rules are authoritative for this suggestion.

```bash
REPO=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -f "$REPO/.rigpath" ]]; then RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath"); else RIG_DIR="$REPO/.rig"; fi
SESSION_JSON=$("$REPO/bin/rig" session resolve --json) || {
  echo "Unable to resolve this session unambiguously; stop before writing snapshot state."
  exit 1
}
SESSION_FILE=$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
SESSION_UUID=$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")')
TENTATIVE_NAME=$(SESSION_F="$SESSION_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); print(d.get("names",{}).get("tentative") or d.get("tentative_name") or "")')
```

### Step 2 — Collect this session's work

**Primary signal: your conversation context.** Enumerate directly what was done
this session — PRs merged or opened, tasks completed, issues resolved. This is
always the most accurate signal. The tentative name (if set) is a pre-compaction
anchor from earlier in this session — use it as a starting point if context was lost.

**Every `## ` entry header you write to PROGRESS.md must include `<!-- sid:UUID -->`
at the end of the line** (read UUID from the resolver output above). This is
what enables UUID-keyed session attribution.

**File signal — UUID-keyed PROGRESS entries:**
```bash
grep "^## .*<!-- sid:${SESSION_UUID} -->" "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null || true
```

**If conversation context and file signals conflict, trust the conversation.**
Never use `CONTEXT_SNAPSHOT.md`, legacy markers, unrelated session files,
other-session UUID entries, or general project history as naming evidence. An
unresolved raw launch fails closed before any name is proposed or written.

### Step 3 — Build the name

If a `tentative_name` exists: use it as the base. If the session delivered exactly
what it described, confirm it (drop `[tentative]`). If scope changed, update it.
If no tentative name: derive from scratch.

Count one "unit" per merged PR, completed task, or significant fix. Use the tiered format:

- **≤5 units:** `type short-desc #N | type short-desc #N | ...`
- **6–15 units:** `type(area, area) | type(area) x3 | type x2`
- **16+ units:** `sprint: N issues · feat/X fix/Y chore/Z · #A–#B`

Keep under ~100 characters.

### Step 4 — Present and confirm

> **Suggested session name:**
> `fix(mobile): Expo Go runtime fixes + PR #360 merge [#359]`

> To apply: say "use that name", "ship it", or "lgtm".

### Step 5 — After confirmation: write to session file, move to done/

Use the shared atomic writer. Pass the confirmed name as one opaque argument;
never interpolate it into shell or Python source.

```bash
# Clear only this exact session's wrap obligation while its active record is
# still resolvable. --adopt-legacy explicitly migrates an older unscoped marker.
"$REPO/bin/rig" session obligation clear --kind wrap --adopt-legacy --json
"$REPO/bin/rig" session-name set --final --complete "$CONFIRMED_NAME"
```

**Do NOT write Session name to CONTEXT_SNAPSHOT.md.** CONTEXT_SNAPSHOT contains
project state only (branch, PRs, roadmap, key facts). Session names live in session files.

### Step 6 — Surface orphan sessions

After completing this session, scan `$SESSION_DIR` for remaining `.json` files
(not in `done/`) with `"status": "active"`:

```bash
for f in "$SESSION_DIR"/session-*.json; do
  [[ -f "$f" ]] || continue
  STATUS=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('lifecycle',{}).get('state') or d.get('status',''))" 2>/dev/null)
  STARTED=$(python3 -c "import json; print(json.load(open('$f')).get('started_at','?'))" 2>/dev/null)
  NAME=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('names',{}).get('tentative') or d.get('tentative_name') or d.get('anchor','?'))" 2>/dev/null)
  if [[ "$STATUS" == "active" ]]; then
    echo "⚠ Orphan session (active, unwrapped): $NAME (started $STARTED, file: $(basename $f))"
  elif [[ "$STATUS" == "complete" ]]; then
    # complete but not moved to done/ — write step finished but rename was interrupted
    echo "⚠ Orphan session (complete, not moved to done/): $NAME (file: $(basename $f))"
    echo "   Move manually: mv '$f' '$DONE_DIR/'"
  fi
done
```

Surface any found to the user. They may be active in another tab — do not delete
them without asking.

If nothing meaningful shipped this session (pure exploration, no PRs, no completions),
skip the naming step silently but still run the orphan scan.

---

## Flag cleanup (step 12)

After suggesting a session name and before asking "What's next?", run both cleanups:

```bash
# The exact wrap obligation was cleared in Step 5 before the record moved to done/.

# Release the concurrent session lock
rm -f "$RIG_DIR/memory/.snapshot-write-in-progress" 2>/dev/null || true

# Clear this session's compact checkpoint — the full snapshot supersedes it
rm -f "$RIG_DIR/memory/.compact-checkpoint-${PPID}.md" 2>/dev/null || true

# Clear /tmp UUID sentinel (session file already moved to done/ by naming step)
# The atomic session-name writer removes the matching legacy sentinel on completion.
```

Log: "`.wrap-needed` cleared. Concurrent session lock released. Compact checkpoint cleared. UUID sentinel cleared."

`.wrap-needed` may contain multiple `anchor=` entries. The exact-session clear
removes only the current anchor and deletes the reminder only when no scoped or
unadopted legacy obligation remains.
`.snapshot-write-in-progress` signals to concurrent sessions that this snapshot write is complete.
`.compact-checkpoint-{PPID}.md` is cleared so the next session reads the authoritative
`CONTEXT_SNAPSHOT.md` rather than a stale post-compaction checkpoint.

---

## Transcript pruning (opt-in)

After flag cleanup, use the current agent identity already established by the active
Claude command or Codex skill/session (the shared #342/#343 behavior). Do not add a
second detector based on installed files, processes, or transcript contents. Replace
`CURRENT_AGENT` below with the literal `claude` or `codex` for that identity, then run
the block.

The `transcript-retention-days:` field in `$REPO/CLAUDE.md` enables age-based pruning
when it is a positive integer. Claude transcripts live under the documented
`$HOME/.claude/projects` location. Codex active sessions live under
`${CODEX_HOME:-$HOME/.codex}/sessions`; never read or parse their rollout contents.
Codex `archived_sessions` is excluded unless
`transcript-retention-include-archived: true` explicitly opts it in.

```bash
# transcript-pruning:start
TRANSCRIPT_AGENT="CURRENT_AGENT"
RETENTION_DAYS=$(grep "^transcript-retention-days:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
INCLUDE_ARCHIVED=$(grep "^transcript-retention-include-archived:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

if [[ ! "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Transcript pruning skipped: transcript persistence retention is disabled."
else
  TRANSCRIPT_DIRS=()
  case "$TRANSCRIPT_AGENT" in
    claude)
      TRANSCRIPT_DIRS+=("$HOME/.claude/projects")
      ;;
    codex)
      CODEX_TRANSCRIPT_HOME="${CODEX_HOME:-$HOME/.codex}"
      TRANSCRIPT_DIRS+=("$CODEX_TRANSCRIPT_HOME/sessions")
      if [[ "$INCLUDE_ARCHIVED" == "true" ]]; then
        TRANSCRIPT_DIRS+=("$CODEX_TRANSCRIPT_HOME/archived_sessions")
      fi
      ;;
    *)
      echo "Transcript pruning skipped: current agent identity is unavailable."
      TRANSCRIPT_DIRS=()
      ;;
  esac

  EXISTING_TRANSCRIPT_DIRS=()
  for TRANSCRIPT_DIR in "${TRANSCRIPT_DIRS[@]}"; do
    if [[ -d "$TRANSCRIPT_DIR" ]]; then
      EXISTING_TRANSCRIPT_DIRS+=("$TRANSCRIPT_DIR")
    else
      echo "Transcript pruning skipped missing path: $TRANSCRIPT_DIR"
    fi
  done

  PRUNED=0
  if [[ "${#EXISTING_TRANSCRIPT_DIRS[@]}" -gt 0 ]]; then
    while IFS= read -r -d '' TRANSCRIPT_FILE; do
      if rm -f -- "$TRANSCRIPT_FILE"; then
        PRUNED=$((PRUNED + 1))
      fi
    done < <(find "${EXISTING_TRANSCRIPT_DIRS[@]}" -type f -name "*.jsonl" -mtime "+${RETENTION_DAYS}" -print0 2>/dev/null)
  fi
  if [[ "$PRUNED" -gt 0 ]]; then
    echo "Pruned ${PRUNED} JSONL transcript file(s) older than ${RETENTION_DAYS} days."
  fi
fi
# transcript-pruning:end
```

Missing transcript directories and absent, zero, or invalid retention settings skip
cleanly with an explicit note. Report the pruned count only when files were actually
deleted. The block only examines paths, file names, types, and modification times; it
must never inspect transcript contents.

---

## Permission scan (opt-in)

After transcript pruning, scan recent JSONL transcripts for frequently-used Bash patterns
and append new `permissions.allow` entries to `.claude/settings.json`.

**Sentinel check:** run only if `$RIG_DIR/memory/.fewer-prompts-enabled` exists.
If absent: skip silently.

```bash
if [[ -f "$RIG_DIR/memory/.fewer-prompts-enabled" ]]; then
  # Claude Code encodes the project path by replacing / with - in the directory name
  TRANSCRIPT_DIR="$HOME/.claude/projects/$(echo "$REPO" | sed 's|/|-|g')"
  SETTINGS_FILE="$REPO/.claude/settings.json"

  if [[ -d "$TRANSCRIPT_DIR" && -f "$SETTINGS_FILE" ]]; then
    python3 - "$TRANSCRIPT_DIR" "$SETTINGS_FILE" <<'PYEOF'
import json, sys, time
from collections import Counter
from pathlib import Path

transcript_dir, settings_file = sys.argv[1], sys.argv[2]

try:
    d = json.load(open(settings_file))
    existing = set(d.get("permissions", {}).get("allow", []))
except Exception:
    existing = set()

SKIP = {
    "rm", "mv", "cp", "chmod", "chown", "kill", "sudo",
    "curl", "wget", "bash", "sh", "zsh", "fish",
    "python3", "node", "ruby", "perl", "php",
    "pip", "npm", "yarn", "brew",
    "make", "docker", "kubectl",
}

cutoff = time.time() - 30 * 86400
commands = []
for jsonl_path in sorted(Path(transcript_dir).glob("*.jsonl")):
    try:
        if jsonl_path.stat().st_mtime < cutoff:
            continue
        with open(jsonl_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") != "assistant":
                    continue
                for item in obj.get("message", {}).get("content", []):
                    if (isinstance(item, dict) and
                            item.get("type") == "tool_use" and
                            item.get("name") == "Bash"):
                        cmd = item.get("input", {}).get("command", "").strip()
                        if cmd:
                            first = cmd.split()[0].split("/")[-1]
                            if first:
                                commands.append(first)
    except Exception:
        continue

counter = Counter(commands)
new_patterns = []
for cmd, count in counter.most_common():
    if count < 3:
        break
    if cmd in SKIP:
        continue
    pattern = f"Bash({cmd}*)"
    if pattern not in existing:
        new_patterns.append(pattern)

if not new_patterns:
    sys.exit(0)

try:
    with open(settings_file) as f:
        d = json.load(f)
    allows = d.setdefault("permissions", {}).setdefault("allow", [])
    added = [p for p in new_patterns if p not in allows]
    allows.extend(added)
    with open(settings_file, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    if added:
        print(f"Auto-approved {len(added)} new permission pattern(s): {', '.join(added)}")
except Exception as e:
    print(f"Permission scan: failed to update settings.json — {e}")
PYEOF
  fi
fi
```

To enable: `touch "$RIG_DIR/memory/.fewer-prompts-enabled"` (per-machine, gitignored).
The `/fewer-permission-prompts` skill remains available for one-off manual scans.

---

## Notes

- `.rig/memory/CONTEXT_SNAPSHOT.md` is gitignored — it lives on disk only, never committed
- `.rig/memory/PROGRESS_archive.md` and `.rig/memory/ERRORS_archive.md` are gitignored — full history on disk, not in the repo
- Always **overwrite** the snapshot, never append to it; it represents current state, not history
- History belongs in `.rig/memory/PROGRESS.md` (recent) and `PROGRESS_archive.md` (older); same pattern for `ERRORS.md` / `ERRORS_archive.md`
- If a task is in progress but not done, use the "Active tasks — in-flight state capture" step above to write a structured `## Resuming from` section into CONTEXT_SNAPSHOT. Vague notes are not sufficient — the next session must be able to resume from the snapshot alone.
