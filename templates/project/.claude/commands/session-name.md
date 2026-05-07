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

---

## Steps

### 1 — Determine the session boundary

Read `.rig/memory/PROGRESS.md`:

- **Primary signal:** look for `<!-- session-end YYYY-MM-DD HH:MM -->` markers.
  Entries between the top of the file and the most recent marker belong to this session.
- **Fallback:** if no markers exist, read the `**Last updated:**` date from
  `CONTEXT_SNAPSHOT.md` and treat entries added since that date as this session.

### 2 — Check for an existing session name

Read the `**Session name:**` field from `.rig/memory/CONTEXT_SNAPSHOT.md`.

- **If blank / absent:** derive a fresh name from this session's entries.
- **If already set:** suggest **appending** any new work rather than replacing:

  > **Session already named:** `feat dashboard ui #49`
  > **New work this session:** PR #51 (fix null user on profile fetch)
  > **Updated suggestion:** `feat dashboard ui #49 | fix null user profile fetch #51`

### 3 — Derive the name

Format:

```
type short-desc #N | type short-desc #N | ...
```

- `type` matches a git commit type: `fix`, `feat`, `chore`, `refactor`, `devops`, `docs`, `test`
- `short-desc` is 3–6 words — enough to identify the work at a glance
- Include the PR or issue number when known
- Keep the full string under ~100 characters

### 4 — Present the suggestion

Output the name as plain text:

> **Suggested session name:**
> `feat user-auth magic-link flow #91`

Then invite the user to apply it:

> To apply: run `/session-name` again with the name as argument, or say "use that name".

Do **not** run anything automatically. Present it for the user to confirm, copy, or tweak.

### 5 — After confirmation

When the user confirms the name (or runs `/session-name` with a name argument),
update the `**Session name:**` field in `.rig/memory/CONTEXT_SNAPSHOT.md` to match.

---

## Notes

- If no meaningful work has been completed yet (no PROGRESS entries this session),
  say so and skip the suggestion.
- If CONTEXT_SNAPSHOT.md doesn't exist, note that `/wrap` should be run first to
  create it — or offer to derive a name from PROGRESS.md alone.
- **Why not `/rename`?** Claude Code has a built-in `/rename` command that renames
  the conversation. This command was renamed to `/session-name` to avoid the conflict.
