# Command: /rig-gaps

Compile and display all logged gaps, friction points, and improvement ideas about
The Rig itself — formatted for submission to The Rig dev session.

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

## How to submit

1. Copy everything between the --- markers above
2. Open Claude Code in ~/tools/the-rig (or wherever The Rig lives)
3. Paste and say:
   "Here are gap reports from [project name]. Please analyze, triage, and create issues."

The Rig agent will review, open GitHub issues, and implement fixes.
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
