# Command: /wrap

Trigger this command before ending a session or when approaching a context limit.
Use `/wrap --checkpoint` to save a handoff while the exact session remains active.

## What this does

With no arguments, performs the session-end housekeeping that prevents state loss
between sessions:

1. Refreshes `.rig/memory/CONTEXT_SNAPSHOT.md` while preserving other sessions' task handoffs
2. Ensures `.rig/memory/PROGRESS.md` is up to date — expands any auto-stubbed entries
3. **Trims `.rig/memory/PROGRESS.md`** if it has grown beyond 20 entries (see Trim step below)
4. **Prunes stale session-end markers** from `PROGRESS.md` (see Marker prune step below)
5. Checks `.rig/memory/ERRORS.md` — prompts you to log anything unexpected; **checks archive before logging** to prevent duplicate entries (see ERRORS.md logging step below)
6. Checks for significant architectural, product, or process decisions made this session and logs new ones to `.rig/memory/DECISIONS.md` (see DECISIONS.md logging step below)
7. **Self-improvement check** — scans for Rig workflow gaps and logs them to `.rig/memory/RIG_GAPS.md`
8. **Trims `.rig/memory/ERRORS.md`** if it has grown beyond 30 entries (see Trim step below)
9. Reports installed active tasks, or that this install omitted task lifecycle
10. **Suggests a session name** — derives a name from this session's work via `/session-name` logic (see Session naming step below)
11. When tasks are installed, surfaces the next priority from `$RIG_DIR/tasks/backlog/` and asks: "What's next?"
12. **Cleans up housekeeping flags** — deletes `.rig/memory/.wrap-needed` if present
13. **Reports a safe skip** when the legacy `.fewer-prompts-enabled` sentinel is present; automatic transcript scanning and permission promotion are disabled until project ownership can be verified

`/wrap` is scoped to the current project only. Do not update another project's
Rig memory, task files, or session records during this workflow. If the
conversation includes work in more than one repository, name those other
projects in the report and leave their wrap/post-merge housekeeping to their own
project sessions.

If a PR was merged and the session is also ending, run `/post-merge` first for
the merged project, then run `/wrap` for this project. Do not combine their
memory writes under one inferred session identity.

If the user asks for multiple actions and an argument-free final wrap in the
same turn, finish all non-wrap implementation, verification, and reporting work
first. Then run the wrap housekeeping. The final assistant response for that
turn must be the Wrap report, even if internal wrap collection happened earlier.
Do not end with an implementation report after a requested final wrap. For an
explicit `--checkpoint`, finish the other work first and end with the
Checkpoint report and saved-handoff result.

## Usage

```
/wrap
/wrap --checkpoint
```

`--checkpoint` is the only accepted option. It must be explicit: an ordinary
request to wrap follows the final wrap path. In checkpoint mode, follow the
Checkpoint route below and stop at its exit; do not continue into final wrap.
The generated Codex `$wrap --checkpoint` skill follows the same route.

## Checkpoint route — preserve the exact active session

Run this route only for `/wrap --checkpoint`. It saves current Rig memory and a
resumable handoff without clearing obligations, finalizing a name, or completing
the session. A real provider SessionEnd can still end the record later; a later
native resume may then create a continuation anchor. Run an ordinary `/wrap`
later to perform all finalization gates.

1. Run `git branch --show-current`, `git status --short`, and
   `git log --oneline -3`. Report the branch, last commit, and every dirty path.
   Include dirty files in the handoff; do not prompt for a commit or make one
   merely to checkpoint. Resolve `REPO` and `RIG_DIR` with:

   ```bash
   REPO=$(git rev-parse --show-toplevel) || exit 1
   TASK_INVENTORY_JSON=$("$REPO/bin/rig" task inventory --json) || exit 1
   RIG_DIR=$(printf '%s' "$TASK_INVENTORY_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") and d.get("state") in ("installed", "omitted"); print(d["rig_dir"])') || exit 1
   ```

   Stop on ambiguous inventory or missing shared memory components. When task
   lifecycle is omitted, save shared memory only and report task handoffs as
   unavailable.
2. Before any write, run `"$REPO/bin/rig" session current --json`. Require
   `ok: true`, `confidence: exact`, `state: active`, a nonempty `anchor`, and a
   nonempty `session_file`. If it is unresolved, ended, ambiguous, or unsafe,
   report the reason and stop without writing. Do not use ordinary wrap's
   degraded mode or create a new record as part of a checkpoint. Extract the
   returned anchor as `CHECKPOINT_ANCHOR` and path as `CHECKPOINT_FILE`. Keep
   those exact values for the entire route; do not reuse an inherited launcher
   file hint if the resolver returned a continuation.
