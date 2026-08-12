# Command: /doc-feature

Research a named feature end-to-end and produce a structured feature doc in
`docs/features/`.

Run this any time you've traced through 5+ files to understand how something
works — capture the knowledge while it's fresh so future sessions don't repeat
the same archaeology.

Use this command only for product or business feature traces. If the requested
document is an operational runbook, one-off validation report, research spike,
agent/Rig/browser/MCP note, or durable project record, put it under the
appropriate docs category instead and update `docs/INDEX.md`; do not file it
under `docs/features/`.

> **Tip:** If you haven't already, run `/recon <feature>` first. It sweeps PR
> history and commit messages so you understand how the feature evolved before
> you document its current state.

---

## Usage

```
/doc-feature <feature name or description>
```

Examples:
```
/doc-feature upcoming grants feed
/doc-feature user authentication flow
/doc-feature PDF export pipeline
/doc-feature Stripe webhook handler
```

If no argument is given, ask: **"Which feature should I document?"**

---

## What this does

> **Project docs resolution:** Documentation lives in the project tree even when
> `.rig/` uses stealth or external tracking. Resolve the project root before
> reading or writing any feature doc path.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> DOCS_DIR="$REPO/docs/features"
> ```
>
> Substitute `$DOCS_DIR` for `docs/features/` in every step below.

### Step 1 — Confirm the feature

Restate in one sentence what you understand the feature to be and what it does
for the user or business. Ask for correction before proceeding if unsure.

---

### Step 2 — Check for an existing doc

Derive a slug from the feature name (lowercase, hyphens, no punctuation).
Check `$DOCS_DIR` for `<slug>.md`.

- **If it exists:** stop and say:
  > "A doc for this feature already exists at `$DOCS_DIR/<slug>.md`.
  > Run `/refresh-feature-doc` to update it instead."
- **If it doesn't exist:** proceed to Step 3.

Also check `$RIG_DIR/memory/ERRORS.md` for any gotchas logged about this feature
(keyword search). If found, note them — they belong in the final doc's
`## Known gotchas` section.

---

### Step 3 — Research end-to-end

Trace the full stack for this feature. The exact layer names vary by project —
use the ones that apply:

- **Entry point** — URL, route, template file, shortcode, webhook, CLI command,
  or cron job that triggers this feature
- **Render / response layer** — every template part, view, component, or
  controller involved in producing output
- **Business logic layer** — service classes, utility functions, hooks, filters,
  or middleware that process data
- **Data layer** — every query, ORM call, or raw SQL involved; post types, meta
  keys, model fields, or schema columns read or written
- **External integrations** — third-party APIs, queues, storage, or services involved
- **Configuration** — environment variables, CMS fields, feature flags, or admin
  settings that control behaviour
- **Conditional logic** — any branching, gating, or edge-case handling visible in
  the code

Use only line numbers you have verified by reading the file. Mark anything you
couldn't confirm with `<!-- TODO: verify -->`.

---

### Step 4 — Write the doc

Create `$DOCS_DIR/<slug>.md` using the template below.
Fill in every section. Delete sections that genuinely don't apply rather than
leaving them empty. Never leave placeholder brackets in the final file.

---

### Step 5 — Update the index

Add a row to the feature index table in `$DOCS_DIR/README.md`:

```
| <Feature name> | [<slug>.md](<slug>.md) | YYYY-MM-DD |
```

If the index table currently has the "none yet" placeholder row, replace it.

Then update the project docs index at the parent docs directory:

- If `$DOCS_DIR` is `.../docs/features`, the project index is `$DOCS_DIR/../INDEX.md`.
- Ensure it contains a row for `features/<slug>.md`:

```
| [`features/<slug>.md`](features/<slug>.md) | Feature: <Feature name> |
```

If `docs/INDEX.md` is missing, create it using the canonical table format before adding the row.

---

### Step 6 — Report

Output:
- Path of the new doc
- Count of: entry points traced, data fields documented, gotchas captured
- Any gaps where you couldn't confirm a detail (these are already flagged with
  `<!-- TODO: verify -->` in the doc — summarise them here too)

---

## Doc template

````markdown
# Feature: [Name]

> Last updated: YYYY-MM-DD

## Summary

One paragraph: what this feature does, why it exists, and why it matters to the
business or users. Written for someone who has never seen the code.

---

## Entry points

Where does this feature start?

- `path/to/file.ext` line N — [what triggers it here]
- `path/to/file.ext` line N — [another entry point if multiple]

---

## Flow

Step-by-step trace from entry point to final output.

1. **[Layer name]** — `path/to/file.ext` lines N–M
   [What happens here. Be specific about function names, field names, conditions.]

2. **[Layer name]** — `path/to/file.ext` lines N–M
   [What happens here.]

3. **[Continue for each meaningful step]**

---

## Data model

Fields, columns, meta keys, or CMS fields involved in this feature.

| Field / key | Type | Role |
|---|---|---|
| `field_name` | [type] | [what it controls] |
| `field_name` | [type] | [what it controls] |

---

## Business rules

The non-obvious logic that isn't obvious from reading the code alone.

- [Rule: e.g. "The label only appears when X is set — if X is absent, no label renders even though the type value exists"]
- [Rule]
- [Rule]

---

## Known gotchas

Things that have caused or could cause bugs, surprises, or confusion.

- **[Short title]**: [description of the gotcha and what to watch for]
- **[Short title]**: [description]

---

## Related features

Features that interact with, depend on, or are commonly confused with this one.

| Feature | Doc | Relationship |
|---|---|---|
| [Feature name] | [slug.md](slug.md) | [e.g. "shares the same data model", "called by this feature", "commonly confused with"] |

*(Delete this section if no meaningful relationships exist.)*

---

## Last verified against

Commit: [hash or branch]
Date: YYYY-MM-DD
````

---

## Notes

- Gotchas and business rules are the highest-value sections — they capture
  knowledge that code alone doesn't communicate. Don't shortchange them.
- If the feature is too large to trace fully in one pass, document what you've
  confirmed and mark the gaps with `<!-- TODO: verify -->`. A partial doc is
  better than no doc.
- After writing the doc, check whether any open task or in-progress PR touches
  this feature. If so, note it in the doc under a `## Related work` section.
