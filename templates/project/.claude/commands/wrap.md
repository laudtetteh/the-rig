# Command: /wrap

Trigger this command before ending a session or when approaching a context limit.

## What this does

Performs the session-end housekeeping that prevents state loss between sessions:

1. Writes (overwrites) `.rig/memory/CONTEXT_SNAPSHOT.md` with full current project state
2. Ensures `.rig/memory/PROGRESS.md` is up to date — expands any auto-stubbed entries
3. **Trims `.rig/memory/PROGRESS.md`** if it has grown beyond 20 entries (see Trim step below)
4. **Prunes stale session-end markers** from `PROGRESS.md` (see Marker prune step below)
5. Checks `.rig/memory/ERRORS.md` — prompts you to log anything unexpected from this session
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
4. Confirm: "`.rig/memory/PROGRESS.md` trimmed to 20 entries. Archive: `.rig/memory/PROGRESS_archive.md`"

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

## Self-improvement check

After logging new ERRORS.md entries, run a brief Rig retrospective:

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
4. Confirm: "`.rig/memory/ERRORS.md` trimmed to 30 entries. Archive: `.rig/memory/ERRORS_archive.md`"

Never trim without confirmation. Never delete entries — only move them.

---

## Session naming step

After reporting active tasks, derive a session name from this session's work and
output it as a suggestion. Do **not** apply it automatically — present it for
the user to confirm or tweak.

### How to determine "this session's work"

**Do not use today's date** — it breaks for sessions that span midnight or are
resumed days later. Use this priority order:

1. **`<!-- session-end -->` markers in PROGRESS.md** (most reliable)
   The `stop.sh` hook appends `<!-- session-end YYYY-MM-DD HH:MM -->` automatically
   when the agent finishes each response. Look for the most recent such marker:
   - Entries **above** the most recent marker belong to this session.
   - Entries **below** it belong to prior sessions.

2. **`Last updated:` field in the previous CONTEXT_SNAPSHOT** (fallback)
   If no session-end marker exists (e.g. stop.sh wasn't wired yet, or this is the
   first /wrap on a new install), read the `**Last updated:**` field from the snapshot
   you noted at session start (before step 1 overwrote it). Collect PROGRESS.md
   entries added since that date.

3. **Infer from PROGRESS.md ordering** (last resort)
   If neither signal exists, take the entries at the top of PROGRESS.md that are
   clearly from this session's conversation, and stop when you reach entries from
   a prior session.

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

For each meaningful unit of work (PR merged, task completed, significant fix shipped):
- **type** — git commit type: `fix`, `feat`, `chore`, `refactor`, `devops`, `docs`, `test`
- **short-desc** — 3–6 words that identify the work at a glance
- **#N** — PR or issue number; omit if none

Combine with ` | `. Keep under ~100 characters — truncate from the right by
dropping whole segments, never mid-word.

### Examples

```
fix step accordion layout #184 | fix h3.steps remaining partials #186
feat custom-permissions per-post levels #152 | fix picker regressions #150
devops cypress ci speedup #170 | devops ci cleanup #171
chore upgrade next to 14.2.1 | fix null user on profile fetch #88
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

After suggesting a session name and before asking "What's next?", delete the
`.wrap-needed` flag file if it exists:

```bash
rm -f "$(git rev-parse --show-toplevel)/.rig/memory/.wrap-needed" 2>/dev/null || true
```

(Resolve via `.rigpath` if present.) Log to session log: "`.wrap-needed` cleared."

This signals to `stop.sh` that `/wrap` has run and no flag should be written until
the next commit creates new unexpanded stubs.

---

## Notes

- `.rig/memory/CONTEXT_SNAPSHOT.md` is gitignored — it lives on disk only, never committed
- `.rig/memory/PROGRESS_archive.md` and `.rig/memory/ERRORS_archive.md` are gitignored — full history on disk, not in the repo
- Always **overwrite** the snapshot, never append to it; it represents current state, not history
- History belongs in `.rig/memory/PROGRESS.md` (recent) and `PROGRESS_archive.md` (older); same pattern for `ERRORS.md` / `ERRORS_archive.md`
- If a task is in progress but not done, note its exact state in the snapshot so the next session can resume without re-reading the whole conversation
