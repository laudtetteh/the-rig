# Command: /rig-gaps

> **For Rig contributors and developers.** This command is for users who contribute to or develop The Rig. If you're working on your own project and have no interest in improving The Rig itself, you can ignore this command and `RIG_GAPS.md`.

Compile and display all logged gaps, friction points, and improvement ideas about
The Rig itself — for review and optional submission.

## What this does

1. Reads `.rig/memory/RIG_GAPS.md` and lists all gap entries
2. Scans `.rig/memory/ERRORS.md` for any Rig-related issues not yet captured in `RIG_GAPS.md`
3. Formats a consolidated report with copy-paste instructions
4. Offers to mark entries as submitted (adds `[submitted]` tag to entry headers)

## Usage

```
/rig-gaps
```

> **RIG_DIR resolution (stealth mode):** Before reading any `.rig/` path, resolve
> where `.rig/` actually lives. If `.rigpath` exists at the project root, read it —
> it contains the absolute path to the external `.rig/` directory. Substitute `$RIG_DIR`
> for `.rig/` throughout.

Run this:
- When you want to report accumulated feedback to The Rig developer
- Before a major project milestone (so gaps get fixed before the next phase)
- Periodically — once every few weeks of active use

---

## Step 1 — Read RIG_GAPS.md

Read `.rig/memory/RIG_GAPS.md`. Collect all entries that do **not** have `[submitted]` in their header.

If there are no unsubmitted entries, say:
> "No unsubmitted gaps in `.rig/memory/RIG_GAPS.md`.
> Run tasks for a while and then come back — gaps are logged automatically during `/wrap`."

---

## Step 2 — Cross-check ERRORS.md

Read `.rig/memory/ERRORS.md`. Look for entries that describe friction with The Rig's own
workflow rather than project-specific bugs. Examples of Rig-related errors:
- "pre-tool.sh blocked an operation that should have been allowed"
- "A process step was missing or wrong"
- "A slash command produced unexpected output"
- "Hook fired when it shouldn't have / didn't fire when it should"

For each Rig-related ERRORS.md entry NOT already reflected in `RIG_GAPS.md`:
- Synthesize it into a gap entry using the standard format
- Append it to `RIG_GAPS.md` automatically (no confirmation needed — this is non-destructive)
- Note how many new entries were synthesized

---

## Step 3 — Display report

Print the following:

```
## Rig Gaps Report — [project name] — [today's date]

[N] unsubmitted entries:

---
[paste each unsubmitted entry verbatim from RIG_GAPS.md]
---

## How to review

Review logged gaps and decide which to act on. If you're contributing to The Rig,
bring these to a Rig dev session or use `/rig-gaps --submit` to open GitHub issues directly.
```

---

## Step 4 — Offer to mark as submitted

After displaying the report, ask:

> "Mark these [N] entries as submitted in `RIG_GAPS.md`? (Useful if you're about to paste
> them into a Rig dev session.)"

If the user confirms:
- Append ` [submitted YYYY-MM-DD]` to each entry's `## [date]` header line
- Confirm: "[N] entries marked as submitted."

If the user declines or there's nothing to mark, skip silently.

---

## Push mode (developer shortcut)

If the user says **"push"**, **"--push"**, or **"submit to rig"**, run this flow instead
of (or after) displaying the report. This is a same-machine shortcut — it works only
when The Rig's own repo is accessible on disk.

### Step P1 — Resolve the destination

Read `rig-gaps-push-target:` from `CLAUDE.md`:

```bash
PUSH_TARGET=$(grep "^rig-gaps-push-target:" "$REPO/CLAUDE.md" | awk '{print $2}' | head -1)
```

If the field is absent or empty, fail gracefully:
> "No `rig-gaps-push-target:` set in `CLAUDE.md`. Add a line like:
> `rig-gaps-push-target: /Users/you/.rig/projects/the-rig/memory/RIG_GAPS.md`
> Then retry."
Stop.

Verify the target file exists:
```bash
[[ -f "$PUSH_TARGET" ]] || { echo "Target not found: $PUSH_TARGET"; exit 1; }
```

If it doesn't exist, fail gracefully:
> "Target file not found: `$PUSH_TARGET`. Check the path in `rig-gaps-push-target:` and retry."
Stop.

### Step P2 — Preview and confirm

Display the entries that will be pushed (same format as Step 3 report).
Ask:
> "Push [N] entries to `$PUSH_TARGET`? These will be appended to the Rig dev session's
> RIG_GAPS.md for triage. Review entries above — strip any project-specific details
> before submitting. Confirm? (yes / no)"

