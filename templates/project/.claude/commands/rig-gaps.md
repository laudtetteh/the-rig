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
