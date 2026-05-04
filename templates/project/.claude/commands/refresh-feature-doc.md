# Command: /refresh-feature-doc

Re-research an existing feature doc and update it to reflect the current state
of the code.

Run this after any PR that changes a documented feature's data model, query
logic, render logic, or business rules. Stale docs are worse than no docs —
they actively mislead future sessions.

---

## Usage

```
/refresh-feature-doc <feature name or doc path>
```

Examples:
```
/refresh-feature-doc upcoming grants feed
/refresh-feature-doc docs/features/upnext-feed.md
/refresh-feature-doc user auth
```

If no argument is given, ask: **"Which feature doc should I refresh?"**
If the argument doesn't match any existing doc, list the docs in
`docs/features/` and ask the user to confirm which one.

---

## What this does

### Step 1 — Load the existing doc

Read `docs/features/<slug>.md` in full. Note the `Last updated:` date and every
claim made — entry point paths, line numbers, field names, flow steps, business
rules, and gotchas.

---

### Step 2 — Re-verify every claim

For each claim in the doc, re-read the referenced file and line range:

- **Paths and line numbers** — verify they still point to the right code; update
  if the code moved or was refactored
- **Field names and data model** — verify each field/column still exists and has
  the same role; note any additions or removals
- **Flow steps** — re-trace the execution path; capture any new branches,
  middleware, or layers added since the doc was written
- **Business rules** — verify each rule is still enforced in the code; flag any
  that were removed or changed
- **Gotchas** — verify each gotcha still applies; remove ones that were fixed
- **Related features table** — if the doc has a `## Related features` section,
  check that every linked doc still exists (`docs/features/<slug>.md`). Remove
  rows pointing to deleted docs. Add rows for any new features that now interact
  with this one.

Mark anything you can't fully verify with `<!-- TODO: verify -->`.

---

### Step 3 — Identify what changed

Before rewriting, produce a brief change summary:

> **Changes since YYYY-MM-DD:**
> - [What changed and where]
> - [What was added]
> - [What was removed or fixed]

If nothing changed, say so and stop — don't update the doc needlessly.

---

### Step 4 — Rewrite the doc

Update `docs/features/<slug>.md`:
- Correct all stale paths, line numbers, field names, and flow steps
- Add new sections or entries for anything that was added
- Remove entries for anything that was deleted or fixed
- Update `Last updated:` to today's date
- Keep all sections from the template — don't delete sections that still apply

Do **not** rewrite the Summary unless the feature's fundamental purpose changed.

---

### Step 5 — Side effects

1. **Update the index** — update the `Last updated` date for this feature in
   `docs/features/README.md`.

2. **Log bugs to ERRORS.md** — if re-verifying the doc revealed a real bug
   (not a doc inaccuracy — an actual code problem), log it in
   `.rig/memory/ERRORS.md` using the standard format:
   - Symptom / Root cause / Fix / Watch for

3. **Report** — output what changed, what stayed the same, and any remaining
   `<!-- TODO: verify -->` gaps.

---

## Notes

- Re-verification should be thorough, not cursory. Read the actual code — don't
  assume a line number still points to the same thing.
- If the feature grew significantly and the doc needs a full rewrite, it's okay
  to do that. The goal is accuracy, not preserving the original prose.
- If you find the doc references a file that no longer exists, check git log to
  understand what happened to it before marking the claim as stale.