Wait for explicit confirmation. Do not push without it.

### Step P3 — Append entries

Append each unsubmitted entry verbatim to `$PUSH_TARGET`:

```bash
echo "" >> "$PUSH_TARGET"
echo "## [ENTRY CONTENT]" >> "$PUSH_TARGET"
```

One blank line before each entry. Do not duplicate entries that already exist in
the destination (check for matching `## [date] —` header lines before appending).

### Step P4 — Mark as submitted

Append ` [submitted YYYY-MM-DD]` to each pushed entry's `## [date]` header in the
**source** `RIG_GAPS.md` (the current project's file, not the destination).

Confirm:
> "[N] entries pushed to `$PUSH_TARGET` and marked as submitted."

---

## Submit mode (GitHub issue creation)

If the user says **"submit"**, **"--submit"**, or **"open issues"**, run this flow.
This creates real GitHub issues in `laudtetteh/the-rig` via the `gh` CLI.
It requires explicit opt-in and `gh` auth with public repo access.

### Step S1 — Check opt-in

Look for the opt-in sentinel:

```bash
OPT_IN="$RIG_DIR/memory/.rig-contribute-enabled"
```

If the file does not exist:

> "GitHub submission is opt-in. To enable it, run:
> `touch $RIG_DIR/memory/.rig-contribute-enabled`
>
> This allows `/rig-gaps --submit` to create public GitHub issues in
> `laudtetteh/the-rig` on your behalf. Gap entries become publicly visible.
> Only enable this if you're comfortable sharing workflow observations publicly."

Stop. Do not proceed without the opt-in file.

### Step S2 — Check gh auth

```bash
gh auth status 2>&1
```

If `gh` is not installed or not authenticated:

> "Submit mode requires the `gh` CLI with GitHub auth.
> Install: `brew install gh`  |  Auth: `gh auth login`
> Then retry."

Stop.

### Step S3 — Privacy warning and entry preview

Show a privacy warning once:

> "⚠ **Privacy notice:** the following entries will be posted as public GitHub
> issues in `laudtetteh/the-rig`. Anyone can read them.
> Strip any project-specific details (client names, internal paths, proprietary
> logic) before submitting. You will review each entry individually."

Then list the unsubmitted entries by title only (no body):

> "**[N] entries ready to review:**
> 1. [title from first entry header]
> 2. [title from second entry header]
> …
>
> Say **go** to step through each one, or **cancel** to stop."

Wait for confirmation. Do not submit without it.

### Step S4 — Per-entry review and submission

For each unsubmitted entry, in order:

1. **Show the entry** formatted as it will appear in the GitHub issue body:

   ```
   ## Entry [N of M]: [title]

   [full entry body]

   ---
   *Submitted via `/rig-gaps --submit` from The Rig.*
   ```

2. **Ask the user:**

   > "Submit this entry as a GitHub issue? Options:
   > - **yes** — submit as shown
   > - **edit** — paste a revised body, then submit
   > - **skip** — leave this entry unsubmitted
   > - **stop** — stop here, don't submit any more"

3. **If yes:**
   - Derive the issue title: take the text after `— ` in the `## [date] — [title]` header line. Strip the date prefix.
   - Run:
     ```bash
     gh issue create \
       --repo laudtetteh/the-rig \
       --title "[derived title]" \
       --body "[entry body + submitted-via footer]" \
       --label "type: gap-report"
     ```
     (If the label doesn't exist, omit `--label` silently — don't fail.)
   - Capture the issue URL returned by `gh issue create`.
   - Report: `✓ Submitted as [URL]`

4. **If edit:**
   - Ask: "Paste the revised entry body:"
   - Wait for the user to provide text.
   - Submit using the revised body (same `gh issue create` call).

5. **If skip:**
   - Note: "[title] skipped."
   - Move to next entry.

6. **If stop:**
   - Stop the loop. Do not process remaining entries.

### Step S5 — Mark submitted entries

After the loop, for each entry that was successfully submitted:

- Update its header line in `RIG_GAPS.md`:
  ```
  ## [2026-05-09] — [title] [submitted: github:#N YYYY-MM-DD]
  ```
  Where `#N` is the issue number extracted from the URL returned by `gh issue create`.

Confirm:
> "[N] entries submitted to laudtetteh/the-rig. [M] skipped.
> Submitted entries marked in `RIG_GAPS.md`."
