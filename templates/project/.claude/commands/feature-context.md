# Command: /feature-context

Load a feature doc into context before starting work on that feature.

Run this before touching code that overlaps with a documented feature. It surfaces
the entry points, data model, business rules, and gotchas so you understand the full
chain before making a change.

---

## Usage

```
/feature-context <feature name or keyword>
```

Examples:
```
/feature-context auth
/feature-context stripe webhooks
/feature-context PDF export
/feature-context upcoming grants feed
```

If no argument is given, list available feature docs and ask which to load.

---

## What this does

> **Project docs resolution:** Feature docs live in the project tree even when
> `.rig/` uses stealth or external tracking. Resolve the project root before
> searching for any feature doc.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> DOCS_DIR="$REPO/docs/features"
> ```

### Step 1 — Find the doc

Check whether `$DOCS_DIR` exists. If not, say:
> "No feature docs exist yet for this project. Run `/doc-feature <name>` to create the first one."
Stop.

Read `$DOCS_DIR/README.md` (the index) to get the list of documented features.

Match the argument against:
1. **Exact slug match** — `$DOCS_DIR/<arg>.md`
2. **Partial slug match** — any filename containing the argument
3. **Title match** — any feature whose `# Feature: <title>` line contains the argument (case-insensitive)

If multiple docs match, list them and ask: **"Which feature did you mean?"**

If no docs match, say:
> "No feature doc found for `<arg>`. Available docs:"
> [list from README.md]
> "Run `/doc-feature <name>` to document this feature."
Stop.

---

### Step 2 — Load and display the doc

Read the matched `$DOCS_DIR/<slug>.md` in full.

Output a structured summary:

**Feature: [Name]** — `$DOCS_DIR/<slug>.md`
*(Last verified: YYYY-MM-DD)*

**Entry points:**
[bullet list from ## Entry points section]

**Data model:**
[table or field list from ## Data model section, if present]

**Business rules:**
[bullet list from ## Business rules section]

**Known gotchas:**
[bullet list from ## Known gotchas section — these are highest priority]

---

### Step 3 — Check for staleness

If `Last verified:` date in the doc is more than 60 days ago, note:
> "⚠ This doc was last verified on [date] — [N] days ago. Some details may be stale.
> Consider running `/refresh-feature-doc <name>` if you're making significant changes."

---

### Step 4 — Report

Confirm the doc was loaded:
> "Loaded feature doc for **[Name]**. Entry points, business rules, and gotchas are
> now in context. Proceed with the task."

---

## Notes

- This command is a read-only context loader — it does not create or modify any files.
- Use `/doc-feature <name>` to create a new feature doc.
- Use `/refresh-feature-doc <name>` to update an existing doc after a PR lands.
- The full doc content is loaded into context so the agent can reference specific
  line numbers and paths when making changes.