3. Gather the current project's progress, errors, decisions, Rig gaps and
   active-task handoffs from conversation context and Rig memory. Print a
   **Checkpoint report** before changing any file with this exact set of fields:
   project/branch/last commit, dirty paths, exact active anchor, session work
   summary, planned PROGRESS/ERRORS/DECISIONS/RIG_GAPS updates, trim and
   session-end marker counts, and owned active task handoffs (or omitted task
   lifecycle). Omit `Session` and `Final session name` fields from the ordinary
   Wrap report. Do not propose or confirm a final name.
4. Acquire the owner-recorded memory workflow lock using
   `"$REPO/bin/rig" memory workflow-lock acquire --owner-anchor "$CHECKPOINT_ANCHOR" --json`,
   where `CHECKPOINT_ANCHOR` is the exact anchor from step 2. Extract and save
   the returned `token` across tool calls. Observe the same busy/stale-lock
   rules as the Concurrent session guard below. Immediately re-run
   `session current --json` with
   `RIG_SESSION_FILE="$CHECKPOINT_FILE" RIG_SESSION_ANCHOR="$CHECKPOINT_ANCHOR"`
   in that tool-call shell; if the anchor, file, exact confidence, or active
   state changed, release that token and stop before other writes.
5. Under that lock, perform the shared memory work in this command: expand
   this session's auto-stubbed PROGRESS entries, add any missing session-tagged
   progress, trim PROGRESS if needed, prune stale session-end markers, log real
   ERRORS and adopted DECISIONS, record Rig gaps, and trim ERRORS if needed.
   Use the existing sections below for each operation. Keep every entry's
   provenance and preserve other sessions' content.
6. Build the Active tasks snapshot draft below with a current shared project
   header, the exact session's task handoffs and dirty-path list. Use
   `memory write-snapshot` with `--shared-only` for the shared header, then
   `--owned-task` for each owned section with `RIG_SESSION_FILE` and
   `RIG_SESSION_ANCHOR` set to the exact values from step 2. If no task handoff
   is owned, use only `--shared-only`. The writer preserves other
   owners' sections. On a writer error, release the lock and keep the draft for
   retry. In the shell executing the snapshot block, set
   `WRAP_SNAPSHOT_MODE=checkpoint`, `RIG_SESSION_FILE="$CHECKPOINT_FILE"`,
   `RIG_SESSION_ANCHOR="$CHECKPOINT_ANCHOR"`, `CHECKPOINT_FILE`, and
   `CHECKPOINT_ANCHOR` for the entire block, including
   its `session current --json` recheck. Re-run that check before the write; if
   it no longer identifies the same exact active anchor and file, release the
   lock and stop. Reassign these saved values in each new tool-call shell;
   shell variables and exports do not persist between tool calls.
7. Release the exact workflow-lock token with
   `"$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json`.
   Report the saved snapshot and the
   still-active anchor. **Stop here.** Do not run PR freshness, final naming,
   obligation clear, session completion, orphan scan, flag or compact-checkpoint
   cleanup, transcript pruning, permission scan, or the ordinary "What's next?"
   prompt. Leave wrap and post-merge reminders, record bytes, names, and
   continuation lineage untouched. A later ordinary `/wrap` still performs
   every finalization gate.

If any checkpoint step fails after lock acquisition, release only the exact
token this invocation received. Never infer a replacement owner from another
session's lock or snapshot. Repeated checkpoints update this owner's handoff
through the same writer and preserve unrelated handoffs.

> **RIG_DIR resolution:** After the Git state check, before reading or writing
> any `.rig/` path, use the inventory helper's resolved `rig_dir`. It handles
> in-repo, external, and relative `.rigpath` values without changing spaces.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> TASK_INVENTORY_JSON=$("$REPO/bin/rig" task inventory --json) || {
>   printf '%s\n' "$TASK_INVENTORY_JSON" >&2
>   exit 1
> }
> RIG_DIR=$(printf '%s' "$TASK_INVENTORY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rig_dir"])')
> DOCS_DIR="$REPO/docs"
> ```
>
> Substitute `$RIG_DIR` for `.rig/` in every step below.

After the Git state check, use the inventory result from the block above.
If it reports `state: omitted`, continue shared memory housekeeping and report
task handoffs and backlog priority as unavailable. If it reports `state:
ambiguous` or `ok: false`, stop and report its `reason` as a task inventory
error. A missing installed directory must never be described as an empty task
list. If shared memory files such as `$RIG_DIR/memory/PROGRESS.md` are missing,
report "shared memory component unavailable" and stop before memory writes;
task omission alone does not make a missing memory component usable.

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
7. **Active tasks** — when the inventory is installed, read `$RIG_DIR/tasks/active/`; when omitted, record "task lifecycle omitted"
8. **Session identity** — run `bin/rig session resolve --json` read-only; extract
   its session file, `anchor`, and `tentative_name`. Stop on ambiguous identity.
9. **Skipped post-merge status** — if `/post-merge` was requested in the same turn but
   no merge is applicable, record the skip reason and next action.

### Report

Print a single structured report before executing anything:

```
## Wrap report — [branch] — [date]

