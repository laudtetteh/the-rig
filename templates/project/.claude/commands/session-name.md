# Command: /session-name

Derive a session name from work completed so far and present it as a ready-to-run
suggestion. Can be run at any point in the session — not just at wrap time.

---

## What this does

1. Determines the session boundary in `.rig/memory/PROGRESS.md`
2. Checks `.rig/memory/CONTEXT_SNAPSHOT.md` for an existing session name
3. Derives a name in the standard `type short-desc #N | ...` format
4. Presents it as output — does **not** run anything automatically
5. After you confirm or tweak it, updates `**Session name:**` in `CONTEXT_SNAPSHOT.md`

This is the same logic used by `/wrap` and `/post-merge`, but callable at any time
without triggering a full wrap or post-merge cycle.

---

## Usage

```
/session-name
```

No arguments. Run it whenever you want to name or re-name the current session.

> **RIG_DIR resolution (stealth mode):** Before reading `.rig/memory/PROGRESS.md` or
> `.rig/memory/CONTEXT_SNAPSHOT.md`, resolve where `.rig/` actually lives. If `.rigpath`
> exists at the project root, read it — it contains the absolute path to the external
> `.rig/` directory. Substitute `$RIG_DIR` for `.rig/` in every step below.

---

## Steps

### 1 — Determine what happened this session

**Your conversation context is the primary signal.** Before reading any files,
enumerate directly what was done in this session: PRs merged or opened, tasks
completed, issues created, commands run, significant files changed. You were
here — this is the most accurate record of the session's work.

File signals are cross-reference only — use them to catch anything that may have
compacted out of the context window, not to override what you already know:

- **`<!-- session-end YYYY-MM-DD HH:MM -->` markers in PROGRESS.md** — entries
  above the most recent marker are candidates to cross-check against your context.
- **`**Last updated:**` datetime in CONTEXT_SNAPSHOT.md** — use as an approximate
  session-start boundary when correlating PROGRESS.md entries.

**If conversation context and file signals conflict, trust the conversation.**
Files may be stale, markers may be missing, or another tab may have written to
the same files. Your direct knowledge of this session is authoritative.

### 2 — Check for an existing session name

Read the `**Session name:**` field from `.rig/memory/CONTEXT_SNAPSHOT.md`.

- **If blank / absent:** derive a fresh name from this session's entries.
- **If already set:** suggest **appending** any new work rather than replacing:

  > **Session already named:** `feat dashboard ui #49`
  > **New work this session:** PR #51 (fix null user on profile fetch)
  > **Updated suggestion:** `feat dashboard ui #49 | fix null user profile fetch #51`

### 3 — Derive the name

Use a **tiered format** based on how many meaningful units of work this session produced.
Count one "unit" per merged PR, completed task, or significant fix.

#### Tier 1 — ≤5 units (list format)

```
type short-desc #N | type short-desc #N | ...
```

- `type` matches a git commit type: `fix`, `feat`, `chore`, `refactor`, `devops`, `docs`, `test`
- `short-desc` is 3–6 words — enough to identify the work at a glance
- Include the PR or issue number when known
- Keep under ~100 characters

Example: `fix step accordion layout #184 | feat custom-permissions #152`

#### Tier 2 — 6–15 units (grouped format)

Group by commit type. For each type, list the 1–3 most significant feature areas
affected (omit the rest). Include a count if there were more.

```
type(area, area) | type(area) x3 | type x2
```

Example: `feat(auth, dashboard) | fix(billing x4, ui) | chore x3`

- Use the scope area, not individual issue numbers
- `x N` suffix means N items of that type; omit if N = 1
- Keep under ~100 characters; drop the smallest groups if over

#### Tier 3 — 16+ units (sprint summary format)

```
sprint: N issues · feat/X fix/Y chore/Z · #A–#B
```

- `N` is the total issue/PR count
- `feat/X fix/Y chore/Z` shows the count per dominant type (omit types with 0)
- `#A–#B` is the issue number range (lowest to highest)
- Keep to one line

Example: `sprint: 23 issues · feat/4 fix/15 chore/4 · #130–#152`

If the session covered a named milestone or sprint (e.g. a GitHub milestone), use
the milestone name as a prefix: `milestone: Sprint 3 · 23 issues · feat/4 fix/15 · #130–#152`

### 4 — Present the suggestion

Output the name as plain text:

> **Suggested session name:**
> `feat user-auth magic-link flow #91`

Then invite the user to apply it:

> To apply: run `/session-name` again with the name as argument, or say "use that name".

Do **not** run anything automatically. Present it for the user to confirm, copy, or tweak.

### 5 — After confirmation

When the user confirms the name (or runs `/session-name` with a name argument),
write the name into `.rig/memory/CONTEXT_SNAPSHOT.md`:

- **If `**Session name:**` field already exists:** update it in-place.
- **If absent:** insert it as the second line of the file (after `**Last updated:**`),
  or append it to the header block before the first `---` divider.

---

## Notes

- If no meaningful work has been completed yet (no PROGRESS entries this session),
  say so and skip the suggestion.
- If CONTEXT_SNAPSHOT.md doesn't exist, note that `/wrap` should be run first to
  create it — or offer to derive a name from PROGRESS.md alone.
- **Why not `/rename`?** Claude Code has a built-in `/rename` command that renames
  the conversation. This command was renamed to `/session-name` to avoid the conflict.