**Scope:** wrapping [project name] only
**Cross-project work:** [none | other projects mentioned: project-a, project-b — not updated here]

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

**Session:** [anchor: UUID | tentative: "..." | suggested final: "type desc REF | type desc REF" | exact recovery pending | unresolved — no final session-file write performed | nothing meaningful shipped, skipped]
**Final session name:** [confirmed final: "..." | suggested final: "..." awaiting confirmation | unresolved — reliable name could not be set | nothing meaningful shipped, skipped]
```

If `bin/rig session resolve --json` returns `ended_record` or `not_found` and
reports a native environment recovery command, record exact recovery as pending
in the report. After acquiring the workflow lock, run the appropriate exact retrofit:
`bin/rig session retrofit --agent codex --from-env --source resume --json` for
Codex, or `bin/rig session retrofit --agent claude --from-env --source resume --json`
for Claude. Use the returned active continuation record if retrofit succeeds.
The UserPromptSubmit hook may already have attached a resumed thread from its
event ID, even when the native ID is absent from the shell environment.

If resolve returns `not_found` without a recovery path, or retrofit cannot create an exact
active continuation, enter degraded mode: print
`Session: unresolved — no final session-file write performed`, continue project
memory maintenance that does not require an exact session record, write
`CONTEXT_SNAPSHOT.md`, and skip final session-file mutation. Do not fabricate a
session UUID or move any record to `sessions/done/`. If it returns `ambiguous`,
`duplicate_native_id`, `cross_project`, malformed data, or an unsafe path, stop
before writing because the session state is unsafe.

An `ended_record` cannot write an owned-task handoff. If the task remains active,
use the exact active continuation returned by retrofit (or start a new exact
session) before calling `memory write-snapshot --owned-task TASK`. The writer
backs up and transfers a handoff owned by the completed session. If an exact
active continuation is unavailable, write only the shared section with
`--shared-only`, preserve the existing handoff, and report that its update is
pending. Never pass the completed session file as an owner or edit snapshot
markers by hand.

### Execution

After printing the report, **execute all automatic actions without further prompts**:

- Trim PROGRESS.md if count > 20
- Prune stale session-end markers
- Add inferred ERRORS.md entries (if any)
- Add inferred DECISIONS.md entries (if any)
- Trim ERRORS.md if count > 30
- Write CONTEXT_SNAPSHOT.md (project state only — no Session name field)
- Write final session name to session file and move to `sessions/done/` — only if user confirms the suggested name

The session name and optional PR description update are the only actions requiring
explicit user input. Ask about the PR description after releasing the workflow
lock; execute memory housekeeping immediately after the report.

---

## Concurrent session guard — acquire before memory writes

After printing the Wrap report, acquire the owner-recorded memory workflow lock
before changing memory. The git-state gate and any dirty-file question must be
resolved before this point. It serializes wrap and post-merge housekeeping; the
snapshot writer separately locks its short atomic update. Preserve the returned
token through the snapshot update:

```bash
LOCK_OWNER=$("$REPO/bin/rig" session current --json 2>/dev/null | \
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")' 2>/dev/null || true)
LOCK_ARGS=(acquire --json)
[[ -n "$LOCK_OWNER" ]] && LOCK_ARGS+=(--owner-anchor "$LOCK_OWNER")
[[ "${RIG_SESSION_PID:-}" =~ ^[0-9]+$ ]] && LOCK_ARGS+=(--provider-pid "$RIG_SESSION_PID")
SNAP_LOCK_JSON=$("$REPO/bin/rig" memory workflow-lock "${LOCK_ARGS[@]}") || {
  echo "Unable to write Rig memory lock: $SNAP_LOCK_JSON" >&2
  echo "No further memory writes were attempted." >&2
  exit 1
}
SNAP_LOCK_TOKEN=$(printf '%s' "$SNAP_LOCK_JSON" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') || exit 1
WRAP_MARKER_TOKEN=$(python3 -c 'import hashlib,pathlib,sys; p=pathlib.Path(sys.argv[1]); s=p.stat() if p.exists() else None; print(hashlib.sha256(p.read_bytes()).hexdigest()+":"+str(s.st_mtime_ns)+":"+str(s.st_ino) if s else "missing")' \
  "$RIG_DIR/memory/.wrap-needed") || {
  "$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json
  exit 1
}
printf 'Rig workflow lock acquired: %s\n' "$SNAP_LOCK_JSON"
printf 'Wrap reminder baseline: %s\n' "$WRAP_MARKER_TOKEN"
```

The lock reports the current owner anchor, PID, and age if another workflow is
active. A dead provider PID is archived and recovered on the next acquire.
For a tool-sourced lock older than 30 minutes, verify that its workflow has
stopped, then retry acquire with `--recover-stale`. Age alone does not take over
the lock; the stale record is archived on explicit recovery.
Never remove another session's lock by hand as
part of this command. Keep the exact `token` from the acquire output in your
working context and reassign `SNAP_LOCK_TOKEN` from that value in later tool-call
shells; shell variables do not persist between tool calls. Never recover a token
by reading the current lock file, which could belong to a newer session. If
`WRAP_MARKER_TOKEN` is lost across tool calls, pass an empty token at the final
clear; that clears only this session's scoped obligation and preserves all
unscoped reminders. Never re-read the marker to reconstruct the baseline. If
acquire fails with `Operation not permitted`, request scoped write approval for $RIG_DIR
before retrying. This commonly happens when Codex is running in a
project whose `.rigpath` points outside the workspace writable roots.

The sentinel file is gitignored alongside other `.rig/memory/` runtime files.
If any step fails after acquire, release the exact token before stopping. Keep
the snapshot draft and pending obligations for a retry.
If exact session retrofit was pending during report collection, perform it now,
before other memory writes. Update the resolved session identity or continue in
degraded mode if exact recovery is unavailable.

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

1. Resolve `$RIG_DIR` (see RIG_DIR resolution block above), then set
   `DOCS_DIR="$REPO/docs"` using the already resolved project root.
2. If `$DOCS_DIR` doesn't exist or has no `.md` files (other than `README.md`): skip silently.
3. For this advisory feature-doc check only, bound the legacy commit sweep by the most recent session-end marker or prior snapshot date when needed. These bounds are not session naming evidence; name the session from the current conversation and exact session UUID evidence.
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

After ERRORS.md cleanup and before session naming, use the task inventory
result from the resolution block. If tasks were intentionally omitted, write a
shared-only snapshot draft, report that task handoffs are unavailable, and
continue session naming. Do not create a task section or infer an empty list.
For installed tasks, read `$RIG_DIR/tasks/active/`.

**If empty:** note "No tasks in flight" and continue.

**If non-empty:** identify the active tasks this exact session worked on. For
each of those tasks, write a `## Resuming from` section in a snapshot draft that
captures enough state for the next session to resume without re-reading the
conversation. Leave tasks owned by another active session out of this draft;
the writer preserves their existing sections. Each owned section must include:

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

Build a draft under `$RIG_DIR/memory/` containing the current shared project
header and only this session's `## Resuming from` sections. Use the token from
the concurrent session guard to name the draft
`.snapshot-draft-${SNAP_LOCK_TOKEN}.md`. For an ordinary final wrap, set
`WRAP_SNAPSHOT_MODE=final` in the shell that runs the writer block, even if an
earlier checkpoint exported another value. The explicit checkpoint route sets
`WRAP_SNAPSHOT_MODE=checkpoint` and its saved exact anchor/file instead. For a
session with no exact active record, write the shared header only and report
that task handoffs could not be
updated without an owner. Then run the owner-aware writer:

```bash
SNAP_DRAFT="$RIG_DIR/memory/.snapshot-draft-${SNAP_LOCK_TOKEN}.md"
SNAP_SHARED_DRAFT="$RIG_DIR/memory/.snapshot-shared-draft-${SNAP_LOCK_TOKEN}.md"
snapshot_write_failed() {
  "$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json
  echo "Snapshot update failed; draft preserved at $SNAP_DRAFT" >&2
  exit 1
}
checkpoint_verify_snapshot_identity() {
  case "${WRAP_SNAPSHOT_MODE:-}" in
    final) return 0 ;;
    checkpoint) ;;
    *) return 1 ;;
  esac
  [[ -n "${CHECKPOINT_ANCHOR:-}" && -n "${CHECKPOINT_FILE:-}" ]] || return 1
  local current
  current=$(RIG_SESSION_FILE="$CHECKPOINT_FILE" RIG_SESSION_ANCHOR="$CHECKPOINT_ANCHOR" \
    "$REPO/bin/rig" session current --json) || return 1
  printf '%s' "$current" | python3 -c 'import json,sys; d=json.load(sys.stdin); ok=d.get("ok") is True and d.get("confidence")=="exact" and d.get("state")=="active" and d.get("anchor")==sys.argv[1] and d.get("session_file")==sys.argv[2]; sys.exit(0 if ok else 1)' \
    "$CHECKPOINT_ANCHOR" "$CHECKPOINT_FILE"
}
checkpoint_verify_snapshot_identity || snapshot_write_failed
OWNED_TASKS=()
while IFS= read -r task; do OWNED_TASKS+=("$task"); done \
  < <(sed -n 's/^## Resuming from: //p' "$SNAP_DRAFT")
SNAP_ARGS=(--file "$SNAP_DRAFT" --json)
if [[ "${#OWNED_TASKS[@]}" -eq 0 ]]; then
  SNAP_ARGS+=(--shared-only)
  checkpoint_verify_snapshot_identity || snapshot_write_failed
  "$REPO/bin/rig" memory write-snapshot "${SNAP_ARGS[@]}" || snapshot_write_failed
else
  awk '/^## Resuming from: / { exit } { print }' "$SNAP_DRAFT" > "$SNAP_SHARED_DRAFT" || snapshot_write_failed
  if grep -q '[^[:space:]]' "$SNAP_SHARED_DRAFT"; then
    checkpoint_verify_snapshot_identity || snapshot_write_failed
    "$REPO/bin/rig" memory write-snapshot --file "$SNAP_SHARED_DRAFT" --shared-only --json || snapshot_write_failed
  fi
  if [[ "$WRAP_SNAPSHOT_MODE" == checkpoint ]]; then
    CURRENT_JSON=$(RIG_SESSION_FILE="$CHECKPOINT_FILE" RIG_SESSION_ANCHOR="$CHECKPOINT_ANCHOR" \
      "$REPO/bin/rig" session current --json) || snapshot_write_failed
  else
    CURRENT_JSON=$("$REPO/bin/rig" session current --json) || snapshot_write_failed
  fi
  CURRENT_FILE=$(printf '%s' "$CURRENT_JSON" | \
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_file") or "")') || snapshot_write_failed
  CURRENT_ANCHOR=$(printf '%s' "$CURRENT_JSON" | \
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")') || snapshot_write_failed
  [[ -n "$CURRENT_FILE" && -n "$CURRENT_ANCHOR" ]] || snapshot_write_failed
  checkpoint_verify_snapshot_identity || snapshot_write_failed
  for task in "${OWNED_TASKS[@]}"; do SNAP_ARGS+=(--owned-task "$task"); done
  RIG_SESSION_FILE="$CURRENT_FILE" RIG_SESSION_ANCHOR="$CURRENT_ANCHOR" \
    "$REPO/bin/rig" memory write-snapshot "${SNAP_ARGS[@]}" || snapshot_write_failed
fi
rm -f "$SNAP_DRAFT" "$SNAP_SHARED_DRAFT"
```

For a pre-existing unowned section with the same task slug, inspect it first.
Only after confirming that this session is taking ownership, rerun with
`--adopt-legacy`. The writer backs up the original snapshot before migration.
Never edit `CONTEXT_SNAPSHOT.md` directly; the writer preserves foreign sections
and atomically materializes the shared view.

Release the workflow lock after the snapshot is written and any legacy section
adoption is complete. Do this before presenting a session name for confirmation;
another session can then start its own memory housekeeping while the user decides.

```bash
"$REPO/bin/rig" memory workflow-lock release --token "$SNAP_LOCK_TOKEN" --json || exit 1
```

---

## PR description freshness step

When this branch has an open PR, check whether the body still matches the final
diff and verification evidence. This check is read-only unless the user approves
a body update.

1. Find the open PR for the current branch. If none exists, skip this step.
2. Fetch the PR's full metadata and final changed-file list:
```
REPO=$(git rev-parse --show-toplevel)
CURRENT_BRANCH=$(git branch --show-current)
PR_JSON=$(gh pr list --head "$CURRENT_BRANCH" --json number --limit 1)
PR_NUMBER=$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["number"] if d else "")')
if [[ -n "$PR_NUMBER" ]]; then
  REVIEW_DIR=$(mktemp -d)
  gh pr view "$PR_NUMBER" --json number,state,isDraft,headRefOid,title,body,labels,commits > "$REVIEW_DIR/pr.json"
  gh pr diff "$PR_NUMBER" --name-only > "$REVIEW_DIR/files.txt" || exit 1
  TRACKER_JSON=$(python3 "$REPO/bin/rig-tracker-config.py" show "$REPO/CLAUDE.md") || exit 1
  TRACKING=$(printf '%s' "$TRACKER_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tracker"])') || exit 1
  "$REPO/bin/rig" pr review-metadata --pr "$REVIEW_DIR/pr.json" --files "$REVIEW_DIR/files.txt" --issue-tracking "$TRACKING" --payload-out "$REVIEW_DIR/payload.json"
fi
```
3. Review the Summary and Changes sections against the changed-file list. The
   metadata command reports explicit file paths that do not appear in the final
   diff. Also compare test and verification statements, including counts, with
   focused results and CI at the current PR head; the command cannot validate
   semantic claims or test counts.
4. If the body is stale, show the exact proposed correction and ask before
   updating it. A finding is evidence to review, not permission to edit. After
   approval, write the body through GitHub's REST API:
```
python3 - "$REVIEW_DIR/body.md" "$REVIEW_DIR/payload.json" <<'BODYJSON'
import json,sys
json.dump({"body":open(sys.argv[1],encoding="utf-8").read()},open(sys.argv[2],"w"))
BODYJSON
gh api repos/{owner}/{repo}/pulls/"$PR_NUMBER" --method PATCH --input "$REVIEW_DIR/payload.json"
gh pr view "$PR_NUMBER" --json body
```
5. If the final diff, test/verification claims, and current-head CI all support
   the body, report it as current and continue wrap.
6. If no PR exists or GitHub is unavailable, report the concrete skip reason.
   Do not infer freshness from the commit-subject substring check alone.

## Session naming step

After reporting active tasks, derive a final session name from this session's work
and output it as a suggestion. Do **not** apply it automatically — present it for
the user to confirm or tweak.

### Step 1 — Find this session's UUID and tentative name

Read `$RIG_DIR/rules/session-naming.md` completely first. Its session-local
evidence rules are authoritative for this suggestion.

```bash
REPO=$(git rev-parse --show-toplevel 2>/dev/null)
TASK_INVENTORY_JSON=$("$REPO/bin/rig" task inventory --json) || exit 1
RIG_DIR=$(printf '%s' "$TASK_INVENTORY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rig_dir"])')
SESSION_JSON=$("$REPO/bin/rig" session resolve --json) || {
  echo "Unable to resolve this session unambiguously; stop before writing snapshot state."
  exit 1
}
SESSION_FILE=$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])')
SESSION_UUID=$(printf '%s' "$SESSION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")')
TENTATIVE_NAME=$(SESSION_F="$SESSION_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); print(d.get("names",{}).get("tentative") or d.get("tentative_name") or "")')
NAMING_EVIDENCE=$(SESSION_F="$SESSION_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); e=d.get("naming_evidence",{}).get("progress_titles",[]) if isinstance(d.get("naming_evidence",{}),dict) else []; print("\n".join(str(x) for x in e if str(x).strip()))' 2>/dev/null || true)
```

### Step 2 — Collect this session's work

**Primary signal: your conversation context.** Enumerate directly what was done
this session — PRs merged or opened, tasks completed, issues resolved. This is
always the most accurate signal. The tentative name (if set) and
`naming_evidence.progress_titles` in the exact active session file are
pre-compaction anchors from earlier in this session — use them as starting points
if context was lost.

**Every `## ` entry header you write to PROGRESS.md must include `<!-- sid:UUID -->`
at the end of the line** (read UUID from the resolver output above). This is
what enables UUID-keyed session attribution.

**File signal — UUID-keyed PROGRESS entries:**
```bash
grep "^## .*<!-- sid:${SESSION_UUID} -->" "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null || true
```

**File signal — compact checkpoint Session naming evidence:** read only
`$RIG_DIR/memory/.compact-checkpoint-${SESSION_UUID}.md`, and use its
`Session naming evidence` only when the same file's `Session anchor` equals
`SESSION_UUID`.

**If conversation context and file signals conflict, trust the conversation.**
Never use `CONTEXT_SNAPSHOT.md`, checkpoints for another anchor, legacy markers,
unrelated session files, other-session UUID entries, or general project history
as naming evidence. An unresolved raw launch fails closed before any name is proposed or written.

### Step 3 — Build the name

If a `tentative_name` exists: use it as the base. If the session delivered exactly
what it described, confirm it (drop `[tentative]`). If scope changed, update it.
If no tentative name: derive from scratch.

Count one "unit" per merged PR, completed task, or significant fix.

Ticket references follow the project's tracker. Read it before writing a name:

```bash
REPO=$(git rev-parse --show-toplevel)
python3 "$REPO/bin/rig-tracker-config.py" show "$REPO/CLAUDE.md"
```

`REF` is one ticket reference in that tracker's format, without brackets, and
`RANGE` is the lowest-to-highest span of references, or a short list for
trackers whose IDs are not ordered:

| `issue-tracking:` | `REF` example | `RANGE` example |
|---|---|---|
| `github` (or absent) | `#184` | `#130–#152` |
| `linear` | `ENG-184` | `ENG-130–ENG-152` |
| `trello` | `trello:a1B2c3` | up to three card references, then `+N more` |
| `gus` | `W-1234567` | `W-1234501–W-1234567` |
| Any other tracker | Configured `issue-ref-example:`, or the user's actual reference | Up to three references, then `+N more` |
| `none` | omit it | omit it |

A merged pull request may still be named as `PR 12` under any tracker.

Use the tiered format:

- **≤5 units:** `type short-desc REF | type short-desc REF | ...`
- **6–15 units:** `type(area, area) | type(area) x3 | type x2`
- **16+ units:** `sprint: N issues · feat/X fix/Y chore/Z · RANGE`

Keep under ~100 characters.

### Step 4 — Present and confirm

> **Suggested session name:**
> `fix mobile Expo Go runtime fixes #359 | chore merge PR 360` (github)
> `fix mobile Expo Go runtime fixes ENG-359 | chore merge PR 360` (linear)

> To apply: say "use that name", "ship it", or "lgtm".

### Step 5 — After confirmation: write to session file, move to done/

Use the shared atomic writer. Pass the confirmed name as one opaque argument;
never interpolate it into shell or Python source.

```bash
# Clear only this exact session's wrap obligation while its active record is
# still resolvable. Adopt an older unscoped marker only if it has not changed
# since the workflow lock was acquired and no unexpanded untagged stub remains;
# another session may add one while this session waits for name confirmation.
CURRENT_JSON=$("$REPO/bin/rig" session current --json) || {
  exit 1
}
CURRENT_UUID=$(printf '%s' "$CURRENT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("anchor") or "")')
[[ -n "$SESSION_UUID" && "$CURRENT_UUID" == "$SESSION_UUID" ]] || {
  echo "Session identity changed; stop before clearing or completing it." >&2
  exit 1
}
WRAP_CLEAR_JSON=$("$REPO/bin/rig" session obligation clear --kind wrap \
  --adopt-legacy-if-marker-token "${WRAP_MARKER_TOKEN:-}" --json) || exit 1
printf '%s\n' "$WRAP_CLEAR_JSON"
"$REPO/bin/rig" session-name set --final --complete "$CONFIRMED_NAME"
```

If `WRAP_CLEAR_JSON` reports `"legacy_preserved": true`, state that another
project reminder remains pending. Do not report that `.wrap-needed` was cleared.
If clear returns `owned_progress_unexpanded`, keep the session active and its
name unfinalized. Expand the new SID-tagged stub, refresh the snapshot under a
new workflow lock, and retry with that lock's reminder baseline.

If this is a continuation after an earlier wrap, name only work done since
that wrap. Preserve the completed parent record and its final name.

**Do NOT write Session name to CONTEXT_SNAPSHOT.md.** CONTEXT_SNAPSHOT contains
project state only (branch, PRs, roadmap, key facts). Session names live in session files.

### Step 6 — Surface orphan sessions

After completing this session, set `SESSION_DIR="$RIG_DIR/memory/sessions"` and
`DONE_DIR="$SESSION_DIR/done"`, then scan `$SESSION_DIR` for remaining `.json` files
(not in `done/`) with `"status": "active"`:

```bash
# orphan-session-scan:start
SESSION_DIR="$RIG_DIR/memory/sessions"
DONE_DIR="$SESSION_DIR/done"
for f in "$SESSION_DIR"/session-*.json; do
  [[ -f "$f" ]] || continue
  STATUS=$(python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('lifecycle', {}).get('state') or d.get('status', ''))
PY
  ) || continue
  STARTED=$(python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('created_at') or d.get('started_at') or '?')
PY
  ) || continue
  NAME=$(python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('names', {}).get('tentative') or d.get('tentative_name') or d.get('anchor', '?'))
PY
  ) || continue
  if [[ "$STATUS" == "active" ]]; then
    echo "⚠ Orphan session (active, unwrapped): $NAME (started $STARTED, file: $(basename "$f"))"
  elif [[ "$STATUS" == "complete" ]]; then
    # complete but not moved to done/ — write step finished but rename was interrupted
    echo "⚠ Orphan session (complete, not moved to done/): $NAME (file: $(basename "$f"))"
    echo "   Move manually: mv '$f' '$DONE_DIR/'"
  fi
done
# orphan-session-scan:end
```

Surface any found to the user. They may be active in another tab — do not delete
them without asking.

If nothing meaningful shipped this session (pure exploration, no PRs, no completions),
skip the naming step silently but still run the orphan scan.

---

## Flag cleanup (step 12)

After suggesting a session name and before asking "What's next?", run checkpoint cleanup:

```bash
# The exact wrap obligation was cleared in Step 5 before the record moved to done/.

# Clear this session's compact checkpoint — the full snapshot supersedes it
rm -f "$RIG_DIR/memory/.compact-checkpoint-${PPID}.md" 2>/dev/null || true

# Clear /tmp UUID sentinel (session file already moved to done/ by naming step)
# The atomic session-name writer removes the matching legacy sentinel on completion.
```

Log the exact scoped wrap obligation as cleared. Report `.wrap-needed` as
cleared only when the marker is gone; otherwise report the remaining project
or other-session reminder. Log the compact checkpoint and UUID sentinel cleanup.

`.wrap-needed` may contain multiple `anchor=` entries. The exact-session clear
removes only the current anchor and deletes the reminder only when no scoped or
unadopted legacy obligation remains.
The workflow lock release after the snapshot update signals to concurrent
sessions that wrap memory housekeeping is complete. The snapshot writer clears
its own short-lived write marker.
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
only when a provider offers a provably project-owned transcript location. Claude's
slash-to-hyphen project directory mapping can collide for distinct repository paths;
Codex stores sessions under a shared directory without a documented project-specific
path. Skip both providers until a safe ownership check is available. Never read
provider-private rollout contents to infer ownership. A retention setting in one
project must never delete another project's transcripts.

```bash
# transcript-pruning:start
TRANSCRIPT_AGENT="CURRENT_AGENT"
RETENTION_DAYS=$(grep "^transcript-retention-days:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')

if [[ ! "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Transcript pruning skipped: transcript persistence retention is disabled."
elif [[ "$TRANSCRIPT_AGENT" == "claude" ]]; then
  echo "Transcript pruning skipped: Claude project directory mapping can collide between repositories."
elif [[ "$TRANSCRIPT_AGENT" == "codex" ]]; then
  echo "Transcript pruning skipped: Codex has no documented project-scoped transcript directory."
else
  echo "Transcript pruning skipped: current agent identity is unavailable."
fi
# transcript-pruning:end
```

Absent, zero, or invalid retention settings skip cleanly with an explicit note.
No transcript contents or provider-private rollout data are inspected.

---

## Next-session handoff prompts — display-only

If the user asks for a handoff or next-session prompt during or after the wrap,
print it in your response; do not write it to a file. Keep it short: point the
next agent at `$RIG_DIR/memory/CONTEXT_SNAPSHOT.md` and the active task files in
`$RIG_DIR/tasks/active/` instead of restating their contents, because the
snapshot is the maintained source of truth and a copy drifts from it.

Save the prompt only when the user explicitly asks for a file. Then overwrite
the single fixed file `$RIG_DIR/memory/NEXT_SESSION_PROMPT.md`. Never create a
new dated handoff file, even if another instruction says to save deliverables
as files.

---

## Permission scan (opt-in)

The legacy `.fewer-prompts-enabled` sentinel remains recognized, but automatic
permission promotion is disabled until a trustworthy project-to-transcript
binding exists. Claude's slash-to-hyphen directory mapping can collide across
repositories. Reading that shared directory could copy another project's Bash
commands into this project's `permissions.allow`. Do not read provider JSONL
or edit `.claude/settings.json` based on that mapping.

If the sentinel is present, report the safe skip so users know why no patterns
were promoted:

```bash
# permission-scan:start
if [[ -f "$RIG_DIR/memory/.fewer-prompts-enabled" ]]; then
  echo "Permission scan skipped: Claude transcript directory mapping can collide between repositories; no project-owned transcript binding is available."
fi
# permission-scan:end
```

A future explicit ownership design must verify the repository before any
transcript read or permission update. The bundled one-off
`/fewer-permission-prompts` skill should be used only after its transcript scope
is checked independently.

---

## Notes

- `.rig/memory/CONTEXT_SNAPSHOT.md` is gitignored — it lives on disk only, never committed
- `.rig/memory/PROGRESS_archive.md` and `.rig/memory/ERRORS_archive.md` are gitignored — full history on disk, not in the repo
- Always use `bin/rig memory write-snapshot` to refresh the shared header and this
  session's task sections. Never overwrite or append to `CONTEXT_SNAPSHOT.md` by hand;
  the writer preserves sections owned by other active sessions.
- History belongs in `.rig/memory/PROGRESS.md` (recent) and `PROGRESS_archive.md` (older); same pattern for `ERRORS.md` / `ERRORS_archive.md`
- If a task is in progress but not done, use the "Active tasks — in-flight state capture" step above to write a structured `## Resuming from` section into CONTEXT_SNAPSHOT. Vague notes are not sufficient — the next session must be able to resume from the snapshot alone.
- At the very end of the response, after every other report or chained command,
  repeat the session block: anchor, final or suggested name, and whether the
  record was completed or remains unresolved.
